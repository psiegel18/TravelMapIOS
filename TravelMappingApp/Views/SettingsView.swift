import SwiftUI
import StoreKit
import WidgetKit
import Sentry

struct SettingsView: View {
    @ObservedObject private var settings = SyncedSettingsService.shared
    @ObservedObject private var favorites = FavoritesService.shared
    @AppStorage("watchUsername") private var watchUsername = ""
    @AppStorage("sendToWatch") private var sendToWatch = true
    @State private var versionTapCount = 0
    @State private var showSentryTestAlert = false
    @State private var showBugReport = false
    @State private var bugReportMessage = ""
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
            // 1. Get Started Guide
            Section("Travel Mapping") {
                NavigationLink {
                    GetStartedView()
                } label: {
                    Label("Get Started Guide", systemImage: "questionmark.circle")
                }
            }

            // 2. Primary User
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
                            userValidationResult = nil
                            watchUsername = settings.primaryUser
                            UserDefaults(suiteName: "group.com.psiegel18.TravelMapping")?
                                .set(settings.primaryUser, forKey: "widgetUsername")
                            WidgetCenter.shared.reloadAllTimelines()
                            if !settings.primaryUser.isEmpty {
                                SentrySDK.configureScope { scope in
                                    scope.setUser(User(userId: settings.primaryUser))
                                    scope.setTag(value: settings.primaryUser, key: "tm.username")
                                }
                            }
                        }
                    if isValidatingUser {
                        ProgressView()
                            .controlSize(.small)
                    } else if let valid = userValidationResult {
                        Image(systemName: valid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(valid ? .green : .orange)
                    }
                }
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
            } header: {
                Text("Quick Access")
            } footer: {
                if let valid = userValidationResult, !valid {
                    Text("Username not found on Travel Mapping. Check your spelling or create an account from the Get Started guide above.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Set your username for one-tap access, widget stats, and Watch app.")
                }
            }

            // 3. Units
            Section("Units") {
                Picker("Distance", selection: $settings.useMiles) {
                    Text("Miles").tag(true)
                    Text("Kilometers").tag(false)
                }
                .onChange(of: settings.useMiles) {
                    UserDefaults(suiteName: "group.com.psiegel18.TravelMapping")?
                        .set(settings.useMiles, forKey: "widgetUseMiles")
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }

            // 4. Map Line Styles
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

            // 5. Accent Color
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

            // 6. Cache
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
                Text("Cached stats, user lists, and API responses (refreshes every 6\u{2013}24 hours). Pull down on any page to force-refresh.")
            }

            // 7. Sync & Apple Watch
            Section {
                Toggle("iCloud Sync", isOn: $favorites.iCloudSyncEnabled)
                Toggle("Show on Apple Watch", isOn: $sendToWatch)
            } header: {
                Text("Sync & Apple Watch")
            } footer: {
                Text("iCloud syncs favorites across devices. Apple Watch receives live trip status and route directions.")
            }

            // 8. Support
            Section("Support") {
                Link(destination: URL(string: "https://apps.apple.com/app/id6761671062?action=write-review")!) {
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

            // 9. Tip Jar
            Section {
                TipJarView()
            } header: {
                Text("Tip Jar")
            } footer: {
                Text("Travel Mapping is free and open source. Tips help support continued iOS app development.")
            }

            // 10. About
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
                NavigationLink {
                    PrivacyPolicyView()
                } label: {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }

            // 11. Links
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
            }
        }
        .navigationTitle("Settings")
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

    /// Returns true if found, false if confirmed not found, nil if the request failed (don't cache failures).
    private func validateUsername(_ username: String) async -> Bool? {
        let url = URL(string: "https://travelmapping.net/lib/getTravelerRoutes.php?dbname=TravelMapping")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "params={\"traveler\":\"\(username)\"}".data(using: .utf8)

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
                HStack(spacing: 10) {
                    ForEach(products.sorted { $0.price < $1.price }) { product in
                        Button {
                            Task { await purchase(product) }
                        } label: {
                            VStack(spacing: 4) {
                                Text(Self.tipEmojis[product.id] ?? "💰")
                                    .font(.title2)
                                Text(Self.tipLabels[product.id] ?? "Tip")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Text(product.displayPrice)
                                    .font(.caption.bold())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)
                            .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
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
                SentrySDK.capture(error: error)
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
                    SentrySDK.logger.info("Tip purchased", attributes: [
                        "productId": product.id,
                        "price": product.displayPrice,
                    ])
                case .unverified:
                    purchaseMessage = "Purchase could not be verified."
                    SentrySDK.logger.warn("Tip purchase unverified", attributes: ["productId": product.id])
                }
            case .userCancelled:
                break
            case .pending:
                purchaseMessage = "Purchase pending..."
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
                    bullet("Accessed only when you start a Road Trip or tap the location button")
                    bullet("Stored locally on your device and in iCloud if enabled")
                    bullet("Never sent to third-party servers")
                    bullet("Stops when you end the recording session")
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
                    Text("No personal information is transmitted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                policyCard(icon: "ant.fill", color: .teal, title: "Crash Reporting") {
                    Text("We use Sentry to collect anonymous crash reports to improve stability.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    bullet("Device model, OS version, app version")
                    bullet("Stack trace (what code was running)")
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
                    noBullet("Advertising or tracking data")
                    noBullet("Your road trip data or location history")
                }

                policyCard(icon: "externaldrive.fill", color: .indigo, title: "Data Storage") {
                    storagePill(icon: "iphone", label: "Device", detail: "Preferences, favorites, cache, trips")
                    storagePill(icon: "icloud", label: "iCloud", detail: "Favorites & preferences (optional)")
                    storagePill(icon: "server.rack", label: "Sentry", detail: "Anonymous crash reports only")
                }

                policyCard(icon: "slider.horizontal.3", color: .mint, title: "Your Choices") {
                    bullet("iCloud sync: Toggle on/off in Settings")
                    bullet("Location: Only for trip recording \u{2014} deny and still use the app")
                    bullet("Cache: Clear anytime from Settings")
                }

                policyCard(icon: "figure.child", color: .yellow, title: "Children's Privacy") {
                    Text("We do not knowingly collect data from children under 13.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Footer
                VStack(spacing: 4) {
                    Text("Last updated: April 12, 2026")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Link("View web version", destination: URL(string: "https://psiegel18.github.io/TravelMapIOS/PRIVACY.html")!)
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
