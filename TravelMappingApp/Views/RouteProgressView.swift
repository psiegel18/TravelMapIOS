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
    private var isComplete: Bool { totalCount > 0 && clinchedCount >= totalCount }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading route...")
            } else if let error = errorMessage {
                loadErrorView(message: error)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        headerCard
                        waypointList
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

    // MARK: Header card

    private var headerCard: some View {
        VStack(spacing: 10) {
            Text(listName)
                .font(.system(size: 22, weight: .heavy))
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                Image(systemName: isComplete ? "checkmark.seal.fill" : "checkmark.seal")
                    .font(.system(size: 15, weight: .bold))
                    .accessibilityHidden(true)
                Text(String(format: "%.1f%% complete", percentage))
                    .font(.system(size: 16, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(isComplete ? TMDesign.clinched : TMDesign.accent)

            ProgressView(value: Double(clinchedCount), total: Double(max(totalCount, 1)))
                .tint(isComplete ? TMDesign.clinched : TMDesign.accent)

            Text("\(clinchedCount.formatted()) of \(totalCount.formatted()) segments")
                .font(.system(size: 15))
                .monospacedDigit()
                .foregroundStyle(TMDesign.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Waypoint list — status by shape + label, not color alone

    private var waypointList: some View {
        VStack(spacing: 0) {
            ForEach(waypoints) { wp in
                HStack(spacing: 12) {
                    // Status indicator: filled check when clinched, ring outline otherwise
                    if wp.isClinched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(TMDesign.clinched)
                            .accessibilityHidden(true)
                    } else {
                        Circle()
                            .strokeBorder(TMDesign.chevron, lineWidth: 2)
                            .frame(width: 17, height: 17)
                            .accessibilityHidden(true)
                    }

                    Text(wp.name)
                        .font(.system(size: 15, weight: .medium))

                    Spacer()

                    if wp.isClinched {
                        Text("Clinched")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(TMDesign.clinched)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(wp.name), \(wp.isClinched ? "clinched" : "not clinched")")

                if wp.id < waypoints.count - 1 {
                    // Connector line between waypoints, aligned with indicator center
                    HStack {
                        Rectangle()
                            .fill(wp.isClinched ? TMDesign.clinched : TMDesign.hairline)
                            .frame(width: 2, height: 20)
                            .padding(.leading, 23.5)
                        Spacer()
                    }
                    .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 8)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Inline error state with a retry button (mirrors the ErrorView card language).
    private func loadErrorView(message: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(TMDesign.redChipBG)
                    .frame(width: 72, height: 72)
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TMDesign.redChipFG)
            }
            .accessibilityHidden(true)

            Text("Couldn't Load Route")
                .font(.system(size: 18, weight: .heavy))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(TMDesign.secondaryText)
                .multilineTextAlignment(.center)

            Button {
                Haptics.light()
                isRetrying = true
                Task {
                    isLoading = true
                    await loadRouteData()
                    isRetrying = false
                }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TMDesign.accent)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 44)
                    .background(
                        Capsule().strokeBorder(TMDesign.accent, lineWidth: 1.5)
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isRetrying)
            .opacity(isRetrying ? 0.5 : 1)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
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
