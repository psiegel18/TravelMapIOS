import Foundation

@MainActor
class DataService: ObservableObject {
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

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
            return []
        }

        // Cache for 24 hours
        await CacheService.shared.set(key: cacheKey, data: data)

        let files = try JSONDecoder().decode([GitHubFile].self, from: data)
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

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
            throw URLError(.fileDoesNotExist)
        }

        // Cache for 24 hours
        await CacheService.shared.set(key: cacheKey, data: data)

        guard let content = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        return content
    }
}
