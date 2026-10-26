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
        // raw.githubusercontent.com/…/master is CDN-cached for ~5 minutes regardless of
        // request cache policy; pin to the head commit so a just-merged change is never
        // missing from the file the user pastes back over the original.
        var ref = "master"
        var headRequest = URLRequest(url: URL(string: "https://api.github.com/repos/TravelMapping/UserData/commits/master")!)
        headRequest.setValue("application/vnd.github.sha", forHTTPHeaderField: "Accept")
        headRequest.cachePolicy = .reloadIgnoringLocalCacheData
        if let (shaData, shaResponse) = try? await URLSession.shared.data(for: headRequest),
           (shaResponse as? HTTPURLResponse)?.statusCode == 200,
           let sha = String(data: shaData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           sha.count == 40 {
            ref = sha
        }
        let url = URL(string: "https://raw.githubusercontent.com/TravelMapping/UserData/\(ref)/\(category.directoryName)/\(username).\(category.fileExtension)")!
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
    var lineCount: Int
    /// Head branch and fork ("login/UserData"), so later updates can be added to
    /// this PR while it's still open instead of opening a conflicting second one
    var branch: String?
    var fork: String?
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

    @Published private var token: String?

    enum GitHubError: LocalizedError {
        case notConfigured
        case notSignedIn
        case expired
        case denied
        case api(status: Int, message: String)
        case forkNotReady
        case nothingNew

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "GitHub sign-in isn't available in this build."
            case .notSignedIn: return "Sign in with GitHub first."
            case .expired: return "The sign-in code expired. Start again."
            case .denied: return "GitHub sign-in was cancelled."
            case .api(let status, let message): return "GitHub returned \(status): \(message)"
            case .forkNotReady: return "GitHub is still creating your fork. Try again in a minute."
            case .nothingNew: return "Your list file already has all of these lines."
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
            let data: Data
            do {
                data = try await formPost("https://github.com/login/oauth/access_token", [
                    "client_id": Self.clientID,
                    "device_code": code.device_code,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ])
            } catch let error as URLError where error.code != .cancelled {
                // "Copy Code & Open GitHub" backgrounds the app, and the first request
                // after resuming often fails (-1005). Keep polling — failing here would
                // throw away the code the user just approved.
                continue
            }
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)
            if let accessToken = response.access_token {
                token = accessToken
                Self.saveToken(accessToken)
                try? await refreshLogin()  // login is re-fetched lazily if this fails
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

    /// Fills in the GitHub username if sign-in stored the token but couldn't fetch it.
    func ensureLogin() async {
        if isSignedIn && login == nil { try? await refreshLogin() }
    }

    private func refreshLogin() async throws {
        struct User: Decodable { let login: String }
        let user = try JSONDecoder().decode(User.self, from: try await api("GET", "/user"))
        login = user.login
        UserDefaults.standard.set(user.login, forKey: "githubLogin")
    }

    // MARK: Pull requests

    /// Merges `lines` into the user's list file and sends it as a pull request.
    /// With an `openPR` still open, the lines are committed to that PR's branch (on top
    /// of what it already adds); otherwise a fresh branch is cut from upstream master.
    func submitListUpdate(
        username: String,
        category: RouteCategory,
        lines: [ListLine],
        blockTitle: String,
        appendOnly: Bool,
        tripNames: [String],
        appendingTo openPR: ListUpdatePR?
    ) async throws -> (pr: ListUpdatePR, merge: ListFileMerger.Result) {
        guard isSignedIn else { throw GitHubError.notSignedIn }
        let path = "\(category.directoryName)/\(username).\(category.fileExtension)"
        let names = tripNames.prefix(3).joined(separator: ", ") + (tripNames.count > 3 ? " +\(tripNames.count - 3) more" : "")

        // A transient failure here must surface, not fall through to a second PR; only a
        // deleted branch (404) means the open PR can no longer take commits.
        var openBranchSHA: String?
        if let openPR, let fork = openPR.fork, let branch = openPR.branch {
            do {
                openBranchSHA = try await refSHA(repo: fork, branch: branch, quiet: true)
            } catch GitHubError.api(let status, _) where status == 404 {
                openBranchSHA = nil
            }
        }
        if let openPR, let fork = openPR.fork, let branch = openPR.branch, let headSHA = openBranchSHA {
            let file = try await readFile(repo: fork, sha: headSHA, path: path)
            let merge = await Self.merge(file.text, lines, blockTitle, appendOnly)
            guard !merge.placements.isEmpty else { throw GitHubError.nothingNew }
            try await commit(repo: fork, branch: branch, path: path, text: merge.text, fileSHA: file.sha,
                             message: "Add \(merge.placements.count) more segment\(merge.placements.count == 1 ? "" : "s") from \(names)")
            var updated = openPR
            updated.lineCount += merge.placements.count
            breadcrumb("Added \(merge.placements.count) lines to PR #\(openPR.number)")
            return (updated, merge)
        }

        // 1. Upstream head + current file at that exact commit (no CDN staleness)
        let baseSHA = try await refSHA(repo: Self.upstream, branch: "master")
        let file = try await readFile(repo: Self.upstream, sha: baseSHA, path: path)
        let merge = await Self.merge(file.text, lines, blockTitle, appendOnly)
        guard !merge.placements.isEmpty else { throw GitHubError.nothingNew }

        // 2. Fork (idempotent — returns the existing fork if there is one)
        struct Repo: Decodable {
            struct Owner: Decodable { let login: String }
            let full_name: String
            let owner: Owner
        }
        let forkRepo = try JSONDecoder().decode(Repo.self, from: try await api("POST", "/repos/\(Self.upstream)/forks", body: [
            "default_branch_only": true,
        ]))
        let fork = forkRepo.full_name

        // A brand-new fork answers GET /repos before its git data exists; wait for the
        // default branch itself to resolve before creating refs on it.
        var forkReady = false
        for _ in 0..<20 {
            if (try? await refSHA(repo: fork, branch: "master", quiet: true)) != nil { forkReady = true; break }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        guard forkReady else { throw GitHubError.forkNotReady }

        // 3. Branch at the upstream head. Forks share the network's object store, but a
        //    long-stale fork may need syncing before the ref can point at that commit.
        let branch = "tm-app-\(Self.branchStamp())"
        let refBody: [String: Any] = ["ref": "refs/heads/\(branch)", "sha": baseSHA]
        var created = false
        for attempt in 0..<4 where !created {
            do {
                _ = try await api("POST", "/repos/\(fork)/git/refs", body: refBody, quietStatuses: [404, 409, 422])
                created = true
            } catch GitHubError.api(let status, _) where [404, 409, 422].contains(status) && attempt < 3 {
                if status == 422 {
                    _ = try? await api("POST", "/repos/\(fork)/merge-upstream", body: ["branch": "master"], quietStatuses: [409, 422])
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        // 4. Commit the merged file
        try await commit(repo: fork, branch: branch, path: path, text: merge.text, fileSHA: file.sha,
                         message: "Update \(username).\(category.fileExtension): \(merge.placements.count) segment\(merge.placements.count == 1 ? "" : "s") from \(names)")

        // 5. Pull request — head owner from the fork itself (survives GitHub renames)
        let lineList = merge.placements.map { "- `\($0.line.text)`" }.joined(separator: "\n")
        let prBody = """
        Adds \(merge.placements.count) segment\(merge.placements.count == 1 ? "" : "s") recorded with GPS in the Travel Mapping iOS app (\(names)).

        \(lineList)

        Existing lines are unchanged; new lines were placed alongside similar routes.
        """
        struct PR: Decodable { let number: Int; let html_url: URL }
        let pr = try JSONDecoder().decode(PR.self, from: try await api("POST", "/repos/\(Self.upstream)/pulls", body: [
            "title": "\(username): add \(merge.placements.count) recorded segment\(merge.placements.count == 1 ? "" : "s")",
            "head": "\(forkRepo.owner.login):\(branch)",
            "base": "master",
            "body": prBody,
            "maintainer_can_modify": true,
        ]))
        login = forkRepo.owner.login
        UserDefaults.standard.set(forkRepo.owner.login, forKey: "githubLogin")

        breadcrumb("Opened list update PR #\(pr.number) (\(merge.placements.count) lines)")
        return (ListUpdatePR(number: pr.number, url: pr.html_url, createdAt: Date(), lineCount: merge.placements.count,
                             branch: branch, fork: fork), merge)
    }

    private func refSHA(repo: String, branch: String, quiet: Bool = false) async throws -> String {
        struct Ref: Decodable { struct Object: Decodable { let sha: String }; let object: Object }
        let data = try await api("GET", "/repos/\(repo)/git/ref/heads/\(branch)", quietStatuses: quiet ? [404, 409] : [])
        return try JSONDecoder().decode(Ref.self, from: data).object.sha
    }

    /// File text + blob SHA at an exact commit. Text comes from the commit-pinned raw URL
    /// (the contents API omits bodies over 1 MB). Throws rather than ever returning an
    /// empty stand-in for a file that exists but couldn't be read — committing a merge
    /// built on that would wipe the user's list.
    private func readFile(repo: String, sha: String, path: String) async throws -> (text: String, sha: String?) {
        struct Contents: Decodable { let sha: String; let size: Int }
        let contents: Contents
        do {
            contents = try JSONDecoder().decode(Contents.self, from: try await api("GET", "/repos/\(repo)/contents/\(path)?ref=\(sha)"))
        } catch GitHubError.api(let status, _) where status == 404 {
            return ("", nil)  // first list of this type
        }
        let rawURL = URL(string: "https://raw.githubusercontent.com/\(repo)/\(sha)/\(path)")!
        let (data, response) = try await URLSession.shared.data(from: rawURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty || contents.size == 0 else {
            throw GitHubError.api(status: (response as? HTTPURLResponse)?.statusCode ?? -1, message: "Couldn't read your current list file")
        }
        return (text, contents.sha)
    }

    private func commit(repo: String, branch: String, path: String, text: String, fileSHA: String?, message: String) async throws {
        var body: [String: Any] = [
            "message": message,
            "content": Data(text.utf8).base64EncodedString(),
            "branch": branch,
        ]
        if let fileSHA { body["sha"] = fileSHA }
        _ = try await api("PUT", "/repos/\(repo)/contents/\(path)", body: body)
    }

    private nonisolated static func merge(_ text: String, _ lines: [ListLine], _ blockTitle: String, _ appendOnly: Bool) async -> ListFileMerger.Result {
        await Task.detached(priority: .userInitiated) {
            ListFileMerger.merge(existing: text, newLines: lines, blockTitle: blockTitle, appendOnly: appendOnly)
        }.value
    }

    private func breadcrumb(_ message: String) {
        let crumb = Breadcrumb(level: .info, category: "github")
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Works signed out too (public repo), subject to the unauthenticated rate limit.
    func pullRequestState(_ number: Int) async throws -> PRState {
        struct PR: Decodable { let state: String; let merged_at: String? }
        let pr = try JSONDecoder().decode(PR.self, from: try await api("GET", "/repos/\(Self.upstream)/pulls/\(number)"))
        if pr.merged_at != nil { return .merged }
        return pr.state == "open" ? .open : .closed
    }

    // MARK: HTTP

    /// `quietStatuses` are expected failures the caller handles — not worth a Sentry issue.
    private func api(_ method: String, _ path: String, body: [String: Any]? = nil, quietStatuses: Set<Int> = []) async throws -> Data {
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
            if status != 404 && !quietStatuses.contains(status) {
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

// MARK: - AI assistant (bring your own key)

/// AI providers the user can connect with their own API key. The app never ships a key
/// and never pays for usage — requests go straight from the device to the provider and
/// bill to the user's own account.
enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case anthropic, openai, xai, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai: return "ChatGPT (OpenAI)"
        case .xai: return "Grok (xAI)"
        case .custom: return "Other (OpenAI-compatible)"
        }
    }

    var companyName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .xai: return "xAI"
        case .custom: return "the service you entered"
        }
    }

    /// API base including version path; custom providers supply their own
    var defaultBaseURL: String? {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .xai: return "https://api.x.ai/v1"
        case .custom: return nil
        }
    }

    var keysPageURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .xai: return URL(string: "https://console.x.ai")
        case .custom: return nil
        }
    }

    var privacyPolicyURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://www.anthropic.com/legal/privacy")
        case .openai: return URL(string: "https://openai.com/policies/privacy-policy/")
        case .xai: return URL(string: "https://x.ai/legal/privacy-policy")
        case .custom: return nil
        }
    }

    /// Preselected after the key is verified; any model the key can use may be chosen
    var suggestedModel: String? {
        self == .anthropic ? "claude-opus-5-5" : nil
    }
}

