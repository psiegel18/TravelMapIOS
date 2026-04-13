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
        let id: Int
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

        var segments: [MapSegment] = []
        let count = response.w1lat?.count ?? 0

        for i in 0..<count {
            guard let lat1 = Double(response.w1lat?[i] ?? ""),
                  let lng1 = Double(response.w1lng?[i] ?? ""),
                  let lat2 = Double(response.w2lat?[i] ?? ""),
                  let lng2 = Double(response.w2lng?[i] ?? "") else { continue }

            segments.append(MapSegment(
                id: i,
                start: CLLocationCoordinate2D(latitude: lat1, longitude: lng1),
                end: CLLocationCoordinate2D(latitude: lat2, longitude: lng2),
                isClinched: response.clinched?[i] == "1",
                root: response.roots?[i] ?? "",
                startName: response.w1name?[i] ?? "",
                endName: response.w2name?[i] ?? ""
            ))
        }

        var routes: [RouteMetadata] = []
        let routeCount = response.routeroots?.count ?? 0

        for i in 0..<routeCount {
            let root = response.routeroots?[i] ?? ""
            routes.append(RouteMetadata(
                id: root,
                root: root,
                listName: response.routelistnames?[i] ?? "",
                mileage: Double(response.routemileages?[i] ?? "0") ?? 0,
                clinchedMileage: Double(response.routeclinchedmileages?[i] ?? "0") ?? 0,
                color: response.routecolors?[i] ?? "TMblue",
                tier: Int(response.routetiers?[i] ?? "1") ?? 1
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

        var data = try await post(endpoint: "/lib/getRouteData.php", params: params)

        // The PHP endpoint may prepend HTML warnings before the JSON — strip them
        if let jsonStart = String(data: data, encoding: .utf8)?.firstIndex(of: "{"),
           let cleanData = String(data: data, encoding: .utf8)?[jsonStart...].data(using: .utf8) {
            data = cleanData
        }

        let response = try JSONDecoder().decode(RouteDataResponse.self, from: data)

        var details: [RouteDetail] = []
        let routeCount = response.latitudes?.count ?? 0

        for i in 0..<routeCount {
            guard let lats = response.latitudes?[i],
                  let lngs = response.longitudes?[i] else { continue }

            let coords = zip(lats, lngs).compactMap { latStr, lngStr -> CLLocationCoordinate2D? in
                guard let latStr, let lngStr,
                      let lat = Double(latStr), let lng = Double(lngStr) else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lng)
            }

            let clinchStatus = response.clinched?[i].map { $0 == "1" } ?? []

            details.append(RouteDetail(
                id: response.listNames?[i] ?? "route-\(i)",
                listName: response.listNames?[i] ?? "",
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
            let rootConditions = roots.map { "routes.root='\($0)'" }.joined(separator: " or ")
            clauseParts.append("(\(rootConditions))")
        }
        if let regions, !regions.isEmpty {
            let regionConditions = regions.map { "routes.region='\($0)'" }.joined(separator: " or ")
            clauseParts.append("(\(regionConditions))")
        } else if let region {
            clauseParts.append("(routes.region='\(region)')")
        }
        if let system {
            clauseParts.append("(routes.systemName='\(system)')")
        }

        let clause = "where " + clauseParts.joined(separator: " and ")

        let params: [String: Any] = [
            "clause": clause,
            "traveler": traveler
        ]

        let data = try await post(endpoint: "/lib/getRegionSystemSegments.php", params: params, cacheTTL: 6 * 3600) // cache 6 hours
        let response = try JSONDecoder().decode(VisibleSegmentsResponse.self, from: data)

        // Same parsing as getVisibleSegments
        var segments: [MapSegment] = []
        let count = response.w1lat?.count ?? 0

        for i in 0..<count {
            guard let lat1 = Double(response.w1lat?[i] ?? ""),
                  let lng1 = Double(response.w1lng?[i] ?? ""),
                  let lat2 = Double(response.w2lat?[i] ?? ""),
                  let lng2 = Double(response.w2lng?[i] ?? "") else { continue }

            segments.append(MapSegment(
                id: i,
                start: CLLocationCoordinate2D(latitude: lat1, longitude: lng1),
                end: CLLocationCoordinate2D(latitude: lat2, longitude: lng2),
                isClinched: response.clinched?[i] == "1",
                root: response.roots?[i] ?? "",
                startName: response.w1name?[i] ?? "",
                endName: response.w2name?[i] ?? ""
            ))
        }

        var routes: [RouteMetadata] = []
        let routeCount = response.routeroots?.count ?? 0

        for i in 0..<routeCount {
            let root = response.routeroots?[i] ?? ""
            routes.append(RouteMetadata(
                id: root,
                root: root,
                listName: response.routelistnames?[i] ?? "",
                mileage: Double(response.routemileages?[i] ?? "0") ?? 0,
                clinchedMileage: Double(response.routeclinchedmileages?[i] ?? "0") ?? 0,
                color: response.routecolors?[i] ?? "TMblue",
                tier: Int(response.routetiers?[i] ?? "1") ?? 1
            ))
        }

        return (segments, routes)
    }

    /// Get the full route catalog (cacheable).
    func getAllRoutes() async throws -> AllRoutesResponse {
        let data = try await get(endpoint: "/lib/getAllRoutesInfo.php")
        return try JSONDecoder().decode(AllRoutesResponse.self, from: data)
    }

    // MARK: - Networking

    private func post(endpoint: String, params: [String: Any], cacheTTL: TimeInterval? = nil) async throws -> Data {
        // Check cache (include dbName to distinguish road vs rail APIs)
        let cacheKey = "tm_\(dbName)_\(endpoint)_\(params.description)"
        if cacheTTL != nil, let cached = await CacheService.shared.get(key: cacheKey) {
            return cached
        }

        var urlComponents = URLComponents(string: baseURL + endpoint)!
        urlComponents.queryItems = [URLQueryItem(name: "dbname", value: dbName)]

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let jsonData = try JSONSerialization.data(withJSONObject: params)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        request.httpBody = "params=\(jsonString)".data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        // Validate HTTP status
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw URLError(.badServerResponse)
        }

        // Cache if TTL specified
        if let ttl = cacheTTL {
            await CacheService.shared.set(key: cacheKey, data: data, ttl: ttl)
        }

        return data
    }

    private func get(endpoint: String) async throws -> Data {
        var urlComponents = URLComponents(string: baseURL + endpoint)!
        urlComponents.queryItems = [URLQueryItem(name: "dbname", value: dbName)]

        let request = URLRequest(url: urlComponents.url!)
        let (data, _) = try await session.data(for: request)
        return data
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
