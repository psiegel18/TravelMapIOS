import Foundation
import Sentry
import Security

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

    /// Current text of a user's list file, bypassing every cache — merging new lines into a
    /// stale copy would silently drop whatever the user changed since. Returns nil when the
    /// user has no file of this type yet.
    nonisolated static func fetchCurrentListText(username: String, category: RouteCategory) async throws -> String? {
        let url = URL(string: "\(rawBase)/\(category.directoryName)/\(username).\(category.fileExtension)")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if statusCode == 404 { return nil }
        guard statusCode == 200 else { throw DataServiceError.badStatus(statusCode) }
        guard let content = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return content
    }

    /// GitHub web-editor URL for a user's list file. For non-collaborators GitHub forks
    /// the repo and opens a pull request when they tap "Propose changes".
    nonisolated static func listFileEditURL(username: String, category: RouteCategory) -> URL {
        URL(string: "https://github.com/TravelMapping/UserData/edit/master/\(category.directoryName)/\(username).\(category.fileExtension)")!
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

// MARK: - GitHub (in-app .list pull requests)

/// A pull request the app opened against TravelMapping/UserData.
struct ListUpdatePR: Codable, Hashable, Identifiable {
    let number: Int
    let url: URL
    let createdAt: Date
    let lineCount: Int
    var id: Int { number }
}

/// Signs in with GitHub's OAuth device flow (no client secret, no redirect) and opens
/// .list update pull requests from the user's fork of TravelMapping/UserData.
/// The token lives only in the Keychain on this device.
@MainActor
final class GitHubService: ObservableObject {
    static let shared = GitHubService()

    /// Client ID of the "Travel Mapping iOS" GitHub OAuth App (device flow enabled).
    /// Client IDs are public; device flow needs no secret. Empty disables in-app PRs.
    static let clientID = "Ov23liCQLY5nbrtgtRSu"

    private static let upstream = "TravelMapping/UserData"
    private static let keychainService = "com.psiegel18.TravelMapping.github"

    @Published private(set) var login: String?

    var isConfigured: Bool { !Self.clientID.isEmpty }
    var isSignedIn: Bool { token != nil }

    private var token: String?

    enum GitHubError: LocalizedError {
        case notConfigured
        case notSignedIn
        case expired
        case denied
        case api(status: Int, message: String)
        case forkNotReady

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "GitHub sign-in isn't available in this build."
            case .notSignedIn: return "Sign in with GitHub first."
            case .expired: return "The sign-in code expired. Start again."
            case .denied: return "GitHub sign-in was cancelled."
            case .api(let status, let message): return "GitHub returned \(status): \(message)"
            case .forkNotReady: return "GitHub is still creating your fork. Try again in a minute."
            }
        }
    }

    struct DeviceCode: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int
    }

    enum PRState: String {
        case open, merged, closed
    }

    private init() {
        token = Self.readToken()
        if token != nil {
            login = UserDefaults.standard.string(forKey: "githubLogin")
        }
    }

    // MARK: Sign-in

    func startDeviceFlow() async throws -> DeviceCode {
        guard isConfigured else { throw GitHubError.notConfigured }
        let data = try await formPost("https://github.com/login/device/code", [
            "client_id": Self.clientID,
            "scope": "public_repo",
        ])
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    /// Polls until the user approves the code on github.com (or it expires).
    func completeDeviceFlow(_ code: DeviceCode) async throws {
        struct TokenResponse: Decodable {
            let access_token: String?
            let error: String?
        }
        var interval = UInt64(max(code.interval, 5))
        let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: interval * 1_000_000_000)
            let data = try await formPost("https://github.com/login/oauth/access_token", [
                "client_id": Self.clientID,
                "device_code": code.device_code,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)
            if let accessToken = response.access_token {
                token = accessToken
                Self.saveToken(accessToken)
                try await refreshLogin()
                let crumb = Breadcrumb(level: .info, category: "github")
                crumb.message = "Signed in with GitHub"
                SentrySDK.addBreadcrumb(crumb)
                return
            }
            switch response.error {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw GitHubError.expired
            case "access_denied": throw GitHubError.denied
            default: throw GitHubError.api(status: 400, message: response.error ?? "unknown error")
            }
        }
        throw GitHubError.expired
    }

    func signOut() {
        token = nil
        login = nil
        Self.deleteToken()
        UserDefaults.standard.removeObject(forKey: "githubLogin")
    }

    private func refreshLogin() async throws {
        struct User: Decodable { let login: String }
        let user = try JSONDecoder().decode(User.self, from: try await api("GET", "/user"))
        login = user.login
        UserDefaults.standard.set(user.login, forKey: "githubLogin")
    }

    // MARK: Pull requests

    /// Merges `lines` into the newest upstream copy of the user's list file, commits it
    /// to a fresh branch on the user's fork, and opens a pull request.
    func openListUpdatePR(
        username: String,
        category: RouteCategory,
        lines: [ListLine],
        blockTitle: String,
        appendOnly: Bool,
        tripNames: [String]
    ) async throws -> (pr: ListUpdatePR, merge: ListFileMerger.Result) {
        guard isSignedIn else { throw GitHubError.notSignedIn }
        if login == nil { try await refreshLogin() }
        guard let login else { throw GitHubError.notSignedIn }

        let path = "\(category.directoryName)/\(username).\(category.fileExtension)"

        // 1. Upstream head + current file at that exact commit (no CDN staleness)
        struct Ref: Decodable { struct Object: Decodable { let sha: String }; let object: Object }
        let baseSHA = try JSONDecoder().decode(Ref.self, from: try await api("GET", "/repos/\(Self.upstream)/git/ref/heads/master")).object.sha

        // Blob SHA from the contents API (needed to update the file); text from the raw
        // URL pinned to the same commit — the contents API omits bodies over 1 MB.
        struct Contents: Decodable { let sha: String }
        var existingText = ""
        var fileSHA: String?
        do {
            fileSHA = try JSONDecoder().decode(Contents.self, from: try await api("GET", "/repos/\(Self.upstream)/contents/\(path)?ref=\(baseSHA)")).sha
        } catch GitHubError.api(let status, _) where status == 404 {
            fileSHA = nil  // first list of this type
        }
        if fileSHA != nil {
            let rawURL = URL(string: "https://raw.githubusercontent.com/\(Self.upstream)/\(baseSHA)/\(path)")!
            let (data, response) = try await URLSession.shared.data(from: rawURL)
            // Never commit a merge built on a file we failed to read — it would wipe the list
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                throw GitHubError.api(status: (response as? HTTPURLResponse)?.statusCode ?? -1, message: "Couldn't read your current list file")
            }
            existingText = text
        }

        let merge = await Task.detached(priority: .userInitiated) {
            ListFileMerger.merge(existing: existingText, newLines: lines, blockTitle: blockTitle, appendOnly: appendOnly)
        }.value

        guard !merge.placements.isEmpty else {
            throw GitHubError.api(status: 409, message: "Your list file already has all of these lines")
        }

        // 2. Fork (idempotent — returns the existing fork if there is one)
        struct Repo: Decodable { let full_name: String }
        let fork = try JSONDecoder().decode(Repo.self, from: try await api("POST", "/repos/\(Self.upstream)/forks", body: [
            "default_branch_only": true,
        ])).full_name
        var forkReady = false
        for _ in 0..<15 {
            if (try? await api("GET", "/repos/\(fork)")) != nil { forkReady = true; break }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        guard forkReady else { throw GitHubError.forkNotReady }

        // 3. Branch at the upstream head. Forks share the network's object store, but a
        //    long-stale fork may need syncing before the ref can point at that commit.
        let branch = "tm-app-\(Self.branchStamp())"
        let refBody: [String: Any] = ["ref": "refs/heads/\(branch)", "sha": baseSHA]
        do {
            _ = try await api("POST", "/repos/\(fork)/git/refs", body: refBody)
        } catch GitHubError.api(let status, _) where status == 422 {
            _ = try? await api("POST", "/repos/\(fork)/merge-upstream", body: ["branch": "master"])
            _ = try await api("POST", "/repos/\(fork)/git/refs", body: refBody)
        }

        // 4. Commit the merged file
        let names = tripNames.prefix(3).joined(separator: ", ") + (tripNames.count > 3 ? " +\(tripNames.count - 3) more" : "")
        var commit: [String: Any] = [
            "message": "Update \(username).\(category.fileExtension): \(merge.placements.count) segment\(merge.placements.count == 1 ? "" : "s") from \(names)",
            "content": Data(merge.text.utf8).base64EncodedString(),
            "branch": branch,
        ]
        if let fileSHA { commit["sha"] = fileSHA }
        _ = try await api("PUT", "/repos/\(fork)/contents/\(path)", body: commit)

        // 5. Pull request
        let lineList = merge.placements.map { "- `\($0.line.text)`" }.joined(separator: "\n")
        let prBody = """
        Adds \(merge.placements.count) segment\(merge.placements.count == 1 ? "" : "s") recorded with GPS in the Travel Mapping iOS app (\(names)).

        \(lineList)

        Existing lines are unchanged; new lines were placed alongside similar routes.
        """
        struct PR: Decodable { let number: Int; let html_url: URL }
        let pr = try JSONDecoder().decode(PR.self, from: try await api("POST", "/repos/\(Self.upstream)/pulls", body: [
            "title": "\(username): add \(merge.placements.count) recorded segment\(merge.placements.count == 1 ? "" : "s")",
            "head": "\(login):\(branch)",
            "base": "master",
            "body": prBody,
            "maintainer_can_modify": true,
        ]))

        let crumb = Breadcrumb(level: .info, category: "github")
        crumb.message = "Opened list update PR #\(pr.number) (\(merge.placements.count) lines)"
        SentrySDK.addBreadcrumb(crumb)

        return (ListUpdatePR(number: pr.number, url: pr.html_url, createdAt: Date(), lineCount: merge.placements.count), merge)
    }

    /// Works signed out too (public repo), subject to the unauthenticated rate limit.
    func pullRequestState(_ number: Int) async throws -> PRState {
        struct PR: Decodable { let state: String; let merged_at: String? }
        let pr = try JSONDecoder().decode(PR.self, from: try await api("GET", "/repos/\(Self.upstream)/pulls/\(number)"))
        if pr.merged_at != nil { return .merged }
        return pr.state == "open" ? .open : .closed
    }

    // MARK: HTTP

    private func api(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            if status == 401 { signOut() }
            struct Message: Decodable { let message: String? }
            let message = (try? JSONDecoder().decode(Message.self, from: data))?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
            let error = GitHubError.api(status: status, message: message)
            if status != 404 {
                SentrySDK.capture(error: error) { scope in
                    scope.setTag(value: method, key: "github.method")
                    scope.setExtra(value: path.components(separatedBy: "?").first ?? path, key: "github.path")
                }
            }
            throw error
        }
        return data
    }

    private func formPost(_ url: String, _ fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw GitHubError.api(status: status, message: HTTPURLResponse.localizedString(forStatusCode: status))
        }
        return data
    }

    private static func branchStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: Keychain

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "oauth-token",
        ]
    }

    private static func readToken() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveToken(_ token: String) {
        deleteToken()
        var query = keychainQuery
        query[kSecValueData as String] = Data(token.utf8)
        // This device only — never synced to iCloud Keychain or restored to another device
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func deleteToken() {
        SecItemDelete(keychainQuery as CFDictionary)
    }
}
