import SwiftUI
import StoreKit
import WidgetKit
import Sentry

struct SettingsView: View {
    @ObservedObject private var settings = SyncedSettingsService.shared
    @ObservedObject private var favorites = FavoritesService.shared
    @AppStorage("watchUsername") private var watchUsername = ""
    @AppStorage("sendToWatch") private var sendToWatch = true
    @State private var showTipJar = false
    @State private var feedbackKind: FeedbackSheet.Kind?
    @ObservedObject private var github = GitHubService.shared
    @ObservedObject private var ai = AIService.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var isValidatingUser = false
    @State private var userValidationResult: Bool? = Self.cachedValidationResult
    @State private var lastValidatedUsername = Self.cachedValidatedUsername

    // Persist validation across view recreations
    private static var cachedValidatedUsername: String {
        get { UserDefaults.standard.string(forKey: "validatedUsername") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "validatedUsername") }
    }
    private static var cachedValidationResult: Bool? {
        get {
            guard UserDefaults.standard.object(forKey: "validationResult") != nil else { return nil }
            return UserDefaults.standard.bool(forKey: "validationResult")
        }
        set {
            if let val = newValue {
                UserDefaults.standard.set(val, forKey: "validationResult")
            } else {
                UserDefaults.standard.removeObject(forKey: "validationResult")
            }
        }
    }

    var body: some View {
        Form {
            // MARK: You
            Section {
                identityCard
            } header: {
                TMDesign.sectionHeader("You")
            } footer: {
                if let valid = userValidationResult, !valid {
                    Text("Username not found on Travel Mapping. Check your spelling or create an account from the Get Started guide in Support below.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Set your username for one-tap access, widget stats, and Watch app.")
                }
            }

            Section {
                Picker("Distance", selection: $settings.useMiles) {
                    Text("Miles").tag(true)
                    Text("Kilometers").tag(false)
                }
                .onChange(of: settings.useMiles) {
                    UserDefaults(suiteName: "group.com.psiegel18.TravelMapping")?
                        .set(settings.useMiles, forKey: "widgetUseMiles")
                    WidgetCenter.shared.reloadAllTimelines()
                }
                Toggle("iCloud Sync", isOn: $favorites.iCloudSyncEnabled)
                Toggle("Show on Apple Watch", isOn: $sendToWatch)
            } header: {
                TMDesign.sectionHeader("General")
            } footer: {
                Text("iCloud syncs favorites across devices. Apple Watch receives live trip status and route directions.")
            }

            // MARK: Features — details live on their own pages to keep this screen short
            Section {
                NavigationLink {
                    MapAppearanceSettingsView()
                } label: {
                    Label("Map Appearance", systemImage: "paintbrush")
                }
                NavigationLink {
                    GitHubSettingsView()
                } label: {
                    LabeledContent {
                        Text(github.isSignedIn ? (github.login.map { "@\($0)" } ?? "Signed in") : "Not signed in")
                    } label: {
                        Label("GitHub", systemImage: "arrow.triangle.pull")
                    }
                }
                .sentryReplayMask()
                NavigationLink {
                    AISettingsView()
                } label: {
                    LabeledContent {
                        Text(ai.isReady ? ai.providerLabel : (ai.hasKey && !ai.isEnabled ? "Off" : "Not set up"))
                    } label: {
                        Label("AI Assistant", systemImage: "sparkles")
                    }
                }
            } header: {
                TMDesign.sectionHeader("Features")
            } footer: {
                Text("GitHub and AI are optional. GitHub sends .list updates as pull requests. AI uses your own key to suggest .list fixes, and nothing is sent until you allow it.")
            }

            // MARK: Support
            Section {
                NavigationLink {
                    GetStartedView()
                } label: {
                    Label("Get Started Guide", systemImage: "questionmark.circle")
                }
                Link(destination: URL(string: "https://apps.apple.com/app/id6761671062?action=write-review")!) {
                    Label("Rate the App", systemImage: "star.fill")
                }
                Button {
                    Haptics.light()
                    feedbackKind = .feedback
                } label: {
                    Label("Share Feedback", systemImage: "bubble.left.and.bubble.right")
                }
                Button {
                    Haptics.light()
                    feedbackKind = .bug
                } label: {
                    Label("Report a Bug", systemImage: "ladybug")
                }

                // Tip jar lives behind a low-key row (not an in-your-face inline grid);
                // the sheet is attached to the row itself, never chained with the
                // Form's alert (chained presentations silently fail).
                Button {
                    showTipJar = true
                } label: {
                    Label("Tip the App Developer", systemImage: "heart")
                }
                .sheet(isPresented: $showTipJar) {
                    // Medium detent is right for iPhone, but on iPad it renders as a
                    // half-height card that clips the third tip — use a full form
                    // sheet there instead.
                    if sizeClass == .compact {
                        TipJarSheet()
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                    } else {
                        TipJarSheet()
                    }
                }
            } header: {
                TMDesign.sectionHeader("Support")
            } footer: {
                Text("Tips go to the independent developer of this iPhone app — not to the Travel Mapping project, which runs the website and route data.")
            }

            Section {
                NavigationLink {
                    AboutSettingsView()
                } label: {
                    LabeledContent {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    } label: {
                        Label("About, Privacy & Data", systemImage: "info.circle")
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(item: $feedbackKind) { kind in
            FeedbackSheet(kind: kind)
        }
        .task {
            await github.ensureLogin()
        }
    }

    // MARK: - Identity card (audit §14)
    // Primary User pulled into a top identity card: monogram avatar + username field
    // with the live validation check. Behavior (widget/watch/Sentry sync + debounced
    // validation) is unchanged from the old mid-form text field.
    private var identityCard: some View {
        HStack(spacing: 12) {
            TMMonogramAvatar(
                name: settings.primaryUser.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "TM"
                    : settings.primaryUser,
                size: 44
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Primary User")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TMDesign.tertiaryText)
                TextField("username", text: $settings.primaryUser)
                    .font(.system(size: 17, weight: .semibold))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Primary User username")
                    .onChange(of: settings.primaryUser) {
                        userValidationResult = nil
                        watchUsername = settings.primaryUser
                        UserDefaults(suiteName: "group.com.psiegel18.TravelMapping")?
                            .set(settings.primaryUser, forKey: "widgetUsername")
                        WidgetCenter.shared.reloadAllTimelines()
                        SentrySDK.configureScope { scope in
                            let isSet = !settings.primaryUser.isEmpty
                            scope.setTag(value: isSet ? "true" : "false", key: "primary_user_set")
                            if isSet {
                                scope.setUser(User(userId: settings.primaryUser))
                                scope.setTag(value: settings.primaryUser, key: "tm.username")
                            } else {
                                scope.setUser(nil)
                                scope.removeTag(key: "tm.username")
                            }
                        }
                    }
            }
            Spacer()
            if isValidatingUser {
                ProgressView()
                    .controlSize(.small)
            } else if let valid = userValidationResult {
                Image(systemName: valid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(valid ? .green : .orange)
                    .accessibilityLabel(valid ? "Username validated" : "Username not found")
            }
        }
        .padding(.vertical, 6)
        .task(id: settings.primaryUser) {
            let username = settings.primaryUser.trimmingCharacters(in: .whitespaces)
            guard !username.isEmpty else {
                userValidationResult = nil
                lastValidatedUsername = ""
                Self.cachedValidatedUsername = ""
                Self.cachedValidationResult = nil
                return
            }
            guard username != lastValidatedUsername else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            isValidatingUser = true
            let result = await validateUsername(username)
            if let result {
                // Only cache definitive results, not network failures
                userValidationResult = result
                lastValidatedUsername = username
                Self.cachedValidatedUsername = username
                Self.cachedValidationResult = result
            }
            // If result is nil (request failed), leave previous state unchanged
            isValidatingUser = false
        }
    }

    /// Returns true if found, false if confirmed not found, nil if the request failed (don't cache failures).
    private func validateUsername(_ username: String) async -> Bool? {
        let url = URL(string: "https://travelmapping.net/lib/getTravelerRoutes.php?dbname=TravelMapping")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        let encoded = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username
        request.httpBody = "params={\"traveler\":\"\(encoded)\"}".data(using: .utf8)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = json["routes"] as? [Any] else {
            SentrySDK.logger.debug("Username validation request failed", attributes: ["username": username])
            return nil  // Request failed — don't treat as "not found"
        }
        let found = !routes.isEmpty
        SentrySDK.logger.debug("Username validation", attributes: [
            "username": username,
            "found": found,
            "routeCount": routes.count,
        ])
        return found
    }
}

// MARK: - Settings sub-pages

struct MapAppearanceSettingsView: View {
    @ObservedObject private var settings = SyncedSettingsService.shared

    var body: some View {
        Form {
            Section {
                Picker("Road Style", selection: $settings.roadLineStyle) {
                    ForEach(MapStyleService.LineStyle.allCases) { style in
                        HStack {
                            LineStylePreview(style: style).frame(width: 40)
                            Text(style.rawValue)
                        }
                        .tag(style.rawValue)
                    }
                }
                HStack {
                    Text("Road Width")
                    Slider(value: $settings.roadLineWidth, in: 1...6, step: 0.5)
                    Text("\(settings.roadLineWidth, specifier: "%.1f")")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32)
                }
                HStack {
                    Text("Rail Width")
                    Slider(value: $settings.railLineWidth, in: 1...6, step: 0.5)
                    Text("\(settings.railLineWidth, specifier: "%.1f")")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32)
                }
                HStack {
                    Text("Untraveled Routes")
                    Slider(value: $settings.untraveledVisibility, in: 0.25...1.0, step: 0.05)
                    Text("\(Int((settings.untraveledVisibility * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Untraveled route visibility, \(Int((settings.untraveledVisibility * 100).rounded())) percent")
            } header: {
                TMDesign.sectionHeader("Map Lines")
            } footer: {
                Text("Untraveled routes appear in amber on the map — raise the visibility if they're hard to see against the base map.")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Accent Color")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], spacing: 12) {
                        ForEach(ThemeService.availableColors, id: \.name) { item in
                            Button {
                                Haptics.selection()
                                settings.accentColorName = item.name
                            } label: {
                                Circle()
                                    .fill(item.color)
                                    .frame(width: 44, height: 44)
                                    .overlay {
                                        Circle()
                                            .stroke(
                                                settings.accentColorName == item.name ? Color.primary : Color.clear,
                                                lineWidth: 3
                                            )
                                    }
                                    .overlay {
                                        if settings.accentColorName == item.name {
                                            Image(systemName: "checkmark")
                                                .font(.callout.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.name)
                            .accessibilityAddTraits(settings.accentColorName == item.name ? [.isSelected] : [])
                        }
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Controls tint for tab icons, buttons, links, and interactive elements throughout the app.")
            }
        }
        .navigationTitle("Map Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .sentryScreen("MapAppearanceSettings")
    }
}

struct GitHubSettingsView: View {
    @ObservedObject private var github = GitHubService.shared
    @AppStorage("listAppendOnly") private var listAppendOnly = false
    @State private var showGitHubSignIn = false
    @State private var githubSyncUnavailable = false

    var body: some View {
        Form {
            Section {
                if github.isConfigured {
                    if github.isSignedIn {
                        LabeledContent("Signed in as", value: github.login.map { "@\($0)" } ?? "GitHub")
                            .sentryReplayMask()
                        Toggle("Stay Signed In on My Other Devices", isOn: Binding(
                            get: { github.syncsAcrossDevices },
                            set: { on in
                                github.setSyncsAcrossDevices(on)
                                githubSyncUnavailable = on && !github.syncsAcrossDevices
                            }
                        ))
                        Button(github.syncsAcrossDevices ? "Sign Out on All Devices" : "Sign Out of GitHub", role: .destructive) {
                            github.signOut()
                        }
                    } else {
                        Button {
                            showGitHubSignIn = true
                        } label: {
                            Label("Sign in with GitHub", systemImage: "person.badge.key")
                        }
                    }
                }
                Picker("New lines go", selection: $listAppendOnly) {
                    Text("Where they fit in my file").tag(false)
                    Text("In a block at the end").tag(true)
                }
            } footer: {
                if githubSyncUnavailable {
                    Text("iCloud Keychain isn't available, so you're signed in on this device only. Turn it on in Settings › [your name] › iCloud › Passwords and Keychain.")
                        .foregroundStyle(TMDesign.rail)
                } else {
                Text(github.isConfigured
                     ? (github.syncsAcrossDevices
                        ? "Lets the app open .list update pull requests for your recorded trips. Your GitHub token is in your iCloud Keychain (end-to-end encrypted) and syncs to your other devices."
                        : "Lets the app open .list update pull requests for your recorded trips. Your GitHub token stays in this device's Keychain.")
                     : "How recorded-trip segments are added to your .list file.")
                }
            }
        }
        .navigationTitle("GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .sentryScreen("GitHubSettings")
        .sheet(isPresented: $showGitHubSignIn) {
            GitHubSignInSheet()
        }
        .task {
            await github.ensureLogin()
        }
    }
}

struct AboutSettingsView: View {
    @State private var versionTapCount = 0
    @State private var showSentryTestAlert = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .onTapGesture {
                        versionTapCount += 1
                        if versionTapCount >= 7 {
                            versionTapCount = 0
                            showSentryTestAlert = true
                        }
                    }
                LabeledContent("Data Source", value: "travelmapping.net + tmrail.teresco.org")
                LabeledContent("User Data", value: "GitHub API")
                NavigationLink {
                    PrivacyPolicyView()
                } label: {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }

            Section {
                CacheStatusView()

                Button("Clear Cache") {
                    Haptics.light()
                    Task {
                        await CacheService.shared.clearAll()
                    }
                }
                .foregroundStyle(.red)
            } header: {
                TMDesign.sectionHeader("Data")
            } footer: {
                Text("Cached stats, user lists, and API responses (refreshes every 6\u{2013}24 hours). Pull down on any page to force-refresh.")
            }

            Section {
                Link(destination: URL(string: "https://travelmapping.net")!) {
                    Label("Travel Mapping (Roads)", systemImage: "car.fill")
                }
                Link(destination: URL(string: "https://tmrail.teresco.org")!) {
                    Label("Travel Mapping (Rail)", systemImage: "tram.fill")
                }
                Link(destination: URL(string: "https://github.com/TravelMapping/UserData")!) {
                    Label("User Data on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/psiegel18/TravelMapIOS/discussions")!) {
                    Label("App Discussion Board", systemImage: "bubble.left.and.text.bubble.right")
                }
                Link(destination: URL(string: "https://forum.travelmapping.net/")!) {
                    Label("TM Community Forum", systemImage: "person.3")
                }
            } header: {
                TMDesign.sectionHeader("Links")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .sentryScreen("AboutSettings")
        .alert("Send Test Event", isPresented: $showSentryTestAlert) {
            Button("Send", role: .destructive) {
                SentrySDK.capture(error: NSError(
                    domain: "com.psiegel18.TravelMapping.test",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Test event from Settings (version tapped 7 times)"]
                ))
                Haptics.success()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will send a test error event to Sentry to verify the integration is working. Continue?")
        }
    }
}

struct LineStylePreview: View {
    let style: MapStyleService.LineStyle

    var body: some View {
        Canvas { context, size in
            let y = size.height / 2
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))

            let lineWidth: CGFloat = 2 * style.widthMultiplier
            let strokeStyle = StrokeStyle(
                lineWidth: lineWidth,
                lineCap: .round,
                dash: style.dashPattern
            )
            context.stroke(path, with: .color(.primary), style: strokeStyle)
        }
        .frame(height: 20)
    }
}

struct CacheStatusView: View {
    @State private var cacheSize: String = "—"
    @State private var fileCount: Int = 0
    @State private var oldestCache: String = "—"
    @State private var lastMerge: String = "—"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Cache Size", value: cacheSize)
            LabeledContent("Cached Items") {
                Text(fileCount.formatted())
                    .monospacedDigit()
            }
            LabeledContent("Oldest Cache", value: oldestCache)
            LabeledContent("Site Last Updated", value: lastMerge)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TMCache-v2")

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else {
            cacheSize = "Empty"
            fileCount = 0
            return
        }

        // Only count data files (not .meta files)
        let dataFiles = files.filter { !$0.lastPathComponent.hasSuffix(".meta") }
        fileCount = dataFiles.count

        let totalBytes = files.compactMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }.reduce(0, +)

        if totalBytes == 0 {
            cacheSize = "Empty"
        } else if totalBytes > 1_000_000 {
            cacheSize = String(format: "%.1f MB", Double(totalBytes) / 1_000_000)
        } else {
            cacheSize = String(format: "%.0f KB", Double(totalBytes) / 1_000)
        }

        // Oldest still-valid cache entry. Skip expired entries — they're abandoned
        // keys that will get swept the next time CacheService.purgeExpired() runs and
        // would otherwise make the display read "15 days ago" right after a fresh fetch.
        let metaFiles = files.filter { $0.lastPathComponent.hasSuffix(".meta") }
        let now = Date()
        var oldestDate: Date?
        for file in metaFiles {
            if let data = try? Data(contentsOf: file),
               let meta = try? JSONDecoder().decode(CacheMetaRead.self, from: data),
               now <= meta.expiresAt {
                if oldestDate == nil || meta.createdAt < oldestDate! {
                    oldestDate = meta.createdAt
                }
            }
        }
        if let oldest = oldestDate {
            oldestCache = formatRelative(oldest)
        } else {
            oldestCache = "None"
        }

        // Fetch last merged PR date from TravelMapping/UserData repo
        await fetchLastMerge()
    }

    private func fetchLastMerge() async {
        let url = URL(string: "https://api.github.com/repos/TravelMapping/UserData/pulls?state=closed&sort=updated&direction=desc&per_page=1")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let prs = try? JSONDecoder().decode([GitHubPR].self, from: data),
              let pr = prs.first,
              let mergedAt = pr.merged_at else {
            lastMerge = "Unknown"
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: mergedAt) {
            lastMerge = formatRelative(date)
        } else {
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: mergedAt) {
                lastMerge = formatRelative(date)
            } else {
                lastMerge = "Unknown"
            }
        }
    }

    private func formatRelative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        let minutes = Int(seconds / 60)
        let hours = Int(seconds / 3600)
        let days = hours / 24

        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if hours < 24 { return "\(hours) hr\(hours == 1 ? "" : "s") ago" }
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }

    private struct CacheMetaRead: Decodable {
        let createdAt: Date
        let expiresAt: Date
    }

    private struct GitHubPR: Decodable {
        let merged_at: String?
    }
}

// MARK: - Tip Jar

struct TipJarView: View {
    private enum PurchaseState {
        case success, pending, failure

        var color: Color {
            switch self {
            case .success: return .green
            case .pending: return .orange
            case .failure: return .secondary
            }
        }
    }

    @State private var products: [Product] = []
    @State private var isLoading = true
    @State private var purchaseMessage: String?
    @State private var purchaseState: PurchaseState = .success


    private static let tipIDs = [
        "com.psiegel18.TravelMapping.tip.small",
        "com.psiegel18.TravelMapping.tip.medium",
        "com.psiegel18.TravelMapping.tip.large"
    ]

    private static let tipEmojis: [String: String] = [
        "com.psiegel18.TravelMapping.tip.small": "☕",
        "com.psiegel18.TravelMapping.tip.medium": "🍕",
        "com.psiegel18.TravelMapping.tip.large": "⛽"
    ]

    private static let tipLabels: [String: String] = [
        "com.psiegel18.TravelMapping.tip.small": "Road Coffee",
        "com.psiegel18.TravelMapping.tip.medium": "Rest-Stop Pizza",
        "com.psiegel18.TravelMapping.tip.large": "Fill the Tank"
    ]

    private static let tipSubtitles: [String: String] = [
        "com.psiegel18.TravelMapping.tip.small": "Keeps the dev awake at the wheel",
        "com.psiegel18.TravelMapping.tip.medium": "Fuel for late-night bug fixes",
        "com.psiegel18.TravelMapping.tip.large": "You're basically a co-pilot now"
    ]

    private static let tipTints: [String: (bg: Color, fg: Color)] = [
        "com.psiegel18.TravelMapping.tip.small": (TMDesign.amberChipBG, TMDesign.amberChipFG),
        "com.psiegel18.TravelMapping.tip.medium": (TMDesign.redChipBG, TMDesign.redChipFG),
        "com.psiegel18.TravelMapping.tip.large": (TMDesign.greenChipBG, TMDesign.greenChipFG)
    ]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if products.isEmpty {
                Text("Tips unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(products.sorted { $0.price < $1.price }.enumerated()), id: \.element.id) { index, product in
                        let tint = Self.tipTints[product.id] ?? (TMDesign.blueChipBG, TMDesign.blueChipFG)
                        Button {
                            Task { await purchase(product) }
                        } label: {
                            HStack(spacing: 14) {
                                Text(Self.tipEmojis[product.id] ?? "💰")
                                    .font(.system(size: 38))
                                    .rotationEffect(.degrees(reduceMotion ? 0 : (index.isMultiple(of: 2) ? -6 : 6)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.tipLabels[product.id] ?? "Tip")
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundStyle(.primary)
                                    Text(Self.tipSubtitles[product.id] ?? "Every bit helps!")
                                        .font(.system(size: 13))
                                        .foregroundStyle(TMDesign.secondaryText)
                                }
                                Spacer()
                                Text(product.displayPrice)
                                    .font(.system(size: 15, weight: .heavy))
                                    .monospacedDigit()
                                    .foregroundStyle(tint.fg)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(tint.bg, in: Capsule())
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .rotationEffect(.degrees(reduceMotion ? 0 : (index.isMultiple(of: 2) ? -0.7 : 0.7)))
                        }
                        .buttonStyle(TipSpringButtonStyle())
                        .accessibilityLabel("\(Self.tipLabels[product.id] ?? "Tip"), \(product.displayPrice)")
                    }
                }

                if let message = purchaseMessage {
                    Text(message)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(purchaseState.color)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
        }
        .task {
            do {
                products = try await Product.products(for: Self.tipIDs)
            } catch {
                SentrySDK.capture(error: error)
            }
            isLoading = false
        }
        // Pending purchases (e.g. Ask to Buy) are finished by the app-launch
        // Transaction.updates listener in TravelMappingApp; reflect the completion here
        // if the user is still looking at the "pending" message.
        .onReceive(NotificationCenter.default.publisher(for: .tipTransactionFinished)) { _ in
            if purchaseState == .pending {
                purchaseState = .success
                purchaseMessage = "Thank you for your support! 🎉"
                Haptics.success()
            }
        }
    }

    private func purchase(_ product: Product) async {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    Haptics.success()
                    purchaseState = .success
                    purchaseMessage = "Thank you for your support! 🎉"
                    SentrySDK.logger.info("Tip purchased", attributes: [
                        "productId": product.id,
                        "price": product.displayPrice,
                    ])
                case .unverified:
                    purchaseState = .failure
                    purchaseMessage = "Purchase could not be verified. You have not been charged."
                    SentrySDK.logger.warn("Tip purchase unverified", attributes: ["productId": product.id])
                }
            case .userCancelled:
                break
            case .pending:
                purchaseState = .pending
                purchaseMessage = "Purchase pending approval — it will complete automatically once approved."
                SentrySDK.logger.info("Tip purchase pending", attributes: ["productId": product.id])
            @unknown default:
                break
            }
        } catch {
            SentrySDK.capture(error: error)
        }
    }
}

