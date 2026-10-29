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

// MARK: - Keychain

/// A generic-password Keychain item that either stays on this device or syncs, end-to-end
/// encrypted, to the user's other devices through iCloud Keychain.
struct KeychainItem {
    let service: String
    let account: String

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Finds the item whether it was saved device-only or synced.
    func read() -> (value: String, synced: Bool)? {
        var query = base
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        let synced = (attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
        return (value, synced)
    }

    /// Replaces any existing copy. Returns whether the item ended up synced — iCloud
    /// Keychain can be unavailable (signed out, or turned off), in which case it falls
    /// back to device-only rather than losing the value.
    @discardableResult
    func save(_ value: String, synced: Bool) -> Bool {
        delete()
        if synced, add(value, synced: true) == errSecSuccess { return true }
        _ = add(value, synced: false)
        return false
    }

    /// Deletes this device's copy and, when synced, the copy on every other device.
    func delete() {
        var query = base
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(query as CFDictionary)
    }

    private func add(_ value: String, synced: Bool) -> OSStatus {
        var query = base
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrSynchronizable as String] = synced
        // Synced items can't use a ThisDeviceOnly class; device-only items never leave
        // this device, not even in backups restored to another one.
        query[kSecAttrAccessible as String] = synced
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
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
    /// A draft isn't up for review until the user marks it ready on GitHub
    var isDraft: Bool? = nil
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
    /// Whether the token syncs to the user's other devices via iCloud Keychain (opt-in)
    @Published private(set) var syncsAcrossDevices = false

    private static let tokenItem = KeychainItem(service: keychainService, account: "oauth-token")

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
        /// `draft` is open but not yet up for review — the user marks it ready on GitHub
        case open, draft, merged, closed
        var isOpen: Bool { self == .open || self == .draft }
    }

    private init() {
        if let stored = Self.tokenItem.read() {
            token = stored.value
            syncsAcrossDevices = stored.synced
        }
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
                syncsAcrossDevices = Self.tokenItem.save(accessToken, synced: syncsAcrossDevices)
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
        Self.tokenItem.delete()
        syncsAcrossDevices = false
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
        replacements: [String: String] = [:],
        appendingTo openPR: ListUpdatePR?,
        asDraft: Bool = false,
        title customTitle: String? = nil
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
        if let openPR, let fork = openPR.fork, let branch = openPR.branch, var headSHA = openBranchSHA {
            // A PR can sit for days: merge upstream master into its branch first, so this
            // update builds on the current file (lines added on github.com since, other
            // fixes) rather than the copy the branch was cut from. A conflict (409) leaves
            // the branch as it was.
            if let upstreamSHA = try? await refSHA(repo: Self.upstream, branch: "master"),
               let data = try? await api("POST", "/repos/\(fork)/merges", body: [
                   "base": branch, "head": upstreamSHA,
                   "commit_message": "Merge TravelMapping/UserData master",
               ], quietStatuses: [403, 404, 409, 422]) {
                struct Merge: Decodable { let sha: String }
                // 204 (already up to date) has an empty body; keep the old head then
                if let merged = try? JSONDecoder().decode(Merge.self, from: data) { headSHA = merged.sha }
            }
            let file = try await readFile(repo: fork, sha: headSHA, path: path)
            let (fixedText, fixed) = ListFileMerger.applyReplacements(file.text, replacements)
            let merge = await Self.merge(fixedText, lines, blockTitle, appendOnly)
            guard !merge.placements.isEmpty || !fixed.isEmpty else { throw GitHubError.nothingNew }
            try await commit(repo: fork, branch: branch, path: path, text: merge.text, fileSHA: file.sha,
                             message: Self.commitSummary(added: merge.placements.count, fixed: fixed.count, from: names, more: true))
            await refreshDescription(number: openPR.number, username: username, fileExtension: category.fileExtension,
                                     section: Self.describe(merge: merge, fixed: fixed, replacements: replacements, names: names),
                                     added: merge.placements.count, fixed: fixed.count, customTitle: customTitle)
            var updated = openPR
            updated.lineCount += merge.placements.count + fixed.count
            breadcrumb("Added \(merge.placements.count) lines to PR #\(openPR.number)")
            return (updated, merge)
        }

        // 1. Upstream head + current file at that exact commit (no CDN staleness)
        let baseSHA = try await refSHA(repo: Self.upstream, branch: "master")
        let file = try await readFile(repo: Self.upstream, sha: baseSHA, path: path)
        let (fixedText, fixed) = ListFileMerger.applyReplacements(file.text, replacements)
        let merge = await Self.merge(fixedText, lines, blockTitle, appendOnly)
        guard !merge.placements.isEmpty || !fixed.isEmpty else { throw GitHubError.nothingNew }

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
                         message: "Update \(username).\(category.fileExtension): " + Self.commitSummary(added: merge.placements.count, fixed: fixed.count, from: names, more: false))

