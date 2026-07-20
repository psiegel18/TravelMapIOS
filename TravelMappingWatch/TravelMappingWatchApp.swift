import SwiftUI
import Sentry

// MARK: - Brand palette (design audit §12)
// The watch target can't see TMDesign (app target). Watch surfaces are always
// dark, so the dark-surface brand hexes are fixed here.

enum WatchPalette {
    static let blue = Color(watchHex: 0x5B8CFF)      // Trailblazer Blue (bright)
    static let green = Color(watchHex: 0x4FD69C)     // Clinched Green / current route
    static let amber = Color(watchHex: 0xF6B45A)     // Frontier Amber / paused
    static let gold = Color(watchHex: 0xFFD84D)      // rank
    static let red = Color(watchHex: 0xF08079)       // recording (matches phone rail red, dark variant)
}

extension Color {
    /// Fixed hex color for watch surfaces.
    init(watchHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Pulsing status dot for the recording state (static under Reduce Motion).
struct WatchPulsingDot: View {
    var color: Color = WatchPalette.red
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.3 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
            .accessibilityHidden(true)
    }
}

@main
struct TravelMappingWatchApp: App {
    @StateObject private var sessionManager = WatchSessionManager.shared

    /// Mirrors the iOS channel detection in TravelMappingApp.swift: a sandbox receipt
    /// means TestFlight, otherwise App Store. Keeps watch events in the same Sentry
    /// environments (development/testflight/appstore) as the iPhone app.
    private static let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"

    init() {
        let buildChannel: String
        #if DEBUG
        buildChannel = "development"
        #else
        buildChannel = Self.isTestFlight ? "testflight" : "appstore"
        #endif

        SentrySDK.start(configureOptions: { options in
            options.dsn = "https://4d5e26ddfb95aaaef4721256a35176e5@o4510452629700608.ingest.us.sentry.io/4511177068183552"
            #if DEBUG
            options.debug = true
            #endif
            options.environment = buildChannel
            options.sampleRate = 1.0
            options.tracesSampleRate = 0.5
            options.enableCrashHandler = true
            options.attachStacktrace = true
            options.enableAutoBreadcrumbTracking = true
            options.enableNetworkBreadcrumbs = true
            options.enableCaptureFailedRequests = true

            options.initialScope = { scope in
                scope.setTag(value: "watchos", key: "app.platform")
                scope.setTag(value: buildChannel, key: "app.channel")
                scope.setTag(value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown", key: "app.version")
                return scope
            }
        })

        if let username = UserDefaults.standard.string(forKey: "watchUsername"), !username.isEmpty {
            SentrySDK.configureScope { scope in
                scope.setUser(User(userId: username))
                scope.setTag(value: username, key: "tm.username")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                WatchDashboardView()
                WatchTripView(sessionManager: sessionManager)
                WatchDirectionsView(sessionManager: sessionManager)
            }
            .tabViewStyle(.verticalPage)
        }
    }
}

// MARK: - Stats Dashboard

struct WatchDashboardView: View {
    @State private var routeCount: Int = 0
    @State private var regionCount: Int = 0
    @State private var milesTraveled: Double = 0
    @State private var rank: Int?
    @State private var totalUsers: Int?
    @State private var isLoading = true
    @AppStorage("watchUsername") private var username = "psiegel18"

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "road.lanes")
                    .font(.caption)
                    .foregroundStyle(WatchPalette.blue)
                Text("Travel Mapping")
                    .font(.caption2.bold())
            }

