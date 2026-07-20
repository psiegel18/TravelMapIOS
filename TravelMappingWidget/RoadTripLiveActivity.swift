import SwiftUI
import WidgetKit
import ActivityKit

struct RoadTripLiveActivity: Widget {
    /// Live-timer anchor derived from the trip's *active* elapsed time. Anchoring to
    /// attributes.startDate would keep counting through pauses; this re-anchors on
    /// every content update so paused stretches are excluded.
    private func timerAnchor(_ state: RoadTripAttributes.ContentState) -> Date {
        Date(timeIntervalSinceNow: -state.elapsedTime)
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RoadTripAttributes.self) { context in
            // Lock screen banner
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "car.fill")
                            .foregroundStyle(.blue)
                        Text(context.attributes.tripName)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    if !context.state.currentRoad.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "road.lanes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(context.state.currentRoad)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if context.state.isPaused {
                        Text("Paused")
                            .font(.system(.title3, design: .monospaced).bold())
                            .foregroundStyle(.orange)
                    } else {
                        Text(timerAnchor(context.state), style: .timer)
                            .font(.system(.title3, design: .monospaced).bold())
                            .monospacedDigit()
                    }

                    Text("\(context.state.matchedSegments) segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.8))

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        Image(systemName: "car.fill")
                            .foregroundStyle(.blue)
                        Text(context.attributes.tripName)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isPaused {
                        Text("Paused")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.orange)
                    } else {
                        Text(timerAnchor(context.state), style: .timer)
                            .font(.system(.caption, design: .monospaced))
                            .monospacedDigit()
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if !context.state.currentRoad.isEmpty {
                            Label(context.state.currentRoad, systemImage: "road.lanes")
                                .font(.caption)
                        }
                        Spacer()
                        Text("\(context.state.matchedSegments) segments")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            } compactLeading: {
                Image(systemName: "car.fill")
                    .foregroundStyle(.blue)

            } compactTrailing: {
                if context.state.isPaused {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text(timerAnchor(context.state), style: .timer)
                        .font(.system(.caption2, design: .monospaced))
                        .monospacedDigit()
                }

            } minimal: {
                Image(systemName: "car.fill")
                    .foregroundStyle(.blue)
            }
        }
    }
}