        // 5. Pull request — head owner from the fork itself (survives GitHub renames)
        let prBody = Self.describe(merge: merge, fixed: fixed, replacements: replacements, names: names)
        struct PR: Decodable { let number: Int; let html_url: URL }
        let pr = try JSONDecoder().decode(PR.self, from: try await api("POST", "/repos/\(Self.upstream)/pulls", body: [
            "title": customTitle ?? Self.autoTitle(username: username, added: merge.placements.count, fixed: fixed.count,
                                                    fileExtensions: [category.fileExtension]),
            "head": "\(forkRepo.owner.login):\(branch)",
            "base": "master",
            "body": prBody,
            "maintainer_can_modify": true,
            // A draft isn't up for review until the user marks it ready on GitHub
            "draft": asDraft,
        ]))
        login = forkRepo.owner.login
        UserDefaults.standard.set(forkRepo.owner.login, forKey: "githubLogin")

        breadcrumb("Opened list update PR #\(pr.number) (\(merge.placements.count) lines)")
        return (ListUpdatePR(number: pr.number, url: pr.html_url, createdAt: Date(), lineCount: merge.placements.count + fixed.count,
                             branch: branch, fork: fork, isDraft: asDraft), merge)
    }

    /// PR description for one update: the segments it adds and the lines it fixes
    private static func describe(merge: ListFileMerger.Result, fixed: [String], replacements: [String: String], names: String) -> String {
        var sections: [String] = []
        if !merge.placements.isEmpty {
            sections.append("Adds \(merge.placements.count) segment\(merge.placements.count == 1 ? "" : "s") recorded with GPS in the Travel Mapping iOS app (\(names)):\n\n"
                + merge.placements.map { placement in
                    guard let ext = placement.extended else { return "- `\(placement.line.text)`" }
                    let merged = placement.absorbed.isEmpty ? "" : "; merges and removes " + placement.absorbed.map { "`\($0)`" }.joined(separator: ", ")
                    return "- `\(ext.from)` → `\(ext.to)` (extended to cover `\(placement.line.text)`\(merged))"
                }.joined(separator: "\n")
                + "\n\nNew lines were placed alongside similar routes.")
        }
        if !fixed.isEmpty {
            sections.append("Fixes \(fixed.count) line\(fixed.count == 1 ? "" : "s") flagged in the TravelMapping site-update log:\n\n"
                + fixed.map { old in
                    let new = replacements.first { ListFileMerger.normalizedLine($0.key) == old }?.value ?? ""
                    return "- `\(old)` → `\(new)`"
                }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// The title the app gives a PR, e.g. "psiegel18: Add 8 lines, fix 1 line (list + rlist)".
    /// `fileExtensions` lists the files the PR changes; two get named in the title.
    static func autoTitle(username: String, added: Int, fixed: Int, fileExtensions: [String]) -> String {
        var parts: [String] = []
        if added > 0 { parts.append("add \(added) line\(added == 1 ? "" : "s")") }
        if fixed > 0 { parts.append("fix \(fixed) line\(fixed == 1 ? "" : "s")") }
        var summary = parts.isEmpty ? "update list" : parts.joined(separator: ", ")
        summary = summary.prefix(1).uppercased() + summary.dropFirst()
        let files = Set(fileExtensions).sorted()
        if files.count > 1 { summary += " (" + files.joined(separator: " + ") + ")" }
        return "\(username): \(summary)"
    }

    /// A title the app wrote (so it's safe to rewrite), not one the user typed
    static func isAutoTitle(_ title: String, username: String) -> Bool {
        title.hasPrefix("\(username): ")
            && title.dropFirst(username.count + 2).range(of: #"^((Add|Fix) \d+ |Update list)"#, options: .regularExpression) != nil
    }

    /// Current title of a PR, to prefill the title field when adding to it
    func pullRequestTitle(_ number: Int) async -> String? {
        struct PR: Decodable { let title: String }
        guard let data = try? await api("GET", "/repos/\(Self.upstream)/pulls/\(number)", quietStatuses: [403, 404, 429, 503]) else { return nil }
        return (try? JSONDecoder().decode(PR.self, from: data))?.title
    }

    /// After commits land on an open PR, keep its title and description in step: the new
    /// commit's changes are appended to the description, and an app-written title has
    /// this send's `added`/`fixed` counts added to its own. A title the user typed is kept
    /// (or replaced by `customTitle` when they edited it this time). Best effort — the
    /// commit already landed.
    private func refreshDescription(number: Int, username: String, fileExtension: String, section: String,
                                    added: Int, fixed: Int, customTitle: String?) async {
        struct PR: Decodable { let title: String; let body: String? }
        struct File: Decodable { let filename: String }
        guard let prData = try? await api("GET", "/repos/\(Self.upstream)/pulls/\(number)", quietStatuses: [403, 404, 429, 503]),
              let pr = try? JSONDecoder().decode(PR.self, from: prData),
              let filesData = try? await api("GET", "/repos/\(Self.upstream)/pulls/\(number)/files?per_page=100", quietStatuses: [403, 404, 429, 503]),
              let files = try? JSONDecoder().decode([File].self, from: filesData) else { return }
        var title = pr.title
        if let customTitle {
            title = customTitle
        } else if Self.isAutoTitle(pr.title, username: username) {
            // Counts come from the titles the app wrote, not the diff: a widened line is a
            // deletion + an addition, which a diff count would call a fix
            let summary = pr.title.dropFirst(username.count + 2)
            func count(_ pattern: String) -> Int {
                guard let match = summary.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return 0 }
                return Int(summary[match].filter(\.isNumber)) ?? 0
            }
            title = Self.autoTitle(username: username, added: count(#"add \d+"#) + added, fixed: count(#"fix \d+"#) + fixed,
                                   fileExtensions: files.map { ($0.filename as NSString).pathExtension } + [fileExtension])
        }
        if title != pr.title {
            _ = try? await api("PATCH", "/repos/\(Self.upstream)/pulls/\(number)", body: ["title": title],
                               quietStatuses: [403, 404, 422, 429, 503])
        }
        // GitHub caps a description at 65,536 characters; past that, a one-line note
        let date = Date().formatted(date: .abbreviated, time: .omitted)
        var update = "**\(username).\(fileExtension)**, added \(date):\n\n\(section)"
        let existing = pr.body ?? ""
        if existing.count + update.count > 60_000 {
            update = "**\(username).\(fileExtension)**, added \(date): \(Self.commitSummary(added: added, fixed: fixed, from: nil, more: true)) — see the latest commit."
            guard existing.count + update.count <= 65_000 else { return }
        }
        let body = [existing, update].filter { !$0.isEmpty }.joined(separator: "\n\n---\n\n")
        _ = try? await api("PATCH", "/repos/\(Self.upstream)/pulls/\(number)", body: ["body": body],
                           quietStatuses: [403, 404, 422, 429, 503])
    }

    private static func commitSummary(added: Int, fixed: Int, from names: String?, more: Bool) -> String {
        var parts: [String] = []
        if added > 0 { parts.append("add \(added)\(more ? " more" : "") recorded segment\(added == 1 ? "" : "s")") }
        if fixed > 0 { parts.append("fix \(fixed) line\(fixed == 1 ? "" : "s")") }
        var summary = parts.joined(separator: ", ")
        if let names, added > 0, !names.isEmpty { summary += " from \(names)" }
        return summary.prefix(1).uppercased() + summary.dropFirst()
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
        struct PR: Decodable { let state: String; let merged_at: String?; let draft: Bool? }
        let pr = try JSONDecoder().decode(PR.self, from: try await api("GET", "/repos/\(Self.upstream)/pulls/\(number)"))
        if pr.merged_at != nil { return .merged }
        guard pr.state == "open" else { return .closed }
        return pr.draft == true ? .draft : .open
    }

    /// The signed-in user's newest open PR that the app opened (a "tm-app-" branch on their
    /// fork), from this or any other device. Later updates — roads, rail, checkup fixes —
    /// go onto it as more commits, so the TM team gets one PR instead of several.
    func latestOpenAppPR() async -> ListUpdatePR? {
        guard isSignedIn else { return nil }
        await ensureLogin()
        guard let login else { return nil }
        struct Search: Decodable {
            struct Item: Decodable { let number: Int }
            let items: [Item]
        }
        struct PR: Decodable {
            struct Head: Decodable {
                struct Repo: Decodable { let full_name: String }
                let ref: String
                let repo: Repo?
            }
            let number: Int
            let html_url: URL
            let created_at: Date
            let draft: Bool?
            let head: Head
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "q", value: "repo:\(Self.upstream) is:pr is:open author:\(login)")]
        guard let query = components.percentEncodedQuery,
              let data = try? await api("GET", "/search/issues?\(query)&sort=created&order=desc&per_page=5", quietStatuses: [403, 422, 429, 503]),
              let search = try? JSONDecoder().decode(Search.self, from: data) else { return nil }
        for item in search.items {
            guard let data = try? await api("GET", "/repos/\(Self.upstream)/pulls/\(item.number)", quietStatuses: [403, 404, 429, 503]),
                  let pr = try? decoder.decode(PR.self, from: data),
                  pr.head.ref.hasPrefix("tm-app-"), let fork = pr.head.repo?.full_name else { continue }
            return ListUpdatePR(number: pr.number, url: pr.html_url, createdAt: pr.created_at, lineCount: 0,
                                branch: pr.head.ref, fork: fork, isDraft: pr.draft)
        }
        return nil
    }

    /// Lines the signed-in user's open UserData PRs change or remove in their list file,
    /// keyed by `ListFileMerger.normalizedLine` (comment stripped). Covers PRs opened on
    /// any device or on github.com, so List Checkup can leave those lines alone.
    /// nil when GitHub couldn't be checked (offline, rate limited) — not the same as no PRs.
    func openPRChangedLines(username: String, category: RouteCategory) async -> [String: ListUpdatePR]? {
        guard isSignedIn else { return [:] }
        await ensureLogin()
        guard let login else { return nil }
        let path = "\(category.directoryName)/\(username).\(category.fileExtension)"

        struct Search: Decodable {
            struct Item: Decodable { let number: Int; let html_url: URL; let draft: Bool? }
            let items: [Item]
        }
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "q", value: "repo:\(Self.upstream) is:pr is:open author:\(login)")]
        guard let query = components.percentEncodedQuery,
              let data = try? await api("GET", "/search/issues?\(query)&sort=created&order=desc&per_page=10", quietStatuses: [403, 422, 429, 503]),
              let search = try? JSONDecoder().decode(Search.self, from: data) else { return nil }

        struct File: Decodable { let filename: String; let patch: String? }
        var changed: [String: ListUpdatePR] = [:]
        for item in search.items.prefix(5) {
            guard let data = try? await api("GET", "/repos/\(Self.upstream)/pulls/\(item.number)/files?per_page=100", quietStatuses: [403, 429, 503]),
                  let files = try? JSONDecoder().decode([File].self, from: data) else { return nil }
            guard let patch = files.first(where: { $0.filename == path })?.patch else { continue }
            let pr = ListUpdatePR(number: item.number, url: item.html_url, createdAt: Date(), lineCount: 0,
                                  branch: nil, fork: nil, isDraft: item.draft)
            for line in patch.components(separatedBy: "\n") where line.hasPrefix("-") && !line.hasPrefix("---") {
                // CRLF list files leave a trailing \r on each patch line
                let entry = line.dropFirst().trimmingCharacters(in: .newlines).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                let key = ListFileMerger.normalizedLine(entry)
                if !key.isEmpty { changed[key] = pr }
            }
        }
        return changed
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
                    scope.setExtra(value: Self.scrubbed(path, login: self.login), key: "github.path")
                }
            }
            throw error
        }
        return data
    }

    /// API path for Sentry without the user's GitHub login or list file name
    private static func scrubbed(_ path: String, login: String?) -> String {
        var path = path.components(separatedBy: "?").first ?? path
        if let login, !login.isEmpty { path = path.replacingOccurrences(of: "/repos/\(login)/", with: "/repos/{login}/") }
        return path.replacingOccurrences(of: #"/[^/]+\.(r?list)$"#, with: "/{user}.$1", options: .regularExpression)
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
        branchStampFormatter.string(from: Date())
    }

    private static let branchStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Persisted, so each cold launch doesn't re-run the cleanup
    private var nextBranchCleanup: Date {
        get { UserDefaults.standard.object(forKey: "githubNextBranchCleanup") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "githubNextBranchCleanup") }
    }

    /// What happens on the user's fork once an app pull request is finished
    /// (Settings › GitHub › Finished PRs). Stored per device.
    enum BranchCleanup: String, CaseIterable, Identifiable {
        case syncAndDelete, deleteOnly, off
        static let storageKey = "githubBranchCleanup"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .syncAndDelete: return "Delete & Update Fork"
            case .deleteOnly: return "Delete Branch Only"
            case .off: return "Leave Everything"
            }
        }
        static var current: BranchCleanup {
            UserDefaults.standard.string(forKey: storageKey).flatMap(BranchCleanup.init) ?? .syncAndDelete
        }
    }

    /// Tidies the app's "tm-app-" branches on the user's fork. When a branch's PR has been
    /// merged into TravelMapping/UserData, the fork's default branch is fast-forwarded to
    /// it first (only when that branch has no commits of its own) and then the branch is
    /// deleted. A branch whose
    /// PR was closed unmerged — or that never got a PR (a failed send) and is over a day
    /// old — is deleted without a sync. Branches with an open PR, and anything the app
    /// didn't create, are never touched. Runs at most every 6 hours; best effort.
    /// `BranchCleanup` can skip the fork update, or turn all of this off.
    func deleteFinishedBranches() async {
        let mode = BranchCleanup.current
        guard mode != .off, isSignedIn, Date() >= nextBranchCleanup else { return }
        nextBranchCleanup = Date().addingTimeInterval(6 * 3600)
        // Fresh login, not the cached one: after a GitHub rename the old name still
        // redirects for branches and deletes, but no longer matches its PRs, so every
        // branch would look PR-less. And only ever touch the real fork of UserData.
        try? await refreshLogin()
        guard let login else { return }
        struct Repo: Decodable {
            struct Owner: Decodable { let login: String }
            struct Parent: Decodable { let full_name: String }
            let full_name: String
            let owner: Owner
            let fork: Bool
            let parent: Parent?
            let default_branch: String
        }
        guard let repoData = try? await api("GET", "/repos/\(login)/UserData", quietStatuses: [403, 404, 429, 503]),
              let repo = try? JSONDecoder().decode(Repo.self, from: repoData),
              repo.fork, repo.parent?.full_name == Self.upstream, repo.owner.login == login else { return }
        let fork = repo.full_name
        struct Branch: Decodable { let name: String }
        struct PR: Decodable { let state: String; let merged_at: String? }
        guard let data = try? await api("GET", "/repos/\(fork)/branches?per_page=100", quietStatuses: [403, 404, 429, 503]),
              let branches = try? JSONDecoder().decode([Branch].self, from: data) else { return }

        var merged: [String] = []
        var abandoned: [String] = []
        for branch in branches.map(\.name) where branch.hasPrefix("tm-app-") {
            guard let prData = try? await api("GET", "/repos/\(Self.upstream)/pulls?state=all&head=\(login):\(branch)",
                                              quietStatuses: [403, 422, 429, 503]),
                  let prs = try? JSONDecoder().decode([PR].self, from: prData) else { return }
            if prs.contains(where: { $0.state == "open" }) { continue }
            if prs.contains(where: { $0.merged_at != nil }) {
                merged.append(branch)
            } else if !prs.isEmpty {
                abandoned.append(branch)
            } else if let created = Self.branchStampFormatter.date(from: String(branch.dropFirst("tm-app-".count))),
                      Date().timeIntervalSince(created) > 24 * 3600 {
                // No PR — a send that failed partway. Fresh ones may be another device mid-send.
                abandoned.append(branch)
            }
        }

        // Merged changes are in TravelMapping's master now: bring the fork's default branch
        // up to them before those branches go — but only as a fast-forward. If that branch
        // has commits of its own (work the user hasn't sent yet), it's left exactly as it
        // is: no merge commit on top of their work. The merged branches can still go, since
        // their changes are upstream. If GitHub can't be checked, keep them for a later try.
        var toDelete = abandoned
        if mode == .deleteOnly {
            toDelete += merged
        } else if !merged.isEmpty {
            struct Compare: Decodable { let ahead_by: Int }
            // ahead_by = commits on the fork's branch that TravelMapping's master lacks
            if let compareData = try? await api("GET", "/repos/\(Self.upstream)/compare/master...\(fork.replacingOccurrences(of: "/", with: ":")):\(repo.default_branch)",
                                                quietStatuses: [403, 404, 422, 429, 503]),
               let compare = try? JSONDecoder().decode(Compare.self, from: compareData) {
                if compare.ahead_by == 0 {
                    _ = try? await api("POST", "/repos/\(fork)/merge-upstream", body: ["branch": repo.default_branch],
                                       quietStatuses: [403, 404, 409, 422, 429, 503])
                } else {
                    breadcrumb("Fork's default branch has its own commits; not syncing it")
                }
                toDelete += merged
            }
        }
        var deleted = 0
        for branch in toDelete {
            if (try? await api("DELETE", "/repos/\(fork)/git/refs/heads/\(branch)", quietStatuses: [403, 404, 422, 429, 503])) != nil {
                deleted += 1
            }
        }
        if deleted > 0 { breadcrumb("Deleted \(deleted) finished app branches") }
    }

    /// Moves the token into (or out of) iCloud Keychain. Turning sync off signs the
    /// other devices out, since the synced copy is removed everywhere.
    func setSyncsAcrossDevices(_ on: Bool) {
        guard let token else { syncsAcrossDevices = false; return }
        syncsAcrossDevices = Self.tokenItem.save(token, synced: on)
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
        case .custom: return "Other (OpenAI API)"  // longer names push the picker value onto its own line
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

    var pricingURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")
        case .openai: return URL(string: "https://openai.com/api/pricing/")
        case .xai: return URL(string: "https://docs.x.ai/developers/models")
        case .custom: return nil
        }
    }

    /// Preselected after the key is verified; any model the key can use may be chosen
    var suggestedModel: String? {
        self == .anthropic ? "claude-opus-5-5" : nil
    }
}

