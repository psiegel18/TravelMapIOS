import Foundation
import Sentry

@MainActor
class DataService: ObservableObject {

    enum DataServiceError: Error, LocalizedError {
        case gitHubRateLimited
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .gitHubRateLimited:
                return "GitHub API rate limit reached. Please try again in a few minutes."
            case .badStatus(let code):
                return "GitHub API returned status \(code)."
            }
        }
    }

    @Published var users: [UserSummary] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let session: URLSession
    private static let githubBase = "https://api.github.com/repos/TravelMapping/UserData/contents"
    private static let rawBase = "https://raw.githubusercontent.com/TravelMapping/UserData/master"

    struct UserSummary: Identifiable, Hashable, Sendable {
        let id: String
        let username: String
        let hasRoads: Bool
        let hasRail: Bool
        let hasFerry: Bool
        let hasScenic: Bool

        var categoryCount: Int {
            [hasRoads, hasRail, hasFerry, hasScenic].filter { $0 }.count
        }
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config)
    }

    /// Fetch user lists from GitHub API
    func loadUserList() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                async let roadUsers = fetchUsernames(directory: "list_files", ext: "list")
                async let railUsers = fetchUsernames(directory: "rlist_files", ext: "rlist")
                async let ferryUsers = fetchUsernames(directory: "flist_files", ext: "flist")
                async let scenicUsers = fetchUsernames(directory: "slist_files", ext: "slist")

                let roads = try await roadUsers
                let rail = try await railUsers
                let ferry = try await ferryUsers
                let scenic = try await scenicUsers

                let allUsernames = Set(roads + rail + ferry + scenic)

                let summaries = allUsernames.map { username in
                    UserSummary(
                        id: username,
                        username: username,
                        hasRoads: roads.contains(username),
                        hasRail: rail.contains(username),
                        hasFerry: ferry.contains(username),
                        hasScenic: scenic.contains(username)
                    )
                }.sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }

                self.users = summaries
                self.isLoading = false
                SpotlightService.shared.indexUsers(summaries)
            } catch {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    /// Load full profile for a user by fetching their .list/.rlist files from GitHub
    func loadUserProfile(username: String) async -> UserProfile? {
        var categories: [RouteCategory: [TravelSegment]] = [:]

        await withTaskGroup(of: (RouteCategory, [TravelSegment])?.self) { group in
            for category in RouteCategory.allCases {
                group.addTask {
                    do {
                        let content = try await self.fetchRawFile(
                            directory: category.directoryName,
                            filename: "\(username).\(category.fileExtension)"
                        )
                        let segments = ListFileParser.parse(content: content, category: category)
                        return segments.isEmpty ? nil : (category, segments)
                    } catch {
                        // 404 just means the user has no list of this type — that's normal
                        // and not worth reporting. Anything else (network failure, server
                        // error, decode failure) is a real problem that callers can't see
                        // because it collapses into "no data", so capture it here.
                        if (error as? URLError)?.code != .fileDoesNotExist {
                            SentrySDK.capture(error: error) { scope in
                                scope.setTag(value: category.rawValue, key: "list_category")
                                scope.setExtra(value: username, key: "username")
                                scope.setExtra(value: category.directoryName, key: "directory")
                            }
                        }
                        return nil
                    }
                }
            }

            for await result in group {
                if let (category, segments) = result {
                    categories[category] = segments
                }
            }
        }

        guard !categories.isEmpty else { return nil }

        return UserProfile(
            id: username,
            username: username,
            categories: categories
        )
    }

    // MARK: - GitHub API

    private struct GitHubFile: Decodable {
        let name: String
    }

    private func fetchUsernames(directory: String, ext: String) async throws -> [String] {
        let cacheKey = "github_\(directory)"

        // Check cache first
        if let cached = await CacheService.shared.get(key: cacheKey) {
            if let files = try? JSONDecoder().decode([GitHubFile].self, from: cached) {
                return files
                    .filter { $0.name.hasSuffix(".\(ext)") }
                    .map { String($0.name.dropLast(ext.count + 1)) }
            }
        }

        let url = URL(string: "\(Self.githubBase)/\(directory)")!
        let (data, response) = try await session.data(from: url)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if statusCode == 404 {
            return []
        }
        if statusCode == 403 {
            // GitHub rate limit (60 req/hr unauthenticated) — surface a clear error
            // instead of caching the JSON error body as a directory listing.
            let error = DataServiceError.gitHubRateLimited
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "github_api", key: "api_endpoint")
                scope.setExtra(value: directory, key: "directory")
            }
            throw error
        }
        guard statusCode == 200 else {
            throw DataServiceError.badStatus(statusCode)
        }

        // Decode BEFORE caching so a non-listing body never becomes a 24h cache hit
        let files = try JSONDecoder().decode([GitHubFile].self, from: data)

        // Cache for 24 hours
        await CacheService.shared.set(key: cacheKey, data: data)

        return files
            .filter { $0.name.hasSuffix(".\(ext)") }
            .map { String($0.name.dropLast(ext.count + 1)) }
    }

    private func fetchRawFile(directory: String, filename: String) async throws -> String {
        let cacheKey = "raw_\(directory)_\(filename)"

        // Check cache
        if let cached = await CacheService.shared.get(key: cacheKey),
           let content = String(data: cached, encoding: .utf8) {
            return content
        }

        let url = URL(string: "\(Self.rawBase)/\(directory)/\(filename)")!
        let (data, response) = try await session.data(from: url)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if statusCode == 404 {
            throw URLError(.fileDoesNotExist)
        }
        guard statusCode == 200 else {
            throw DataServiceError.badStatus(statusCode)
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        // Cache for 24 hours (only after validation)
        await CacheService.shared.set(key: cacheKey, data: data)

        return content
    }
}