/// One AI request, kept on this device so the user can see exactly what was sent.
struct AIActivityEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let feature: String
    let provider: String
    let host: String
    let model: String
    /// Plain-language description of what was sent
    let sentSummary: String
    let charactersSent: Int
    var outcome: String
}

/// Bring-your-own-key AI client. AI features stay hidden unless the user has saved a key,
/// agreed to the data-sharing disclosure for that exact provider and host, and left the
/// master switch on (App Store Review Guideline 5.1.2(i): explicit permission before
/// personal data goes to a third-party AI).
@MainActor
final class AIService: ObservableObject {
    static let shared = AIService()

    enum AIError: LocalizedError {
        case notReady
        case badBaseURL
        case http(status: Int, message: String)
        case refused(String?)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .notReady: return "Turn on AI Assistant in Settings first."
            case .badBaseURL: return "That API address isn't a valid https URL."
            case .http(let status, let message):
                if status == 401 || status == 403 { return "The provider rejected the API key (\(status)). Check it in Settings › AI Assistant." }
                if status == 429 { return "Rate limited or out of credit with the provider (429): \(message)" }
                return "The AI provider returned \(status): \(message)"
            case .refused(let category): return "The model declined this request\(category.map { " (\($0))" } ?? "")."
            case .emptyResponse: return "The AI returned an empty answer."
            }
        }
    }

    @Published private(set) var provider: AIProvider?
    @Published private(set) var hasKey = false
    @Published var model: String { didSet { defaults.set(model, forKey: "aiModel") } }
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "aiEnabled") } }
    @Published private(set) var consentDate: Date?
    @Published private(set) var activity: [AIActivityEntry] = []

    private let defaults = UserDefaults.standard
    private var customBaseURL: String
    private static let keychainService = "com.psiegel18.TravelMapping.ai"

    /// Everything a feature needs before it may send anything
    var isReady: Bool { isEnabled && hasKey && provider != nil && consentDate != nil && !model.isEmpty }

    var baseURL: String? {
        guard let provider else { return nil }
        return provider == .custom ? customBaseURL : provider.defaultBaseURL
    }

    var host: String { baseURL.flatMap { URL(string: $0)?.host } ?? "" }

    /// Short label for buttons: "Claude (Anthropic)" / host for custom
    var providerLabel: String {
        guard let provider else { return "AI" }
        return provider == .custom ? host : provider.displayName
    }

    private init() {
        provider = defaults.string(forKey: "aiProvider").flatMap(AIProvider.init(rawValue:))
        customBaseURL = defaults.string(forKey: "aiBaseURL") ?? ""
        model = defaults.string(forKey: "aiModel") ?? ""
        isEnabled = defaults.object(forKey: "aiEnabled") as? Bool ?? true
        hasKey = Self.readKey() != nil
        // Consent is tied to the provider + host it was given for
        if let stored = defaults.string(forKey: "aiConsentScope"), stored == consentScope,
           let date = defaults.object(forKey: "aiConsentDate") as? Date {
            consentDate = date
        }
        if let data = defaults.data(forKey: "aiActivity"),
           let entries = try? JSONDecoder().decode([AIActivityEntry].self, from: data) {
            activity = entries
        }
    }

    private var consentScope: String { "\(provider?.rawValue ?? "")|\(host)" }

    // MARK: Setup

    /// Verifies the key by listing models, then stores it. Returns the model IDs the key can use.
    func connect(provider: AIProvider, key: String, customBaseURL: String) async throws -> [String] {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = provider == .custom
            ? customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : (provider.defaultBaseURL ?? "")
        guard let url = URL(string: base), url.scheme == "https", url.host != nil else { throw AIError.badBaseURL }

        let models = try await Self.listModels(provider: provider, baseURL: base, key: trimmedKey)

        let scopeChanged = provider != self.provider || base != baseURL
        self.provider = provider
        self.customBaseURL = base
        defaults.set(provider.rawValue, forKey: "aiProvider")
        defaults.set(base, forKey: "aiBaseURL")
        Self.saveKey(trimmedKey)
        hasKey = true
        if scopeChanged { revokeConsent() }
        if model.isEmpty || !models.contains(model) || scopeChanged {
            model = provider.suggestedModel.flatMap { models.contains($0) ? $0 : nil } ?? models.first ?? ""
        }
        return models
    }

    func availableModels() async throws -> [String] {
        guard let provider, let baseURL, let key = Self.readKey() else { throw AIError.notReady }
        return try await Self.listModels(provider: provider, baseURL: baseURL, key: key)
    }

    func grantConsent() {
        consentDate = Date()
        defaults.set(consentScope, forKey: "aiConsentScope")
        defaults.set(consentDate, forKey: "aiConsentDate")
    }

    func revokeConsent() {
        consentDate = nil
        defaults.removeObject(forKey: "aiConsentScope")
        defaults.removeObject(forKey: "aiConsentDate")
    }

    /// Removes the key and everything tied to it. AI features disappear immediately.
    func removeKey() {
        Self.deleteKey()
        hasKey = false
        provider = nil
        customBaseURL = ""
        model = ""
        revokeConsent()
        for key in ["aiProvider", "aiBaseURL", "aiModel"] { defaults.removeObject(forKey: key) }
    }

    func clearActivity() {
        activity = []
        defaults.removeObject(forKey: "aiActivity")
    }

    // MARK: Requests

    /// Sends one prompt and returns the text answer. `sentSummary` is what the activity
    /// log shows — describe the data in plain words. Cancelling the calling Task cancels
    /// the request.
    func complete(system: String, prompt: String, feature: String, sentSummary: String) async throws -> String {
        guard isReady, let provider, let baseURL, let key = Self.readKey() else { throw AIError.notReady }
        var entry = AIActivityEntry(id: UUID(), date: Date(), feature: feature, provider: provider.displayName,
                                    host: host, model: model, sentSummary: sentSummary,
                                    charactersSent: system.count + prompt.count, outcome: "Sending…")
        record(entry)
        do {
            let text = provider == .anthropic
                ? try await Self.anthropicMessage(baseURL: baseURL, key: key, model: model, system: system, prompt: prompt)
                : try await Self.chatCompletion(baseURL: baseURL, key: key, model: model, system: system, prompt: prompt)
            entry.outcome = "Answered"
            record(entry)
            return text
        } catch {
            entry.outcome = (error as? URLError)?.code == .cancelled || error is CancellationError ? "Cancelled" : "Failed"
            record(entry)
            throw error
        }
    }

    private func record(_ entry: AIActivityEntry) {
        if let i = activity.firstIndex(where: { $0.id == entry.id }) {
            activity[i] = entry
        } else {
            activity.insert(entry, at: 0)
            if activity.count > 50 { activity.removeLast(activity.count - 50) }
        }
        if let data = try? JSONEncoder().encode(activity) { defaults.set(data, forKey: "aiActivity") }
    }

    // MARK: Provider HTTP

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral  // no disk cache of prompts or answers
        config.timeoutIntervalForRequest = 180
        return URLSession(configuration: config)
    }()

    private static func listModels(provider: AIProvider, baseURL: String, key: String) async throws -> [String] {
        var request = URLRequest(url: URL(string: "\(baseURL)/models")!)
        authorize(&request, provider: provider, key: key)
        let data = try await send(request)
        struct List: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        let ids = (try? JSONDecoder().decode(List.self, from: data))?.data.map(\.id) ?? []
        return ids.sorted()
    }

    /// Claude Messages API. Opus 5.x / Fable 5.1 / Sonnet 5.5 get server-side refusal
    /// fallbacks so a safety decline is retried on Anthropic's recommended model.
    private static func anthropicMessage(baseURL: String, key: String, model: String, system: String, prompt: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(baseURL)/messages")!)
        request.httpMethod = "POST"
        authorize(&request, provider: .anthropic, key: key)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        let fallbackModels = ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"]
        if fallbackModels.contains(model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)

        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            struct StopDetails: Decodable { let category: String? }
            let content: [Block]
            let stop_reason: String?
            let stop_details: StopDetails?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.stop_reason == "refusal" { throw AIError.refused(response.stop_details?.category) }
        let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw AIError.emptyResponse }
        return text
    }

    /// OpenAI-style Chat Completions — OpenAI, xAI, and compatible services.
    private static func chatCompletion(baseURL: String, key: String, model: String, system: String, prompt: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        authorize(&request, provider: .openai, key: key)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt],
            ],
        ])
        let data = try await send(request)
        struct Response: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String?; let refusal: String? }; let message: Message }
            let choices: [Choice]
        }
        let message = try JSONDecoder().decode(Response.self, from: data).choices.first?.message
        if let refusal = message?.refusal, !refusal.isEmpty { throw AIError.refused(nil) }
        guard let text = message?.content, !text.isEmpty else { throw AIError.emptyResponse }
        return text
    }

    private static func authorize(_ request: inout URLRequest, provider: AIProvider, key: String) {
        if provider == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            // Provider error bodies vary: {"error":{"message":…}} or {"error":"…"}
            var message = HTTPURLResponse.localizedString(forStatusCode: status)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? [String: Any], let m = error["message"] as? String { message = m }
                else if let m = json["error"] as? String { message = m }
            }
            // Deliberately not sent to Sentry: these are the user's own account/config
            throw AIError.http(status: status, message: String(message.prefix(200)))
        }
        return data
    }

    // MARK: Keychain

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "api-key",
        ]
    }

    private static func readKey() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveKey(_ key: String) {
        deleteKey()
        var query = keychainQuery
        query[kSecValueData as String] = Data(key.utf8)
        // This device only — never synced to iCloud Keychain or restored elsewhere
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func deleteKey() {
        SecItemDelete(keychainQuery as CFDictionary)
    }
}
