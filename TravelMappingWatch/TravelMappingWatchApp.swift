import SwiftUI

@main
struct TravelMappingWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchDashboardView()
        }
    }
}

struct WatchDashboardView: View {
    @State private var routeCount: Int = 0
    @State private var isLoading = true
    @AppStorage("watchUsername") private var username = "psiegel18"

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "road.lanes")
                    .font(.title2)
                    .foregroundStyle(.blue)

                Text("Travel Mapping")
                    .font(.headline)

                if isLoading {
                    ProgressView()
                } else {
                    Text("\(routeCount)")
                        .font(.system(.largeTitle, design: .rounded).bold())
                    Text("Routes Traveled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(username)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
        .task {
            await loadStats()
        }
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
            print("Watch API error: \(error)")
        }
        isLoading = false
    }
}
