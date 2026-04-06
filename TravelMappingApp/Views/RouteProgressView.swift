import SwiftUI

struct RouteProgressView: View {
    let username: String
    let root: String
    let listName: String

    @State private var waypoints: [WaypointStatus] = []
    @State private var isLoading = true
    @AppStorage("useMiles") private var useMiles = true

    struct WaypointStatus: Identifiable {
        let id: Int
        let name: String
        let isClinched: Bool // segment AFTER this waypoint is clinched
    }

    var clinchedCount: Int { waypoints.filter(\.isClinched).count }
    var totalCount: Int { max(waypoints.count - 1, 0) }
    var percentage: Double { totalCount > 0 ? Double(clinchedCount) / Double(totalCount) * 100 : 0 }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading route...")
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // Header
                        VStack(spacing: 8) {
                            Text(listName)
                                .font(.title2.bold())
                            Text(String(format: "%.1f%% complete", percentage))
                                .font(.headline)
                                .foregroundStyle(percentage >= 100 ? .green : .blue)
                            ProgressView(value: Double(clinchedCount), total: Double(max(totalCount, 1)))
                                .tint(percentage >= 100 ? .green : .blue)
                            Text("\(clinchedCount.formatted()) / \(totalCount.formatted()) segments")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))

                        // Waypoint list
                        VStack(spacing: 0) {
                            ForEach(waypoints) { wp in
                                HStack(spacing: 12) {
                                    // Status indicator
                                    Circle()
                                        .fill(wp.isClinched ? .blue : .gray.opacity(0.3))
                                        .frame(width: 12, height: 12)

                                    Text(wp.name)
                                        .font(.subheadline)

                                    Spacer()

                                    if wp.isClinched {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal)

                                if wp.id < waypoints.count - 1 {
                                    // Connector line between waypoints
                                    HStack {
                                        Rectangle()
                                            .fill(wp.isClinched ? .blue : .gray.opacity(0.2))
                                            .frame(width: 2, height: 20)
                                            .padding(.leading, 17) // align with circle center
                                        Spacer()
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(listName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadRouteData()
        }
        .refreshable {
            await loadRouteData()
        }
    }

    private func loadRouteData() async {
        do {
            let details = try await TravelMappingAPI.shared.getRouteData(
                roots: [root],
                traveler: username
            )

            guard let route = details.first else {
                isLoading = false
                return
            }

            var wps: [WaypointStatus] = []
            for (i, _) in route.coordinates.enumerated() {
                let clinched = i < route.clinched.count ? route.clinched[i] : false
                wps.append(WaypointStatus(
                    id: i,
                    name: "Waypoint \(i + 1)", // API doesn't return names in this endpoint
                    isClinched: clinched
                ))
            }

            waypoints = wps
        } catch {
            print("Route progress error: \(error)")
        }

        isLoading = false
    }
}