// MARK: - Privacy Policy

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                    Text("Your Privacy Matters")
                        .font(.title2.bold())
                    Text("Travel Mapping is designed to keep your data on your device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical)

                // Quick summary cards
                HStack(spacing: 12) {
                    summaryCard(icon: "xmark.shield.fill", color: .red, title: "No Ads", subtitle: "Ever")
                    summaryCard(icon: "location.slash.fill", color: .green, title: "GPS Stays", subtitle: "On Device")
                    summaryCard(icon: "eye.slash.fill", color: .purple, title: "No Tracking", subtitle: "Period")
                }
                .padding(.horizontal)

                // Sections
                policyCard(icon: "location.fill", color: .blue, title: "Location Data") {
                    bullet("Accessed only when you start a Road Trip, tap the location button, or choose Current Location in the Route Planner")
                    bullet("Recorded trips are stored on your device and in iCloud if enabled, and never sent to third parties")
                    bullet("Route Planner: your current location goes to Apple Maps for directions and nearby address suggestions, and the route's area to travelmapping.net for highway data")
                    bullet("Navigating or sharing with Google Maps or Waze passes the start and end points to that app")
                    bullet("Trip recording stops when you end the recording session")
                }

                policyCard(icon: "gear", color: .gray, title: "User Preferences") {
                    bullet("Favorites, username, map settings stored on device")
                    bullet("Optionally syncs via iCloud Key-Value Storage")
                }

                policyCard(icon: "network", color: .orange, title: "Network Requests") {
                    Text("The app fetches public data from:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    serviceRow("travelmapping.net", desc: "Route data & statistics")
                    serviceRow("tmrail.teresco.org", desc: "Rail route data")
                    serviceRow("GitHub", desc: "User travel list files")
                    serviceRow("Apple Maps", desc: "Route Planner directions & address suggestions")
                    Text("No personal information is sent to the developer. The app has no accounts of its own. GitHub and AI providers are contacted only if you turn on the optional features below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                policyCard(icon: "arrow.triangle.pull", color: .purple, title: "Optional GitHub Sign-In") {
                    bullet("Off unless you sign in under Settings › GitHub")
                    bullet("You approve access on github.com. Your password never passes through the app")
                    bullet("Used only to fork TravelMapping/UserData, commit your updated .list file, and open a pull request")
                    bullet("Token stored in your Keychain and sent only to api.github.com. Syncs through iCloud Keychain only if you turn that on")
                    bullet("Pull requests are public on GitHub, like any UserData contribution")
                }

                policyCard(icon: "sparkles", color: .pink, title: "Optional AI Assistant (Your Own Key)") {
                    Text("Off unless you add your own API key and give permission. Requests go straight from your device to the provider you chose, under your account and its privacy policy. The developer never receives your key, your requests, or the answers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(AIDisclosure.sends, id: \.self) { bullet("Sent: \($0)") }
                    ForEach(AIDisclosure.neverSends, id: \.self) { noBullet("Never sent: \($0)") }
                    bullet("Key stored in your Keychain. Syncs through iCloud Keychain only if you turn that on")
                    bullet("A log of every request stays on your device (Settings › AI Assistant › Activity)")
                }

                policyCard(icon: "ant.fill", color: .teal, title: "Crash Reporting & Diagnostics") {
                    Text("We use Sentry to collect anonymous diagnostic data to improve stability and performance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    bullet("Device model, OS version, app version")
                    bullet("Stack trace (what code was running)")
                    bullet("Performance metrics (CPU profiles, slow frames, app hangs)")
                    bullet("Screenshot, view hierarchy, and short session replay at the moment of an error")
                    bullet("Breadcrumbs & logs of app events (trip start/stop, navigation)")
                    bullet("Your TravelMapping username if set")
                    bullet("General device state (memory, battery)")
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("Not used for ads, tracking, or analytics")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                    .padding(.top, 4)
                }

                policyCard(icon: "xmark.circle.fill", color: .red, title: "We Do Not Collect") {
                    noBullet("Personal info (email, phone, real name)")
                    noBullet("Your API keys, GitHub token, or AI requests")
                    noBullet("Advertising or tracking data")
                    noBullet("Your road trip data or location history")
                }

                policyCard(icon: "externaldrive.fill", color: .indigo, title: "Data Storage") {
                    storagePill(icon: "iphone", label: "Device", detail: "Preferences, favorites, cache, trips")
                    storagePill(icon: "icloud", label: "iCloud", detail: "Favorites, preferences & trips (optional)")
                    storagePill(icon: "key.fill", label: "Keychain", detail: "GitHub token & AI key, if added (iCloud Keychain sync optional)")
                    storagePill(icon: "server.rack", label: "Sentry", detail: "Anonymous crash, performance, and session replay data (no PII)")
                }

                policyCard(icon: "slider.horizontal.3", color: .mint, title: "Your Choices") {
                    bullet("iCloud sync: Toggle on/off in Settings")
                    bullet("Location: Only for trip recording \u{2014} deny and still use the app")
                    bullet("Cache: Clear anytime from Settings")
                    bullet("GitHub: Sign out anytime from Settings")
                    bullet("AI: Turn off, revoke permission, or remove your key anytime from Settings")
                }

                policyCard(icon: "figure.child", color: .yellow, title: "Children's Privacy") {
                    Text("We do not knowingly collect data from children under 13.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Footer
                VStack(spacing: 4) {
                    Text("Last updated: October 25, 2026")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Link("View web version", destination: URL(string: "https://travel.psiegel.org/PRIVACY")!)
                        .font(.caption2)
                }
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Components

    private func summaryCard(icon: String, color: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(title)
                .font(.caption.bold())
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func policyCard<Content: View>(icon: String, color: Color, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(color)
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline.bold())
            }
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(.leading, 32)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark")
                .font(.caption2.bold())
                .foregroundStyle(.green)
                .frame(width: 14)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func noBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark")
                .font(.caption2.bold())
                .foregroundStyle(.red)
                .frame(width: 14)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func serviceRow(_ name: String, desc: String) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.caption.bold())
            Text("\u{2014} \(desc)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    private func storagePill(icon: String, label: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.blue)
                .frame(width: 20)
            Text(label)
                .font(.caption.bold())
                .fixedSize(horizontal: true, vertical: false)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Tip Jar Sheet

/// Whimsical modal home for the tip jar — reached from a low-key Settings row so
/// tipping is opt-in rather than staring at everyone from the middle of Settings.
struct TipJarSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("🫙")
                    .font(.system(size: 64))
                    .padding(.top, 26)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("The Tip Jar")
                        .font(.system(size: 28, weight: .heavy))
                    Text("Tips support this iPhone app, which is built and maintained by one independent developer.")
                        .font(.system(size: 15))
                        .foregroundStyle(TMDesign.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Credit where it's due: the app is a client for someone else's project
                VStack(alignment: .leading, spacing: 8) {
                    Label("Who does what", systemImage: "info.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TMDesign.accent)
                    Text("The Travel Mapping website, route data, and every traveler's stats are the work of the Travel Mapping project and its volunteers. The app's developer didn't build any of that and isn't part of that team — this app just shows their data on your iPhone.")
                        .font(.system(size: 14))
                        .foregroundStyle(TMDesign.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Tips go only to the app's developer, for work on the iPhone, iPad, Apple Watch, and widget apps — not to the Travel Mapping project.")
                        .font(.system(size: 14))
                        .foregroundStyle(TMDesign.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: URL(string: "https://travelmapping.net")!) {
                        Label("Visit the Travel Mapping project", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 20)
                .accessibilityElement(children: .combine)

                TipJarView()
                    .padding(.horizontal, 20)

                Text("No subscriptions, no unlocks — just gratitude. 💙")
                    .font(.system(size: 13))
                    .foregroundStyle(TMDesign.tertiaryText)
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(TMDesign.secondarySurface)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(TMDesign.tertiaryText)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.trailing, 10)
            .accessibilityLabel("Close tip jar")
        }
    }
}

/// Springy press effect for the tip cards — playful without being noisy.
/// Under Reduce Motion the scale change is skipped.
struct TipSpringButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

// MARK: - GitHub sign-in (device flow)

/// Shows the one-time code from GitHub's device flow and waits for the user to
/// approve it on github.com. No password ever passes through the app.
struct GitHubSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var github = GitHubService.shared
    @State private var code: GitHubService.DeviceCode?
    @State private var errorMessage: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(TMDesign.accent)
                    .padding(.top, 24)

                if let code {
                    Text("Enter this code on GitHub")
                        .font(.system(size: 20, weight: .heavy))
                    Text(code.user_code)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(TMDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button {
                        UIPasteboard.general.string = code.user_code
                        if let url = URL(string: code.verification_uri) { openURL(url) }
                    } label: {
                        Label("Copy Code & Open GitHub", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(TMDesign.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for you to approve…")
                            .foregroundStyle(TMDesign.secondaryText)
                    }
                    Text("The app asks for access to public repositories only, so it can fork TravelMapping/UserData and open pull requests for you.")
                        .font(.system(size: 13))
                        .foregroundStyle(TMDesign.tertiaryText)
                        .multilineTextAlignment(.center)
                } else if let errorMessage {
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(TMDesign.secondaryText)
                    Button("Try Again") {
                        self.errorMessage = nil
                        attempt += 1
                    }
                    .font(.system(size: 17, weight: .semibold))
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .navigationTitle("Sign in with GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: attempt) {
                do {
                    code = nil
                    let deviceCode = try await github.startDeviceFlow()
                    code = deviceCode
                    try await github.completeDeviceFlow(deviceCode)
                    Haptics.success()
                    dismiss()
                } catch is CancellationError {
                    // Sheet dismissed mid-poll
                } catch {
                    code = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
        .sentryScreen("GitHubSignIn")
    }
}

// MARK: - Feedback form

/// Native feedback / bug-report form. Replaces Sentry's built-in form for the Settings
/// buttons: that form doesn't scroll, and on current iPhones the keyboard covers its
/// Send button (TRAVELMAPPING-W: 8 opens, 0 reports received). Send lives in the
/// toolbar here so it's always reachable.
struct FeedbackSheet: View {
    enum Kind: String, Identifiable {
        case feedback, bug
        var id: String { rawValue }
    }

    let kind: Kind

    @Environment(\.dismiss) private var dismiss
    // Remembered on this device so repeat reporters don't retype them
    @AppStorage("feedbackName") private var name = ""
    @AppStorage("feedbackEmail") private var email = ""
    @State private var message = ""
    @FocusState private var messageFocused: Bool

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $message)
                        .frame(minHeight: 160)
                        .focused($messageFocused)
                        .overlay(alignment: .topLeading) {
                            if message.isEmpty {
                                Text(kind == .bug
                                     ? "What happened? Steps to reproduce help a lot."
                                     : "Share thoughts, feature ideas, or general feedback.")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } footer: {
                    if kind == .bug {
                        Text("App diagnostics (version, device, recent screens) are attached to help find the problem — never your trips or location.")
                    }
                }

                Section {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Contact (optional)")
                } footer: {
                    Text("Only used to follow up on this \(kind == .bug ? "report" : "feedback").")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(kind == .bug ? "Report a Bug" : "Send Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(kind == .bug ? "Send Report" : "Send") { send() }
                        .disabled(trimmedMessage.isEmpty)
                }
            }
            .onAppear { messageFocused = true }
        }
        .sentryScreen(kind == .bug ? "ReportBug" : "SendFeedback")
    }

    private func send() {
        // The issue is created on send (not on open) so it always carries the report
        var eventId: SentryId?
        if kind == .bug {
            eventId = SentrySDK.capture(message: "User-reported bug") { scope in
                scope.setLevel(.warning)
                scope.setTag(value: "bug_report", key: "feedback_type")
            }
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        SentrySDK.capture(feedback: SentryFeedback(
            message: trimmedMessage,
            name: trimmedName.isEmpty ? nil : trimmedName,
            email: trimmedEmail.isEmpty ? nil : trimmedEmail,
            source: .custom,
            associatedEventId: eventId
        ))
        SentrySDK.logger.info("User feedback submitted", attributes: [
            "hasName": !trimmedName.isEmpty,
            "hasEmail": !trimmedEmail.isEmpty,
            "feedback_type": kind == .bug ? "bug_report" : "feedback",
        ])
        Haptics.success()
        dismiss()
    }
}

// MARK: - AI Assistant

/// What AI features may send and do — shown in the consent sheet and in Settings so the
/// two never drift apart (App Store Review Guideline 5.1.2(i)).
enum AIDisclosure {
    static let sends = [
        "Lines from your .list file that TravelMapping flagged as not counting, with its notes about them",
        "Public TravelMapping route data for those routes (waypoint names and coordinates)",
    ]
    static let neverSends = [
        "Your recorded GPS trips or current location",
        "The rest of your .list file",
        "Your email, GitHub account, or any other keys",
    ]
    static let control = [
        "The AI only suggests. Your .list file doesn't change until you review a fix and send it yourself.",
        "Every request is listed under Settings › AI Assistant › Activity.",
        "Turn AI off, revoke permission, or remove your key here at any time.",
    ]
}

struct AISettingsView: View {
    @ObservedObject private var ai = AIService.shared
    @State private var provider: AIProvider = AIService.shared.provider ?? .anthropic
    @State private var keyText = ""
    @State private var customBaseURL = UserDefaults.standard.string(forKey: "aiBaseURL") ?? ""
    @State private var models: [String] = []
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showConsent = false
    @State private var confirmRemove = false

    private var editingNewProvider: Bool { provider != ai.provider || !ai.hasKey }

    var body: some View {
        Form {
            if ai.hasKey {
                Section {
                    Toggle("AI features", isOn: $ai.isEnabled)
                } footer: {
                    Text(ai.isEnabled
                         ? "Turning this off stops all AI requests right away. Your key stays saved on this device."
                         : "AI is off. No data is sent to any AI provider.")
                }
            }

            Section {
                Picker("Provider", selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                }
                if provider == .custom {
                    TextField("API address (https://…/v1)", text: $customBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if editingNewProvider {
                    SecureField("API key", text: $keyText)
                        .textContentType(.password)  // offers Passwords AutoFill on the keyboard
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .sentryReplayMask()
                    if let url = provider.keysPageURL {
                        Link("Get an API key from \(provider.companyName)", destination: url)
                            .font(.subheadline)
                    }
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Text(isConnecting ? "Checking key…" : "Verify & Save Key")
                            if isConnecting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isConnecting || keyText.trimmingCharacters(in: .whitespaces).isEmpty
                              || (provider == .custom && customBaseURL.isEmpty))
                } else {
                    LabeledContent("API key", value: ai.syncsAcrossDevices ? "Saved in iCloud Keychain" : "Saved on this device")
                    Toggle("Use on My Other Devices", isOn: Binding(
                        get: { ai.syncsAcrossDevices },
                        set: { on in
                            ai.setSyncsAcrossDevices(on)
                            if on && !ai.syncsAcrossDevices {
                                errorMessage = "iCloud Keychain isn't available. Turn it on in Settings › [your name] › iCloud › Passwords and Keychain."
                            }
                        }
                    ))
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(TMDesign.rail)
                        .sentryReplayMask()
                }
            } header: {
                Text("Provider")
            } footer: {
                Text(providerFooter)
            }

            if editingNewProvider {
                Section {
                    Label {
                        Text("Save your key in the **Passwords** app (as a password for \(provider == .custom ? "the service" : URL(string: provider.keysPageURL?.absoluteString ?? "")?.host ?? provider.companyName)). Then tap the key field and choose **Passwords** above the keyboard to fill it in on any device.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "key.fill")
                            .foregroundStyle(TMDesign.goldChipFG)
                    }
                } header: {
                    Text("Tip")
                }
            }


            if ai.hasKey && !editingNewProvider {
                Section {
                    if models.isEmpty {
                        LabeledContent("Model", value: ai.model.isEmpty ? "Not chosen" : ai.model)
                    } else {
                        Picker("Model", selection: $ai.model) {
                            Text("Choose…").tag("")
                            ForEach(models, id: \.self) { id in
                                if let cost = AIModelCost.estimate(for: id) {
                                    // Tier first: menu rows wrap long IDs, which pushed a trailing tier around
                                    Text("\(cost.symbol)\u{2002}\(id)").tag(id)
                                } else {
                                    Text(id).tag(id)
                                }
                            }
                        }
                    }
                    if let cost = AIModelCost.estimate(for: ai.model) {
                        LabeledContent("Relative cost") {
                            Text("\(cost.symbol) · \(cost.label)")
                        }
                    }
                    if let url = ai.provider?.pricingURL {
                        Link(destination: url) {
                            Label("\(ai.provider?.companyName ?? "Provider") Pricing", systemImage: "dollarsign.circle")
                        }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if ai.model.isEmpty {
                            Text("Choose a chat model. AI features stay off until you do.")
                        }
                        Text("$ to $$$$ is a rough guide from the model's name — providers don't publish prices in their model lists. AI Activity shows the exact tokens each request used.")
                    }
                }
            }

            if ai.hasKey {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("List checkup")
                            Text("Road Trips › List checkup › Suggest fixes. When TravelMapping skips lines of your .list file, the AI proposes waypoints for them.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checklist")
                    }
                } header: {
                    Text("Where AI is used")
                } footer: {
                    Text("The AI only runs when you tap Suggest fixes. There's no background use and no chat.")
                }
            }

            Section {
                disclosureList("Can read", items: AIDisclosure.sends, icon: "eye", tint: TMDesign.accent)
                disclosureList("Never sent", items: AIDisclosure.neverSends, icon: "eye.slash", tint: TMDesign.clinched)
                disclosureList("You stay in control", items: AIDisclosure.control, icon: "hand.raised", tint: TMDesign.frontier)
            } header: {
                Text("What the AI can see and do")
            }

            if ai.hasKey {
                Section {
                    if let date = ai.consentDate {
                        LabeledContent("Allowed", value: date.formatted(date: .abbreviated, time: .omitted))
                        Button("Revoke Permission", role: .destructive) { ai.revokeConsent() }
                    } else {
                        Button("Review & Allow Data Sharing…") { showConsent = true }
                    }
                } header: {
                    Text("Permission")
                } footer: {
                    Text("Sharing with \(ai.providerLabel) needs your permission. Revoking it stops AI features until you allow it again.")
                }

                Section {
                    NavigationLink {
                        AIActivityView()
                    } label: {
                        LabeledContent("Activity", value: "\(ai.activity.count) request\(ai.activity.count == 1 ? "" : "s")")
                    }
                    Button("Remove API Key", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .navigationTitle("AI Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .sentryScreen("AISettings")
        .sheet(isPresented: $showConsent) {
            AIConsentSheet()
        }
        .confirmationDialog("Remove your API key?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) {
                ai.removeKey()
                keyText = ""
                models = []
            }
        } message: {
            Text(ai.syncsAcrossDevices
                 ? "AI features turn off and the key is deleted from this device and from your other devices through iCloud Keychain. Your activity history stays until you clear it."
                 : "AI features turn off and the key is deleted from this device. Your activity history stays until you clear it.")
        }
        .task {
            guard ai.hasKey, !editingNewProvider else { return }
            models = (try? await ai.availableModels()) ?? []
        }
    }

    private var providerFooter: String {
        let host = provider == .custom
            ? (URL(string: customBaseURL)?.host ?? "the address above")
            : (URL(string: provider.defaultBaseURL ?? "")?.host ?? provider.companyName)
        let storage = ai.hasKey && !editingNewProvider && ai.syncsAcrossDevices
            ? "Your key is in your iCloud Keychain (end-to-end encrypted) and syncs to devices signed in to your Apple Account. Turning this off removes it from your other devices."
            : "Your key is stored only in this device's Keychain."
        let account = provider == .custom ? "account with that service" : "\(provider.companyName) account"
        return "\(storage) It's sent only to \(host), and usage is billed to your own \(account) — the app's developer never sees your key or your requests."
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            models = try await ai.connect(provider: provider, key: keyText, customBaseURL: customBaseURL)
            // connect() may switch Other to the built-in provider whose address was entered
            if let connected = ai.provider, connected != provider { provider = connected }
            keyText = ""
            Haptics.success()
            if ai.consentDate == nil { showConsent = true }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func disclosureList(_ title: String, items: [String], icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(items, id: \.self) { item in
                Text("• \(item)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Explicit permission before anything goes to a third-party AI (Guideline 5.1.2(i)).
struct AIConsentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ai = AIService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 36))
                        .foregroundStyle(TMDesign.accent)
                    Text("Share data with \(ai.providerLabel)?")
                        .font(.system(size: 24, weight: .heavy))
                    Text("When you ask for a suggested fix, the app sends the data below to \(ai.host) using your API key. \(ai.provider?.companyName.capitalized ?? "The provider") processes it under its own terms and privacy policy.")
                        .foregroundStyle(TMDesign.secondaryText)

                    block("What's sent", items: AIDisclosure.sends, icon: "arrow.up.right.circle.fill", tint: TMDesign.accent)
                    block("Never sent", items: AIDisclosure.neverSends, icon: "lock.circle.fill", tint: TMDesign.clinched)
                    block("You stay in control", items: AIDisclosure.control, icon: "hand.raised.circle.fill", tint: TMDesign.frontier)

                    if let url = ai.provider?.privacyPolicyURL {
                        Link("\(ai.provider?.companyName ?? "Provider") privacy policy", destination: url)
                            .font(.subheadline)
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        ai.grantConsent()
                        Haptics.success()
                        dismiss()
                    } label: {
                        Text("Allow")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(TMDesign.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Button("Don't Allow") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
        .sentryScreen("AIConsent")
    }

    private func block(_ title: String, items: [String], icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                    Text(item)
                }
                .font(.subheadline)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Every AI request made from this device: when, what feature, which provider/model,
/// and a plain description of what was sent.
struct AIActivityView: View {
    @ObservedObject private var ai = AIService.shared

    var body: some View {
        List {
            if ai.activity.isEmpty {
                Text("No AI requests yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(ai.activity) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.feature).font(.headline)
                        Spacer()
                        Text(entry.outcome)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(entry.outcome == "Answered" ? TMDesign.clinched : .secondary)
                    }
                    Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.provider) · \(entry.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Sent: \(entry.sentSummary) (\(entry.charactersSent.formatted()) characters) to \(entry.host)")
                        .font(.footnote)
                    if let tokens = tokenSummary(entry) {
                        Text("Used: \(tokens)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("AI Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !ai.activity.isEmpty {
                Button("Clear") { ai.clearActivity() }
            }
        }
        .sentryScreen("AIActivity")
    }

    /// Whichever token counts the provider reported; some compatible servers send only input
    private func tokenSummary(_ entry: AIActivityEntry) -> String? {
        let parts = [
            entry.inputTokens.map { "\($0.formatted()) input" },
            entry.outputTokens.map { "\($0.formatted()) output" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " + ") + " tokens"
    }
}
