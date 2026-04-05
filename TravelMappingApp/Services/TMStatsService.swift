import Foundation

/// Fetches aggregated stats CSV files from travelmapping.net/stats/.
/// One file contains every user's mileage for every region/system — much faster than per-user API calls.
/// TM site updates these nightly around 8-11pm ET, so we cache for 12 hours.
actor TMStatsService {
    static let shared = TMStatsService()

    private let baseURL = "https://travelmapping.net/stats"
    private let session: URLSession
    private let cacheTTL: TimeInterval = 12 * 3600 // 12 hours

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Models

    struct UserRegionStats: Sendable {
        let username: String
        let totalMiles: Double
        let byRegion: [String: Double] // region code → miles
    }

    struct UserSystemStats: Sendable {
        let system: String           // e.g., "usai"
        let username: String
        let totalMiles: Double
        let byRegion: [String: Double] // region code → miles within this system
    }

    struct LeaderboardSnapshot: Sendable {
        let users: [UserRegionStats] // sorted by totalMiles desc
        let userCount: Int
        let globalTotalMiles: Double

        /// Returns (rank, percentile) for a given username. Rank is 1-indexed.
        func position(of username: String) -> (rank: Int, percentile: Double)? {
            guard let idx = users.firstIndex(where: { $0.username.lowercased() == username.lowercased() }) else {
                return nil
            }
            let rank = idx + 1
            let percentile = 100.0 - (Double(rank) / Double(users.count) * 100.0)
            return (rank, percentile)
        }
    }

    // MARK: - Public API

    /// Load aggregate region stats (one file, all users, all regions).
    func loadRegionStats(includePreview: Bool = false, forceRefresh: Bool = false) async throws -> LeaderboardSnapshot {
        let filename = includePreview ? "allbyregionactivepreview.csv" : "allbyregionactiveonly.csv"
        let csv = try await fetchCSV(filename: filename, forceRefresh: forceRefresh)
        let users = parseRegionCSV(csv).sorted { $0.totalMiles > $1.totalMiles }
        let globalTotal = users.reduce(0.0) { $0 + $1.totalMiles }
        return LeaderboardSnapshot(users: users, userCount: users.count, globalTotalMiles: globalTotal)
    }

    /// Load stats for a specific system (e.g., "usai" for US Interstates).
    func loadSystemStats(system: String, forceRefresh: Bool = false) async throws -> [UserSystemStats] {
        let filename = "\(system)-all.csv"
        let csv = try await fetchCSV(filename: filename, forceRefresh: forceRefresh)
        return parseSystemCSV(csv, systemCode: system)
    }

    /// Clear all cached CSVs
    func clearCache() async {
        await CacheService.shared.clearAll()
    }

    /// Check if we have cached data that's still fresh
    func hasFreshCache(filename: String) async -> Bool {
        let cacheKey = "stats_\(filename)"
        return await CacheService.shared.get(key: cacheKey) != nil
    }

    /// Get the last-fetched date of the region stats CSV
    func lastUpdated(includePreview: Bool = false) async -> Date? {
        let filename = includePreview ? "allbyregionactivepreview.csv" : "allbyregionactiveonly.csv"
        return await CacheService.shared.getAge(key: "stats_\(filename)")
    }

    // MARK: - Private

    private func fetchCSV(filename: String, forceRefresh: Bool) async throws -> String {
        let cacheKey = "stats_\(filename)"

        if !forceRefresh, let cached = await CacheService.shared.get(key: cacheKey),
           let content = String(data: cached, encoding: .utf8) {
            return content
        }

        let url = URL(string: "\(baseURL)/\(filename)")!
        let (data, response) = try await session.data(from: url)

        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw URLError(.fileDoesNotExist)
        }

        await CacheService.shared.set(key: cacheKey, data: data, ttl: cacheTTL)

        guard let content = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return content
    }

    private func parseRegionCSV(_ content: String) -> [UserRegionStats] {
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count >= 2 else { return [] }

        let headers = lines[0].components(separatedBy: ",")
        guard headers.count >= 3 else { return [] }
        let regionCodes = Array(headers.dropFirst(2)) // skip Traveler, Total

        var result: [UserRegionStats] = []
        for line in lines.dropFirst() {
            let fields = line.components(separatedBy: ",")
            guard fields.count == headers.count else { continue }

            let username = fields[0]
            let total = Double(fields[1]) ?? 0

            var byRegion: [String: Double] = [:]
            for (i, region) in regionCodes.enumerated() {
                let miles = Double(fields[i + 2]) ?? 0
                if miles > 0 {
                    byRegion[region] = miles
                }
            }

            result.append(UserRegionStats(
                username: username,
                totalMiles: total,
                byRegion: byRegion
            ))
        }
        return result
    }

    private func parseSystemCSV(_ content: String, systemCode: String) -> [UserSystemStats] {
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count >= 2 else { return [] }

        let headers = lines[0].components(separatedBy: ",")
        guard headers.count >= 3 else { return [] }
        let regionCodes = Array(headers.dropFirst(2))

        var result: [UserSystemStats] = []
        for line in lines.dropFirst() {
            let fields = line.components(separatedBy: ",")
            guard fields.count == headers.count else { continue }

            let username = fields[0]
            let total = Double(fields[1]) ?? 0

            var byRegion: [String: Double] = [:]
            for (i, region) in regionCodes.enumerated() {
                let miles = Double(fields[i + 2]) ?? 0
                if miles > 0 {
                    byRegion[region] = miles
                }
            }

            result.append(UserSystemStats(
                system: systemCode,
                username: username,
                totalMiles: total,
                byRegion: byRegion
            ))
        }
        return result
    }
}
