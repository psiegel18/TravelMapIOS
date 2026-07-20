import Foundation
import CoreLocation
import Sentry

/// Client for the TravelMapping website's PHP endpoints.
/// These return pre-processed coordinate data from the site's database.
actor TravelMappingAPI {
    static let shared = TravelMappingAPI(baseURL: "https://travelmapping.net", dbName: "TravelMapping")
    static let rail = TravelMappingAPI(baseURL: "https://tmrail.teresco.org", dbName: "TravelMappingRail")

    private let baseURL: String
    private let dbName: String
    private let session: URLSession

    init(baseURL: String, dbName: String) {
        self.baseURL = baseURL
        self.dbName = dbName
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - Response Types

    struct VisibleSegmentsResponse: Decodable {
        // Per-segment parallel arrays
        let roots: [String]?
        let segmentids: [String]?
        let w1lat: [String]?
        let w1lng: [String]?
        let w2lat: [String]?
        let w2lng: [String]?
        let w1name: [String]?
        let w2name: [String]?
        let clinched: [String]?       // "0" or "1"
        let travelers: [String]?

        // Per-route metadata arrays
        let routeroots: [String]?
        let routelistnames: [String]?
        let routemileages: [String]?
        let routeclinchedmileages: [String]?
        let routecolors: [String]?
        let routetiers: [String]?
    }

    struct RouteDataResponse: Decodable {
        let pointNames: [[String?]]?
        let latitudes: [[String?]]?
        let longitudes: [[String?]]?
        let clinched: [[String?]]?     // "0" or "1" per segment (N-1 for N waypoints)
        let segmentIds: [[String?]]?
        let driverCounts: [[String?]]?
        let listNames: [String]?
    }

    struct TravelerRoutesResponse: Decodable {
        let routes: [String]?
    }

    struct AllRoutesResponse: Decodable {
        let listNames: [String]?
        let systems: [String]?
        let routeNames: [String]?
        let regions: [String]?
        let countries: [String]?
        let continents: [String]?
        let roots: [String]?
    }

    // MARK: - Processed Types for the App

    struct MapSegment: Identifiable {
        /// Stable content-based identity ("root|startName|endName"). Must NOT be a
        /// response array index — indices collide across regions and between the road
        /// and rail APIs, which corrupts selection sets built from multiple responses.
        let id: String
        /// Position within the API response — preserves along-route ordering for
        /// polyline merging. Only meaningful relative to other segments of the same root.
        let orderIndex: Int
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
        let isClinched: Bool
        let root: String
        let startName: String
        let endName: String
    }

    struct RouteMetadata: Identifiable {
        let id: String  // root
        let root: String
        let listName: String
        let mileage: Double
        let clinchedMileage: Double
        let color: String
        let tier: Int
    }

    struct RouteDetail: Identifiable {
        let id: String  // root from listName
        let listName: String
        let coordinates: [CLLocationCoordinate2D]
        let clinched: [Bool]  // per-segment (between consecutive points)
    }

    // MARK: - API Calls

    /// Get all segments visible in a map bounding box, with clinch status for a traveler.
    func getVisibleSegments(
        traveler: String,
        minLat: Double,
        maxLat: Double,
        minLng: Double,
        maxLng: Double
    ) async throws -> (segments: [MapSegment], routes: [RouteMetadata]) {
        let params: [String: Any] = [
            "minLat": minLat,
            "maxLat": maxLat,
            "minLng": minLng,
            "maxLng": maxLng,
            "traveler": traveler
        ]

        let data = try await post(endpoint: "/lib/getVisibleSegments.php", params: params, cacheTTL: 6 * 3600)
        let response = try JSONDecoder().decode(VisibleSegmentsResponse.self, from: data)
        return Self.parseSegmentsResponse(response)
    }

    /// Parse the parallel arrays of a VisibleSegmentsResponse into segments + route metadata.
    /// All sibling-array accesses use the safe subscript: the loop count comes from one
    /// array, and a server hiccup that returns a shorter sibling array must degrade to
    /// the default value, not crash with index-out-of-range (optional chaining does NOT
    /// bounds-check).
    private static func parseSegmentsResponse(_ response: VisibleSegmentsResponse) -> (segments: [MapSegment], routes: [RouteMetadata]) {
        let w1lat = response.w1lat ?? []
        let w1lng = response.w1lng ?? []
        let w2lat = response.w2lat ?? []
        let w2lng = response.w2lng ?? []
        let roots = response.roots ?? []
        let w1name = response.w1name ?? []
        let w2name = response.w2name ?? []
        let clinched = response.clinched ?? []

        var segments: [MapSegment] = []
        for i in 0..<w1lat.count {
            guard let lat1 = Double(w1lat[safe: i] ?? ""),
                  let lng1 = Double(w1lng[safe: i] ?? ""),
                  let lat2 = Double(w2lat[safe: i] ?? ""),
                  let lng2 = Double(w2lng[safe: i] ?? "") else { continue }

            let root = roots[safe: i] ?? ""
            let startName = w1name[safe: i] ?? ""
            let endName = w2name[safe: i] ?? ""
            segments.append(MapSegment(
                id: "\(root)|\(startName)|\(endName)",
                orderIndex: i,
                start: CLLocationCoordinate2D(latitude: lat1, longitude: lng1),
                end: CLLocationCoordinate2D(latitude: lat2, longitude: lng2),
                isClinched: clinched[safe: i] == "1",
                root: root,
                startName: startName,
                endName: endName
            ))
        }

        let routeroots = response.routeroots ?? []
        let routelistnames = response.routelistnames ?? []
        let routemileages = response.routemileages ?? []
        let routeclinchedmileages = response.routeclinchedmileages ?? []
        let routecolors = response.routecolors ?? []
        let routetiers = response.routetiers ?? []

        var routes: [RouteMetadata] = []
        for i in 0..<routeroots.count {
            let root = routeroots[i]
            routes.append(RouteMetadata(
                id: root,
                root: root,
                listName: routelistnames[safe: i] ?? "",
                mileage: Double(routemileages[safe: i] ?? "0") ?? 0,
                clinchedMileage: Double(routeclinchedmileages[safe: i] ?? "0") ?? 0,
                color: routecolors[safe: i] ?? "TMblue",
                tier: Int(routetiers[safe: i] ?? "1") ?? 1
            ))
        }

        return (segments, routes)
    }

    /// Get full route data with waypoints for specific route roots.
    func getRouteData(roots: [String], traveler: String) async throws -> [RouteDetail] {
        SentrySDK.logger.debug("Loading route data", attributes: [
            "rootCount": roots.count,
            "firstRoot": roots.first ?? "",
            "traveler": traveler,
        ])
        let params: [String: Any] = [
            "roots": roots,
            "traveler": traveler
        ]

        // post() strips any HTML warnings prepended before the JSON (see salvageJSON)
        let data = try await post(endpoint: "/lib/getRouteData.php", params: params)

        let response = try JSONDecoder().decode(RouteDataResponse.self, from: data)

        let latitudes = response.latitudes ?? []
        let longitudes = response.longitudes ?? []
        let clinchedArrays = response.clinched ?? []
        let listNames = response.listNames ?? []

        var details: [RouteDetail] = []
        for i in 0..<latitudes.count {
            let lats = latitudes[i]
            guard let lngs = longitudes[safe: i] else { continue }

            let coords = zip(lats, lngs).compactMap { latStr, lngStr -> CLLocationCoordinate2D? in
                guard let latStr, let lngStr,
                      let lat = Double(latStr), let lng = Double(lngStr) else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lng)
            }

            let clinchStatus = clinchedArrays[safe: i]?.map { $0 == "1" } ?? []

            details.append(RouteDetail(
                id: listNames[safe: i] ?? "route-\(i)",
                listName: listNames[safe: i] ?? "",
                coordinates: coords,
                clinched: clinchStatus
            ))
        }

        return details
    }

    /// Get segments filtered by region(s), system, or specific route roots.
    func getRegionSegments(
        roots: [String]? = nil,
        region: String? = nil,
        regions: [String]? = nil,
        system: String? = nil,
        traveler: String
    ) async throws -> (segments: [MapSegment], routes: [RouteMetadata]) {
        var clauseParts: [String] = []

        if let roots, !roots.isEmpty {
            let rootConditions = roots.map { "routes.root='\(Self.sqlQuoteEscaped($0))'" }.joined(separator: " or ")
            clauseParts.append("(\(rootConditions))")
        }
        if let regions, !regions.isEmpty {
            let regionConditions = regions.map { "routes.region='\(Self.sqlQuoteEscaped($0))'" }.joined(separator: " or ")
            clauseParts.append("(\(regionConditions))")
        } else if let region {
            clauseParts.append("(routes.region='\(Self.sqlQuoteEscaped(region))')")
        }
        if let system {
            clauseParts.append("(routes.systemName='\(Self.sqlQuoteEscaped(system))')")
        }

        // No filters → no clause at all; a bare "where " is invalid SQL server-side
        let clause = clauseParts.isEmpty ? "" : "where " + clauseParts.joined(separator: " and ")

        let params: [String: Any] = [
            "clause": clause,
            "traveler": traveler
        ]

        let data = try await post(endpoint: "/lib/getRegionSystemSegments.php", params: params, cacheTTL: 6 * 3600) // cache 6 hours
        let response = try JSONDecoder().decode(VisibleSegmentsResponse.self, from: data)
        return Self.parseSegmentsResponse(response)
    }

    /// Escape a value for interpolation into the server-side SQL-ish clause:
    /// single quotes are doubled (' → '') so quoted values can't break the statement.
    private static func sqlQuoteEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    /// Get the full route catalog (cacheable). The TM site only updates once a day,
    /// so a long TTL is appropriate; values rarely change otherwise.
    func getAllRoutes() async throws -> AllRoutesResponse {
        let data = try await get(endpoint: "/lib/getAllRoutesInfo.php", cacheTTL: 24 * 3600)
        return try JSONDecoder().decode(AllRoutesResponse.self, from: data)
    }

    // MARK: - Networking

    /// Build a deterministic cache-key fragment from POST params.
    /// `[String: Any].description` randomizes key order per launch, which made the
    /// disk cache never hit across launches. Keys are sorted; array values are joined
    /// in their existing order (order is meaningful for e.g. `roots`).
    private static func stableParamsKey(_ params: [String: Any]) -> String {
        params.keys.sorted().map { key in
            let value = params[key]
            let str: String
            if let arr = value as? [Any] {
                str = arr.map { "\($0)" }.joined(separator: ",")
            } else {
                str = value.map { "\($0)" } ?? ""
            }
            return "\(key)=\(str)"
        }.joined(separator: "&")
    }

    /// Allowed characters for the percent-encoded form value. `.urlQueryAllowed` minus
    /// the characters that are structural in application/x-www-form-urlencoded bodies —
    /// unencoded '&' splits the value, '+' decodes as a space, '=' splits key/value.
    private static let formValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?")
        return set
    }()

    private func post(endpoint: String, params: [String: Any], cacheTTL: TimeInterval? = nil) async throws -> Data {
        // Check cache (include dbName to distinguish road vs rail APIs)
        let cacheKey = "tm_\(dbName)_\(endpoint)_\(Self.stableParamsKey(params))"
        if cacheTTL != nil, let cached = await CacheService.shared.get(key: cacheKey) {
            if cached == Self.negativeCacheSentinel {
                throw APIError.htmlResponseInsteadOfJSON
            }
            return cached
        }

        var urlComponents = URLComponents(string: baseURL + endpoint)!
        urlComponents.queryItems = [URLQueryItem(name: "dbname", value: dbName)]

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let jsonData = try JSONSerialization.data(withJSONObject: params)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        let encoded = jsonString.addingPercentEncoding(withAllowedCharacters: Self.formValueAllowed) ?? jsonString
        request.httpBody = "params=\(encoded)".data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        // Validate HTTP status
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw URLError(.badServerResponse)
        }

        // The PHP backend occasionally returns HTML (a maintenance page, an error page,
        // or a captive-portal redirect) with a 200 status. Detecting that here lets callers
        // fail fast with a meaningful error instead of producing the cryptic
        // NSCocoaErrorDomain 4864 ("Unexpected character '<'") from JSONDecoder downstream.
        if let firstByte = data.first, firstByte == 0x3C { // '<'
            // Some endpoints prepend HTML warnings before valid JSON
            // (e.g. "<br /><b>Warning</b>…{json}") — salvage the JSON when it's there.
            if let salvaged = Self.salvageJSON(from: data) {
                if let ttl = cacheTTL {
                    await CacheService.shared.set(key: cacheKey, data: salvaged, ttl: ttl)
                }
                return salvaged
            }
            Self.captureHTMLResponse(endpoint: endpoint, method: "POST", data: data)
            if cacheTTL != nil {
                await CacheService.shared.set(key: cacheKey, data: Self.negativeCacheSentinel, ttl: Self.negativeCacheTTL)
            }
            throw APIError.htmlResponseInsteadOfJSON
        }

        // Cache if TTL specified
        if let ttl = cacheTTL {
            await CacheService.shared.set(key: cacheKey, data: data, ttl: ttl)
        }

        return data
    }

    /// If an HTML-prefixed body contains a JSON object after the noise, return just the
    /// JSON portion (validated via JSONSerialization); nil if nothing salvageable.
    private static func salvageJSON(from data: Data) -> Data? {
        guard let braceIndex = data.firstIndex(of: 0x7B) else { return nil } // '{'
        let candidate = Data(data[braceIndex...])
        guard (try? JSONSerialization.jsonObject(with: candidate)) != nil else { return nil }
        return candidate
    }

    // Negative-cache marker: when the backend returns HTML for an endpoint, we stash this
    // sentinel under the same cacheKey for a short window so subsequent identical requests
    // fail fast without hitting the network or re-capturing to Sentry.
    private static let negativeCacheSentinel = Data("__TM_NEGATIVE_CACHE__".utf8)
    private static let negativeCacheTTL: TimeInterval = 300

    /// Capture a Sentry issue WITH the offending response body when the API gives us HTML.
    /// Callers swallow the throw with `try?`, so without an explicit capture we'd never see
    /// what the server actually returned — defeating the point of the typed error.
    private static func captureHTMLResponse(endpoint: String, method: String, data: Data) {
        let preview = String(data: data.prefix(2048), encoding: .utf8) ?? "<non-utf8>"
        let attachment = Attachment(
            data: data,
            filename: "api_response.html",
            contentType: "text/html"
        )
        SentrySDK.capture(error: APIError.htmlResponseInsteadOfJSON) { scope in
            scope.addAttachment(attachment)
            scope.setExtra(value: preview, key: "response_preview_2kb")
            scope.setExtra(value: data.count, key: "response_bytes")
            scope.setTag(value: endpoint, key: "api_endpoint")
            scope.setTag(value: method, key: "api_method")
        }
    }

    enum APIError: Error, LocalizedError {
        case htmlResponseInsteadOfJSON

        var errorDescription: String? {
            switch self {
            case .htmlResponseInsteadOfJSON:
                return "TravelMapping API returned HTML instead of JSON (likely a server error or maintenance page)."
            }
        }
    }

    private func get(endpoint: String, cacheTTL: TimeInterval? = nil) async throws -> Data {
        let cacheKey = "tm_\(dbName)_GET_\(endpoint)"
        if cacheTTL != nil, let cached = await CacheService.shared.get(key: cacheKey) {
            if cached == Self.negativeCacheSentinel {
                throw APIError.htmlResponseInsteadOfJSON
            }
            return cached
        }

        var urlComponents = URLComponents(string: baseURL + endpoint)!
        urlComponents.queryItems = [URLQueryItem(name: "dbname", value: dbName)]

        let request = URLRequest(url: urlComponents.url!)
        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        if let firstByte = data.first, firstByte == 0x3C { // '<'
            Self.captureHTMLResponse(endpoint: endpoint, method: "GET", data: data)
            if cacheTTL != nil {
                await CacheService.shared.set(key: cacheKey, data: Self.negativeCacheSentinel, ttl: Self.negativeCacheTTL)
            }
            throw APIError.htmlResponseInsteadOfJSON
        }

        if let ttl = cacheTTL {
            await CacheService.shared.set(key: cacheKey, data: data, ttl: ttl)
        }

        return data
    }
}

