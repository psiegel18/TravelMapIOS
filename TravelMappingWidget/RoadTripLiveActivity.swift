import SwiftUI
import WidgetKit
import ActivityKit

// MARK: - Live Activity palette (design audit §13)
// The widget target can't see TMDesign (app target), so the brand hexes are
// defined locally. Live Activity surfaces are fixed-dark, so fixed hexes are correct.

private enum LAPalette {
    static let green = Color(tmwHex: 0x4FD69C)       // clinched / matching
    static let amber = Color(tmwHex: 0xF6B45A)       // paused
    static let amberDeep = Color(tmwHex: 0xE8912D)   // paused badge fill
    static let red = Color(tmwHex: 0xD6453E)         // recording
    static let gray = Color(tmwHex: 0x8A8A90)        // secondary labels
}

// MARK: - Units
// Distances arrive in meters; the app mirrors its units preference into the app
// group as "widgetUseMiles" (absent key = miles), same convention as the home widget.

private enum LAUnits {
    static var useMiles: Bool {
        (UserDefaults(suiteName: "group.com.psiegel18.TravelMapping")?
            .object(forKey: "widgetUseMiles") as? Bool) ?? true
    }

    static func distanceValue(_ meters: Double) -> String {
        let value = useMiles ? meters / 1609.344 : meters / 1000
        return String(format: "%.1f", value)
    }

    static var distanceLabel: String { useMiles ? "miles" : "km" }
    static var distanceAbbrev: String { useMiles ? "mi" : "km" }

    static func speedValue(_ mps: Double) -> String {
        let value = useMiles ? mps * 2.236936 : mps * 3.6
        return "\(max(0, Int(value.rounded())).formatted())"
    }

    static var speedLabel: String { useMiles ? "mph" : "km/h" }
}

// MARK: - Shared subviews

/// Pulsing REC capsule (amber PAUSED when paused). Live Activities render
/// out-of-process, so onAppear-driven repeating animations don't run; the pulse
/// uses `.symbolEffect(.pulse)` which the system animates in widget contexts.
/// Under Reduce Motion it degrades to a static dot.
private struct RecBadge: View {
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            if isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 9, weight: .heavy))
                Text("PAUSED")
                    .font(.system(size: 12, weight: .heavy))
            } else {
                pulseDot
                Text("REC")
                    .font(.system(size: 12, weight: .heavy))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            (isPaused ? LAPalette.amberDeep : LAPalette.red).opacity(0.9),
            in: Capsule()
        )
        .accessibilityLabel(isPaused ? "Paused" : "Recording")
    }

    @ViewBuilder private var pulseDot: some View {
        if reduceMotion {
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
        } else {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating)
        }
    }
}

/// Small status dot for the Dynamic Island (red pulse while recording).
private struct IslandPulseDot: View {
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isPaused {
            Image(systemName: "pause.fill")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(LAPalette.amber)
        } else if reduceMotion {
            Circle()
                .fill(LAPalette.red)
                .frame(width: 7, height: 7)
        } else {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(LAPalette.red)
                .symbolEffect(.pulse, options: .repeating)
        }
    }
}

// MARK: - Lock screen banner

private struct LockScreenTripView: View {
    let tripName: String
    let state: RoadTripAttributes.ContentState
    let timerAnchor: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Header: REC badge · trip name · timer
            HStack(spacing: 8) {
                RecBadge(isPaused: state.isPaused)
                Text(tripName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if state.isPaused {
                    Text("Paused")
                        .font(.system(size: 20, weight: .heavy, design: .monospaced))
                        .foregroundStyle(LAPalette.amber)
                } else {
                    Text(timerAnchor, style: .timer)
                        .font(.system(size: 22, weight: .heavy, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: 104, alignment: .trailing)
                }
            }

            // "Now matching" strip (paused state replaces it, per spec)
            if state.isPaused {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(LAPalette.amber)
                    Text("Trip paused")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(state.matchedSegments.formatted()) matched")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(LAPalette.gray)
                        .monospacedDigit()
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else if !state.currentRoad.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(LAPalette.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("NOW MATCHING")
                            .font(.system(size: 11, weight: .bold))
                            .kerning(0.5)
                            .foregroundStyle(LAPalette.gray)
                        Text(state.currentRoad)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(state.matchedSegments.formatted()) matched")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(LAPalette.green)
                        .monospacedDigit()
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    LAPalette.green.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(LAPalette.green.opacity(0.3), lineWidth: 1)
                )
            }

            // 3-up stats: distance · speed · segments
            HStack(spacing: 0) {
                statColumn(value: LAUnits.distanceValue(state.distanceMeters), label: LAUnits.distanceLabel)
                statDivider
                statColumn(value: LAUnits.speedValue(state.isPaused ? 0 : state.speedMps), label: LAUnits.speedLabel)
                statDivider
                statColumn(
                    value: "\(state.matchedSegments.formatted())",
                    label: "segments",
                    valueColor: LAPalette.green
                )
            }
        }
        .padding(16)
        .activityBackgroundTint(.black.opacity(0.8))
        .activitySystemActionForegroundColor(.white)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 30)
    }

    private func statColumn(value: String, label: String, valueColor: Color = .white) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 19, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(LAPalette.gray)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Widget

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
            LockScreenTripView(
                tripName: context.attributes.tripName,
                state: context.state,
                timerAnchor: timerAnchor(context.state)
            )

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        IslandPulseDot(isPaused: context.state.isPaused)
                        Text(context.attributes.tripName)
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isPaused {
                        Text("Paused")
                            .font(.system(size: 16, weight: .heavy, design: .monospaced))
                            .foregroundStyle(LAPalette.amber)
                    } else {
                        Text(timerAnchor(context.state), style: .timer)
                            .font(.system(size: 20, weight: .heavy, design: .monospaced))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: 88, alignment: .trailing)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if context.state.isPaused {
                            Text("Trip paused")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(LAPalette.amber)
                        } else if !context.state.currentRoad.isEmpty {
                            Text(context.state.currentRoad)
                                .font(.system(size: 14, weight: .bold))
                                .lineLimit(1)
                        } else {
                            Text("Recording")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(LAPalette.gray)
                        }
                        Spacer()
                        Text("\(context.state.matchedSegments.formatted()) seg · \(LAUnits.distanceValue(context.state.distanceMeters)) \(LAUnits.distanceAbbrev)")
                            .font(.system(size: 14, weight: .heavy))
                            .monospacedDigit()
                            .foregroundStyle(LAPalette.green)
                    }
                }

            } compactLeading: {
                if context.state.isPaused {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(LAPalette.amber)
                } else {
                    Text(timerAnchor(context.state), style: .timer)
                        .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: 58)
                }

            } compactTrailing: {
                HStack(spacing: 3) {
                    IslandPulseDot(isPaused: context.state.isPaused)
                    Text("\(context.state.matchedSegments.formatted())")
                        .font(.system(size: 14, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(LAPalette.green)
                }

            } minimal: {
                IslandPulseDot(isPaused: context.state.isPaused)
            }
        }
    }
}