            if isLoading {
                ProgressView()
            } else {
                Text(formatMiles(milesTraveled))
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("Miles Traveled")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Divider()

                HStack(spacing: 16) {
                    VStack(spacing: 1) {
                        Text("\(regionCount.formatted())")
                            .font(.system(.subheadline, design: .rounded).bold())
                            .monospacedDigit()
                        Text("Regions")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 1) {
                        Text("\(routeCount.formatted())")
                            .font(.system(.subheadline, design: .rounded).bold())
                            .monospacedDigit()
                        Text("Routes")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    if let rank, let total = totalUsers {
                        VStack(spacing: 1) {
                            Text("#\(rank.formatted())")
                                .font(.system(.subheadline, design: .rounded).bold())
                                .monospacedDigit()
                                .foregroundStyle(WatchPalette.gold)
                            Text("of \(total.formatted())")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Text(username)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .task {
            await loadStats()
        }
    }

    private func formatMiles(_ miles: Double) -> String {
        if miles >= 1000 {
            return String(format: "%.1fk", miles / 1000)
        }
        return String(format: "%.0f", miles)
    }

    private func loadStats() async {
        do {
            let url = URL(string: "https://travelmapping.net/lib/getTravelerRoutes.php?dbname=TravelMapping")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "params={\"traveler\":\"\(username)\"}".data(using: .utf8)

            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let routes = json["routes"] as? [String] {
                routeCount = routes.count
            }
        } catch {
            SentrySDK.capture(error: error)
        }

        do {
            let csvURL = URL(string: "https://travelmapping.net/stats/allbyregionactiveonly.csv")!
            let (data, _) = try await URLSession.shared.data(from: csvURL)
            if let csv = String(data: data, encoding: .utf8) {
                parseCSVStats(csv)
            }
        } catch {
            SentrySDK.capture(error: error)
        }

        isLoading = false
    }

    private func parseCSVStats(_ csv: String) {
        let lines = csv.components(separatedBy: "\n")
        let lowerUser = username.lowercased()
        var userRank = 0

        for line in lines {
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 3 else { continue }

            let name = cols[0].trimmingCharacters(in: .whitespaces)
            if name == "TOTAL" || name == "Traveler" || name.isEmpty { continue }

            userRank += 1

            if name.lowercased() == lowerUser {
                rank = userRank
                milesTraveled = Double(cols[1].trimmingCharacters(in: .whitespaces)) ?? 0
                var regions = 0
                for i in 2..<cols.count {
                    if let val = Double(cols[i].trimmingCharacters(in: .whitespaces)), val > 0 {
                        regions += 1
                    }
                }
                regionCount = regions
            }
        }
        totalUsers = userRank
    }
}

// MARK: - Live Trip View

struct WatchTripView: View {
    @ObservedObject var sessionManager: WatchSessionManager

    var body: some View {
        Group {
            if let trip = sessionManager.tripState {
                ScrollView {
                    VStack(spacing: 8) {
                        // Status — recording red matches the phone's rail red (dark
                        // variant); dot pulses while recording, static when paused.
                        HStack(spacing: 4) {
                            if trip.isPaused {
                                Circle()
                                    .fill(WatchPalette.amber)
                                    .frame(width: 8, height: 8)
                            } else {
                                WatchPulsingDot()
                            }
                            Text(trip.isPaused ? "Paused" : "Recording")
                                .font(.caption2.bold())
                                .foregroundStyle(trip.isPaused ? WatchPalette.amber : WatchPalette.red)
                        }

                        // Timer — tick locally off startDate when the phone provides it
                        // (applicationContext pushes are coalesced, so the pushed
                        // elapsedTime alone freezes between updates).
                        if let start = trip.startDate, !trip.isPaused {
                            TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
                                Text(WatchSessionManager.TripState.format(max(timeline.date.timeIntervalSince(start), 0)))
                                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                                    .monospacedDigit()
                            }
                        } else {
                            Text(trip.formattedTime)
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                        }

                        // Speed + Distance
                        HStack(spacing: 12) {
                            VStack(spacing: 1) {
                                Text(String(format: "%.0f", trip.speedMPH))
                                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                                    .monospacedDigit()
                                Text("mph")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            VStack(spacing: 1) {
                                Text(String(format: "%.1f", trip.distanceMiles))
                                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                                    .monospacedDigit()
                                Text("mi")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Current segment — clinched green, matching the phone's
                        // "now matching" accent.
                        if !trip.currentSegment.isEmpty {
                            Divider()
                            Text(trip.currentSegment)
                                .font(.caption2.bold())
                                .foregroundStyle(WatchPalette.green)
                                .multilineTextAlignment(.center)
                        }

                        Divider()

                        // Counts
                        HStack(spacing: 12) {
                            Label("\(trip.matchedCount.formatted())", systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(WatchPalette.green)
                            Label("\(trip.pointCount.formatted())", systemImage: "location")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Text(trip.tripName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "car.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No Active Trip")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text("Start a trip on your iPhone to see live status here.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }
}

// MARK: - Directions View

struct WatchDirectionsView: View {
    @ObservedObject var sessionManager: WatchSessionManager

    var body: some View {
        Group {
            if let dirs = sessionManager.directions {
                List {
                    Section {
                        VStack(spacing: 2) {
                            Text(dirs.routeName)
                                .font(.caption.bold())
                            Text("\(dirs.distanceMiles) · \(dirs.timeFormatted)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    }

                    ForEach(Array(dirs.steps.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1). \(step.instruction)")
                                .font(.caption2)
                            if !step.distanceMiles.isEmpty {
                                Text(step.distanceMiles)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            if let notice = step.notice {
                                Text(notice)
                                    .font(.system(size: 10))
                                    .foregroundStyle(WatchPalette.amber)
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No Directions")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text("Use Route Planner on your iPhone and tap \"Send to Watch\".")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }
}