/// In-memory snapshot of the TravelMapping route catalog. Loaded once per app launch
/// (with a 24h disk cache as a fallback) and shared across views that need region→country
/// or region→listName lookups, instead of every view re-fetching the multi-MB catalog.
@MainActor
final class CatalogService: ObservableObject {
    static let shared = CatalogService()

    @Published private(set) var regionCountryMap: [String: String] = [:]
    @Published private(set) var isLoaded: Bool = false

    private var loadTask: Task<Void, Never>?

    /// Kick off a load if one isn't already in flight. Safe to call repeatedly.
    func loadIfNeeded() {
        guard !isLoaded, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await TravelMappingAPI.shared.getAllRoutes()
                var mapping: [String: String] = [:]
                let regions = catalog.regions ?? []
                let countries = catalog.countries ?? []
                for (i, region) in regions.enumerated() where i < countries.count && mapping[region] == nil {
                    mapping[region] = countries[i]
                }
                self.regionCountryMap = mapping
                self.isLoaded = true
            } catch {
                SentrySDK.capture(error: error)
            }
            self.loadTask = nil
        }
    }

    /// Await the in-flight load (or trigger one) and return the current mapping.
    /// Views that need the data immediately should call this instead of reading the
    /// published value, which may still be empty during the first launch.
    func awaitMapping() async -> [String: String] {
        if isLoaded { return regionCountryMap }
        if loadTask == nil { loadIfNeeded() }
        await loadTask?.value
        return regionCountryMap
    }
}

// MARK: - Safe Array Access

/// Bounds-checked subscript for the parallel-array API responses. The loop count is
/// taken from ONE array, so a sibling array that came back shorter must yield nil
/// (→ caller default) instead of crashing — optional chaining alone does not bounds-check.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Color Mapping

extension TravelMappingAPI.RouteMetadata {
    /// Convert TM color names to SwiftUI-compatible hex
    var displayColorHex: String {
        switch color {
        case "TMblue": return "#0000FF"
        case "TMred": return "#FF0000"
        case "TMgreen": return "#00AA00"
        case "TMmagenta": return "#FF00FF"
        case "TMteal": return "#008080"
        case "TMpurple": return "#800080"
        case "TMbrown": return "#A0522D"
        case "TMlightsalmon": return "#FFA07A"
        case "TMyellow": return "#CCCC00"
        default: return "#0000FF"
        }
    }
}
