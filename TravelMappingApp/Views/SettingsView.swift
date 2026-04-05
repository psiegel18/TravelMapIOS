import SwiftUI
import StoreKit
import WidgetKit

struct SettingsView: View {
    @Environment(\.requestReview) private var requestReviewAction
    @ObservedObject private var settings = SyncedSettingsService.shared
    @ObservedObject private var favorites = FavoritesService.shared
    @AppStorage("watchUsername") private var watchUsername = ""

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

            Section("Tools") {
                NavigationLink {
                    RoutePlannerView()
                } label: {
                    Label("Route Planner", systemImage: "arrow.triangle.turn.up.right.diamond")
                }
            }

            Section {
                Toggle("iCloud Sync", isOn: $favorites.iCloudSyncEnabled)
            } header: {
                Text("Sync")
            } footer: {
                Text("Sync favorites across your Apple devices. When disabled, favorites are stored only on this device.")
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

                Picker("Rail Style", selection: $settings.railLineStyle) {
                    ForEach(MapStyleService.LineStyle.allCases) { style in
                        HStack {
                            LineStylePreview(style: style).frame(width: 40)
                            Text(style.rawValue)
                        }
                        .tag(style.rawValue)
                    }
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
                Text("Cached stats, user lists, and API responses (refreshes every 6–24 hours). Pull down on Stats or Leaderboard to force-refresh. Clear the cache if data seems stale or you want to free up space.")
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
                Link(destination: URL(string: "https://github.com/psiegel18/TravelMapIOS/issues/new")!) {
                    Label("Report a Bug", systemImage: "ladybug")
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("Data Source", value: "travelmapping.net + tmrail.teresco.org")
                LabeledContent("User Data", value: "GitHub API")
                Link(destination: URL(string: "https://psiegel18.github.io/TravelMapIOS/PRIVACY.html")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Cache Size", value: cacheSize)
            LabeledContent("Cached Items", value: "\(fileCount)")
        }
        .task { await refresh() }
    }

    private func refresh() async {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TMCache-v2")

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey]
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
    }
}
