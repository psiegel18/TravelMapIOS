import SwiftUI
import StoreKit
import WidgetKit
import Sentry

struct SettingsView: View {
    @Environment(\.requestReview) private var requestReviewAction
    @ObservedObject private var settings = SyncedSettingsService.shared
    @ObservedObject private var favorites = FavoritesService.shared
    @AppStorage("watchUsername") private var watchUsername = ""
    @AppStorage("sendToWatch") private var sendToWatch = true
    @State private var versionTapCount = 0
    @State private var showSentryTestAlert = false
    @State private var showBugReport = false
    @State private var bugReportMessage = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Primary User")
                    Spacer()
                    TextField("username", text: $settings.primaryUser)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: settings.primaryUser) {
                            watchUsername = settings.primaryUser
                            // Write to app group so widget/watch can read
                            UserDefaults(suiteName: "group.com.psiegel18.TravelMapping")?
                                .set(settings.primaryUser, forKey: "widgetUsername")
                            // Reload widget timelines
                            WidgetCenter.shared.reloadAllTimelines()
                            // Keep Sentry user in sync
                            if !settings.primaryUser.isEmpty {
                                SentrySDK.configureScope { scope in
                                    scope.setUser(User(userId: settings.primaryUser))
                                    scope.setTag(value: settings.primaryUser, key: "tm.username")
                                }
                            }
                        }
                }
            } header: {
                Text("Quick Access")
            } footer: {
                Text("Set your username for one-tap access, widget stats, and Watch app.")
            }

            Section("Units") {
                Picker("Distance", selection: $settings.useMiles) {
                    Text("Miles").tag(true)
                    Text("Kilometers").tag(false)
                }
            }

            Section {
                Toggle("iCloud Sync", isOn: $favorites.iCloudSyncEnabled)
            } header: {
                Text("Sync")
            } footer: {
                Text("Sync favorites across your Apple devices. When disabled, favorites are stored only on this device.")
            }

            Section {
                Toggle("Show on Apple Watch", isOn: $sendToWatch)
            } header: {
                Text("Apple Watch")
            } footer: {
                Text("Send live trip recording status and route directions to your Apple Watch. Disable to stop sending updates.")
            }

            Section("Map Line Styles") {
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
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 30)
                }

                HStack {
                    Text("Rail Width")
                    Slider(value: $settings.railLineWidth, in: 1...6, step: 0.5)
                    Text("\(settings.railLineWidth, specifier: "%.1f")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 30)
                }
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 12) {
                    ForEach(ThemeService.availableColors, id: \.name) { item in
                        Button {
                            Haptics.selection()
                            settings.accentColorName = item.name
                        } label: {
                            Circle()
                                .fill(item.color)
                                .frame(width: 40, height: 40)
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
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Accent Color")
            } footer: {
                Text("Controls tint for tab icons, buttons, links, and interactive elements throughout the app.")
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
                Text("Cache")
            } footer: {
                Text("Cached stats, user lists, and API responses (refreshes every 6–24 hours). Pull down on any page to force-refresh. Clear the cache if data seems stale or you want to free up space.")
            }

            Section("Links") {
                Link(destination: URL(string: "https://travelmapping.net")!) {
                    Label("Travel Mapping (Roads)", systemImage: "car.fill")
                }
                Link(destination: URL(string: "https://tmrail.teresco.org")!) {
                    Label("Travel Mapping (Rail)", systemImage: "tram.fill")
                }
                Link(destination: URL(string: "https://github.com/TravelMapping/UserData")!) {
                    Label("User Data on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://travelmapping.net/devel/devel.php")!) {
                    Label("Developer Documentation", systemImage: "doc.text")
                }
            }

            Section("Travel Mapping") {
                NavigationLink {
                    GetStartedView()
                } label: {
                    Label("Get Started Guide", systemImage: "questionmark.circle")
                }
            }

            Section {
                TipJarView()
            } header: {
                Text("Tip Jar")
            } footer: {
                Text("Travel Mapping is free and open source. Tips help support continued development of the iOS app.")
            }

            Section("Support") {
                Button {
                    Haptics.light()
                    requestReview()
                } label: {
                    Label("Rate the App", systemImage: "star.fill")
                }
                Link(destination: URL(string: "https://github.com/psiegel18/TravelMapIOS/discussions")!) {
                    Label("Share Feedback", systemImage: "bubble.left.and.bubble.right")
                }
                Button {
                    Haptics.light()
                    bugReportMessage = ""
                    showBugReport = true
                } label: {
                    Label("Report a Bug", systemImage: "ladybug")
                }
            }

            Section("About") {
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
                Link(destination: URL(string: "https://psiegel18.github.io/TravelMapIOS/PRIVACY.html")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }
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
            .alert("Report a Bug", isPresented: $showBugReport) {
                TextField("Describe the issue...", text: $bugReportMessage)
                Button("Send") {
                    guard !bugReportMessage.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    let eventId = SentrySDK.capture(message: "Bug Report: \(bugReportMessage)")
                    let feedback = SentryFeedback(
                        message: bugReportMessage,
                        name: settings.primaryUser.isEmpty ? nil : settings.primaryUser,
                        email: nil,
                        source: .custom,
                        associatedEventId: eventId
                    )
                    SentrySDK.capture(feedback: feedback)
                    Haptics.success()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Describe what happened or what you expected. This will be sent as feedback to help improve the app.")
            }
        }
        .navigationTitle("Settings")
    }

    private func requestReview() {
        requestReviewAction()
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
            LabeledContent("Cached Items", value: "\(fileCount)")
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

        // Find oldest cache file modification date
        let metaFiles = files.filter { $0.lastPathComponent.hasSuffix(".meta") }
        var oldestDate: Date?
        for file in metaFiles {
            if let data = try? Data(contentsOf: file),
               let meta = try? JSONDecoder().decode(CacheMetaRead.self, from: data) {
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
    }

    private struct GitHubPR: Decodable {
        let merged_at: String?
    }
}

// MARK: - Tip Jar

struct TipJarView: View {
    @State private var products: [Product] = []
    @State private var isLoading = true
    @State private var purchaseMessage: String?


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
        "com.psiegel18.TravelMapping.tip.small": "Coffee",
        "com.psiegel18.TravelMapping.tip.medium": "Pizza",
        "com.psiegel18.TravelMapping.tip.large": "Gas Tank"
    ]

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
                HStack(spacing: 12) {
                    ForEach(products.sorted { $0.price < $1.price }) { product in
                        Button {
                            Task { await purchase(product) }
                        } label: {
                            VStack(spacing: 4) {
                                Text(Self.tipEmojis[product.id] ?? "💰")
                                    .font(.title2)
                                Text(Self.tipLabels[product.id] ?? "Tip")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(product.displayPrice)
                                    .font(.caption.bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let message = purchaseMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .task {
            do {
                products = try await Product.products(for: Self.tipIDs)
            } catch {
                print("[TipJar] Failed to load products: \(error)")
            }
            isLoading = false
        }
        .task {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
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
                    purchaseMessage = "Thank you for your support! 🎉"
                case .unverified:
                    purchaseMessage = "Purchase could not be verified."
                }
            case .userCancelled:
                break
            case .pending:
                purchaseMessage = "Purchase pending..."
            @unknown default:
                break
            }
        } catch {
            print("[TipJar] Purchase failed: \(error)")
        }
    }
}