/// Rough relative price of a model, guessed from its name. Providers' model lists carry
/// no prices, so this is only a hint; the provider's pricing page has the real rates.
enum AIModelCost: Int {
    case low = 1, moderate, high, highest

    var symbol: String { String(repeating: "$", count: rawValue) }

    var label: String {
        switch self {
        case .low: return "Lower cost"
        case .moderate: return "Moderate cost"
        case .high: return "Higher cost"
        case .highest: return "Highest cost"
        }
    }

    static func estimate(for model: String) -> AIModelCost? {
        let id = model.lowercased()
        // Whole name parts only, so "gemini" doesn't read as "mini"
        let parts = Set(id.split(whereSeparator: { "-_.:/ ".contains($0) }).map(String.init))
        // Not chat models; no badge so they don't look like deliberate picks
        if !parts.isDisjoint(with: ["embedding", "tts", "whisper", "transcribe", "image", "dall", "moderation", "audio", "realtime", "search"]) { return nil }
        let openAIStyle = id.hasPrefix("gpt-") || id.hasPrefix("o1") || id.hasPrefix("o3")
        if id.contains("fable") || id.contains("mythos") { return .highest }
        if id.contains("opus") { return .high }
        if id.contains("sonnet") { return .moderate }
        if id.contains("haiku") { return .low }
        if !parts.isDisjoint(with: ["mini", "nano", "lite", "flash", "fast", "small"]) { return .low }
        // OpenAI's "-pro" models are top tier; other vendors' "pro" models vary too much to guess
        if parts.contains("pro") { return openAIStyle ? .highest : nil }
        if id.hasPrefix("o1") || id.hasPrefix("o3") { return .high }
        if id.hasPrefix("gpt-") || id.hasPrefix("grok-") { return .moderate }
        return nil
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
    /// Tokens the provider reported billing for; nil for older entries or if not reported
    var inputTokens: Int?
    var outputTokens: Int?
}

/// Token counts from a provider response — what the user's account is billed on
struct AIUsage {
    var input: Int?
    var output: Int?
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
                if status == 401 || status == 403 { return "The provider rejected the API key (\(status)). Check the key and that your account has API access." }
                if status == 429 { return "Rate limited or out of credit with the provider (429): \(message)" }
                return "The AI provider returned \(status): \(message)"
            case .refused(let category): return "The model declined this request\(category.map { " (\($0))" } ?? "")."
            case .emptyResponse: return "The AI returned an empty answer."
            }
        }
    }

    @Published private(set) var provider: AIProvider?
    @Published private(set) var hasKey = false
    @Published var model: String {
        didSet {
            defaults.set(model, forKey: "aiModel")
            if hasKey { saveConfig() }
        }
    }
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "aiEnabled") } }
    @Published private(set) var consentDate: Date?
    @Published private(set) var activity: [AIActivityEntry] = []

    /// Whether the key (and provider/model) sync to the user's other devices (opt-in)
    @Published private(set) var syncsAcrossDevices = false

    private let defaults = UserDefaults.standard
    private var customBaseURL: String
    private static let keychainService = "com.psiegel18.TravelMapping.ai"
    private static let keyItem = KeychainItem(service: keychainService, account: "api-key")
    /// Provider / address / model, synced alongside the key so another device can use it
    private static let configItem = KeychainItem(service: keychainService, account: "api-config")

    private struct SyncedConfig: Codable {
        let provider: String
        let baseURL: String
        let model: String
    }

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
        if let stored = Self.keyItem.read() {
            hasKey = true
            syncsAcrossDevices = stored.synced
            // Key arrived from another device through iCloud Keychain: adopt its settings.
            // Permission to share data is still asked on this device.
            if provider == nil, let json = Self.configItem.read()?.value,
               let config = try? JSONDecoder().decode(SyncedConfig.self, from: Data(json.utf8)),
               let syncedProvider = AIProvider(rawValue: config.provider) {
                provider = syncedProvider
                customBaseURL = config.baseURL
                model = config.model
                defaults.set(config.provider, forKey: "aiProvider")
                defaults.set(config.baseURL, forKey: "aiBaseURL")
            }
        }
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

    /// True for requests to an AI provider — Sentry drops their failed-request events, since
    /// they concern the user's own account and must never carry prompts or keys to us.
    nonisolated static func isAIProviderURL(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host else { return false }
        var hosts: Set<String> = ["api.anthropic.com", "api.openai.com", "api.x.ai"]
        if let custom = UserDefaults.standard.string(forKey: "aiBaseURL").flatMap({ URL(string: $0)?.host }) {
            hosts.insert(custom)
        }
        return hosts.contains(host)
    }

    // MARK: Setup

    /// Verifies the key by listing models, then stores it. Returns the model IDs the key can use.
    func connect(provider: AIProvider, key: String, customBaseURL: String) async throws -> [String] {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = provider == .custom
            ? customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : (provider.defaultBaseURL ?? "")
        guard let url = URL(string: base), url.scheme == "https", url.host != nil else { throw AIError.badBaseURL }
        // A built-in provider's address typed under Other gets that provider's own API and auth
        if provider == .custom, let known = AIProvider.allCases.first(where: {
            $0.defaultBaseURL.flatMap { URL(string: $0)?.host } == url.host
        }) {
            return try await connect(provider: known, key: key, customBaseURL: "")
        }

        let models = try await Self.listModels(provider: provider, baseURL: base, key: trimmedKey)

        let scopeChanged = provider != self.provider || base != baseURL
        self.provider = provider
        self.customBaseURL = base
        defaults.set(provider.rawValue, forKey: "aiProvider")
        defaults.set(base, forKey: "aiBaseURL")
        syncsAcrossDevices = Self.keyItem.save(trimmedKey, synced: syncsAcrossDevices)
        hasKey = true
        if scopeChanged { revokeConsent() }
        if model.isEmpty || !models.contains(model) || scopeChanged {
            // Only Claude gets a default; other providers list many non-chat models
            // (embeddings, audio, legacy completions), so the user picks one
            model = provider.suggestedModel.flatMap { models.contains($0) ? $0 : nil } ?? ""
        }
        saveConfig()
        return models
    }

    func availableModels() async throws -> [String] {
        guard let provider, let baseURL, let key = Self.keyItem.read()?.value else { throw AIError.notReady }
        return try await Self.listModels(provider: provider, baseURL: baseURL, key: key)
    }

    /// Moves the key and its settings into (or out of) iCloud Keychain. Turning sync off
    /// removes the synced copy, so other devices lose the key.
    func setSyncsAcrossDevices(_ on: Bool) {
        guard let key = Self.keyItem.read()?.value else { syncsAcrossDevices = false; return }
        syncsAcrossDevices = Self.keyItem.save(key, synced: on)
        saveConfig()
    }

    private func saveConfig() {
        guard let provider,
              let data = try? JSONEncoder().encode(SyncedConfig(provider: provider.rawValue, baseURL: baseURL ?? "", model: model)),
              let json = String(data: data, encoding: .utf8) else { return }
        Self.configItem.save(json, synced: syncsAcrossDevices)
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
        Self.keyItem.delete()
        Self.configItem.delete()
        hasKey = false
        syncsAcrossDevices = false
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
        guard isReady, let provider, let baseURL, let key = Self.keyItem.read()?.value else { throw AIError.notReady }
        var entry = AIActivityEntry(id: UUID(), date: Date(), feature: feature, provider: provider.displayName,
                                    host: host, model: model, sentSummary: sentSummary,
                                    charactersSent: system.count + prompt.count, outcome: "Sending…")
        record(entry)
        do {
            let (text, usage) = provider == .anthropic
                ? try await Self.anthropicMessage(baseURL: baseURL, key: key, model: model, system: system, prompt: prompt)
                : try await Self.chatCompletion(baseURL: baseURL, key: key, model: model, system: system, prompt: prompt)
            entry.outcome = "Answered"
            entry.inputTokens = usage.input
            entry.outputTokens = usage.output
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
        // Anthropic pages /v1/models at 20 by default
        let path = provider == .anthropic ? "/models?limit=1000" : "/models"
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        authorize(&request, provider: provider, key: key)
        let data = try await send(request)
        struct List: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        let ids = (try? JSONDecoder().decode(List.self, from: data))?.data.map(\.id) ?? []
        return ids.sorted()
    }

    /// Claude Messages API. Opus 5.x / Fable 5.1 / Sonnet 5.5 get server-side refusal
    /// fallbacks so a safety decline is retried on Anthropic's recommended model.
    private static func anthropicMessage(baseURL: String, key: String, model: String, system: String, prompt: String) async throws -> (String, AIUsage) {
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
            struct Usage: Decodable { let input_tokens: Int?; let output_tokens: Int? }
            let content: [Block]
            let stop_reason: String?
            let stop_details: StopDetails?
            let usage: Usage?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.stop_reason == "refusal" { throw AIError.refused(response.stop_details?.category) }
        let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw AIError.emptyResponse }
        return (text, AIUsage(input: response.usage?.input_tokens, output: response.usage?.output_tokens))
    }

    /// OpenAI-style Chat Completions — OpenAI, xAI, and compatible services.
    private static func chatCompletion(baseURL: String, key: String, model: String, system: String, prompt: String) async throws -> (String, AIUsage) {
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
            struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
            let choices: [Choice]
            let usage: Usage?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let message = response.choices.first?.message
        if let refusal = message?.refusal, !refusal.isEmpty { throw AIError.refused(nil) }
        guard let text = message?.content, !text.isEmpty else { throw AIError.emptyResponse }
        return (text, AIUsage(input: response.usage?.prompt_tokens, output: response.usage?.completion_tokens))
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
            // Providers echo part of a rejected key ("Incorrect API key provided: sk-proj-ab…yz");
            // keep it out of on-screen text (and so out of session replays)
            message = message.replacingOccurrences(
                of: #"(sk|xai|key)[-_][A-Za-z0-9_\-\.\*…]{4,}"#, with: "[key]", options: .regularExpression)
            // Deliberately not sent to Sentry: these are the user's own account/config
            throw AIError.http(status: status, message: String(message.prefix(200)))
        }
        return data
    }

}
