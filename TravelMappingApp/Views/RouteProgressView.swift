import Sentry
import SwiftUI

struct RouteProgressView: View {
    let username: String
    let root: String
    let listName: String

    @State private var waypoints: [WaypointStatus] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isRetrying = false
    @AppStorage("useMiles") private var useMiles = true

    struct WaypointStatus: Identifiable {
        let id: Int
        let name: String
        let isClinched: Bool // segment AFTER this waypoint is clinched
    }

    // Count segments only — the last waypoint mirrors the previous segment's
    // clinched state for display, so it's excluded from the segment tally.
    var clinchedCount: Int { waypoints.dropLast().filter(\.isClinched).count }
    var totalCount: Int { max(waypoints.count - 1, 0) }
    var percentage: Double { totalCount > 0 ? Double(clinchedCount) / Double(totalCount) * 100 : 0 }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading route...")
            } else if let error = errorMessage {
                loadErrorView(message: error)
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

    /// Inline error state with a retry button (mirrors the ErrorView pattern).
    private func loadErrorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Couldn't Load Route")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                Haptics.light()
                isRetrying = true
                Task {
                    isLoading = true
                    await loadRouteData()
                    isRetrying = false
                }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(isRetrying)
            .opacity(isRetrying ? 0.5 : 1)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadRouteData() async {
        errorMessage = nil
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
                // clinched is per-segment (n-1 entries for n waypoints). The last
                // waypoint has no following segment, so use the previous segment's
                // state — a fully-clinched route then shows all checkmarks.
                let clinched: Bool
                if i < route.clinched.count {
                    clinched = route.clinched[i]
                } else if i > 0, i - 1 < route.clinched.count {
                    clinched = route.clinched[i - 1]
                } else {
                    clinched = false
                }
                wps.append(WaypointStatus(
                    id: i,
                    name: "Waypoint \(i + 1)", // API doesn't return names in this endpoint
                    isClinched: clinched
                ))
            }

            waypoints = wps
        } catch {
            SentrySDK.capture(error: error)
            errorMessage = ErrorView.friendly(error.localizedDescription)
        }

        isLoading = false
    }
}
