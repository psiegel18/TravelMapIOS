import SwiftUI
import Sentry

@main
struct TravelMappingWatchApp: App {
    @StateObject private var sessionManager = WatchSessionManager.shared

    init() {
        SentrySDK.start(configureOptions: { options in
            options.dsn = "https://4d5e26ddfb95aaaef4721256a35176e5@o4510452629700608.ingest.us.sentry.io/4511177068183552"
            #if DEBUG
            options.debug = true
            options.environment = "development"
            #else
            options.environment = "production"
            #endif
            options.sampleRate = 1.0
            options.tracesSampleRate = 0.5
            options.enableCrashHandler = true
            options.attachStacktrace = true
            options.enableAutoBreadcrumbTracking = true
            options.enableNetworkBreadcrumbs = true
            options.enableCaptureFailedRequests = true

            options.initialScope = { scope in
                scope.setTag(value: "watchos", key: "app.platform")
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
                    .foregroundStyle(.blue)
                Text("Travel Mapping")
                    .font(.caption2.bold())
            }

            if isLoading {
                ProgressView()
            } else {
                Text(formatMiles(milesTraveled))
                    .font(.system(.title2, design: .rounded).bold())
                Text("Miles Traveled")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Divider()

                HStack(spacing: 16) {
                    VStack(spacing: 1) {
                        Text("\(regionCount)")
                            .font(.system(.subheadline, design: .rounded).bold())
                        Text("Regions")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 1) {
                        Text("\(routeCount)")
                            .font(.system(.subheadline, design: .rounded).bold())
                        Text("Routes")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    if let rank, let total = totalUsers {
                        VStack(spacing: 1) {
                            Text("#\(rank)")
                                .font(.system(.subheadline, design: .rounded).bold())
                            Text("of \(total)")
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
            print("Watch routes error: \(error)")
        }

        do {
            let csvURL = URL(string: "https://travelmapping.net/stats/allbyregionactiveonly.csv")!
            let (data, _) = try await URLSession.shared.data(from: csvURL)
            if let csv = String(data: data, encoding: .utf8) {
                parseCSVStats(csv)
            }
        } catch {
            print("Watch stats error: \(error)")
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
                        // Status
                        HStack(spacing: 4) {
                            Circle()
                                .fill(trip.isPaused ? .orange : .red)
                                .frame(width: 8, height: 8)
                            Text(trip.isPaused ? "Paused" : "Recording")
                                .font(.caption2.bold())
                                .foregroundStyle(trip.isPaused ? .orange : .red)
                        }

                        // Timer
                        Text(trip.formattedTime)
                            .font(.system(.title, design: .rounded).bold())
                            .monospacedDigit()

                        // Speed + Distance
                        HStack(spacing: 12) {
                            VStack(spacing: 1) {
                                Text(String(format: "%.0f", trip.speedMPH))
                                    .font(.system(.headline, design: .rounded).bold())
                                Text("mph")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            VStack(spacing: 1) {
                                Text(String(format: "%.1f", trip.distanceMiles))
                                    .font(.system(.headline, design: .rounded).bold())
                                Text("mi")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Current segment
                        if !trip.currentSegment.isEmpty {
                            Divider()
                            Text(trip.currentSegment)
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .multilineTextAlignment(.center)
                        }

                        Divider()

                        // Counts
                        HStack(spacing: 12) {
                            Label("\(trip.matchedCount)", systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Label("\(trip.pointCount)", systemImage: "location")
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
                                    .foregroundStyle(.orange)
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
