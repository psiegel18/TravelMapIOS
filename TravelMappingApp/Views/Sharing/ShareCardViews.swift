import SwiftUI

// Share cards render to an image via renderShareImage (forced light mode), so
// they use fixed light-mode brand hexes rather than adaptive TMDesign tokens —
// adaptive UIColor-backed colors may not resolve predictably inside ImageRenderer.

// MARK: - Static completion ring
// TMCompletionRing animates 0 → value onAppear; ImageRenderer can snapshot before
// that animation runs, which would render an empty ring. Share cards need a static
// ring drawn at its final value.

private struct ShareCompletionRing: View {
    let fraction: Double
    var diameter: CGFloat = 88
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 22, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("clinched")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Profile Stats Card

struct ProfileShareCard: View {
    let username: String
    let regions: Int
    let routes: Int
    let clinchedMiles: Double
    let useMiles: Bool
    let rank: (rank: Int, total: Int)?
    /// Overall completion (0...1) for the header ring. The card's current data
    /// sources don't carry an available-mileage total, so this is optional; the
    /// ring is omitted when nil rather than showing a fabricated value.
    var completionFraction: Double? = nil

    private var distanceText: String {
        let value = useMiles ? clinchedMiles : clinchedMiles * 1.60934
        let unit = useMiles ? "mi" : "km"
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return "\(formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))") \(unit)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header band — brand gradient (audit §12)
            VStack(spacing: 12) {
                HStack(spacing: 5) {
                    Image(systemName: "road.lanes")
                        .font(.system(size: 12, weight: .bold))
                    Text("TRAVEL MAPPING")
                        .font(.system(size: 13, weight: .bold))
                        .kerning(1.2)
                }
                .foregroundStyle(.white.opacity(0.8))

                if let completionFraction {
                    ShareCompletionRing(fraction: completionFraction)
                }

                VStack(spacing: 3) {
                    Text(username)
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("clinched across \(regions.formatted()) regions")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 16)
            .background(
                LinearGradient(
                    colors: [Color(tmHex: 0x2F6BF0), Color(tmHex: 0x1E3FA8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            // Footer 3-up: miles / routes / rank (rank in amber)
            HStack(spacing: 0) {
                statColumn(value: distanceText, label: useMiles ? "miles" : "km")
                Divider().frame(height: 44)
                statColumn(value: routes.formatted(), label: "routes")
                Divider().frame(height: 44)
                if let rank {
                    statColumn(
                        value: "#\(rank.rank.formatted())",
                        label: "of \(rank.total.formatted())",
                        valueColor: Color(tmHex: 0xB4700F)
                    )
                } else {
                    statColumn(value: regions.formatted(), label: "regions")
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 12)

            // Footer link
            Divider()
            Text("travelmapping.net")
                .font(.system(size: 12))
                .foregroundStyle(Color(tmHex: 0xB4B4BA))
                .padding(.vertical, 9)
        }
        .frame(width: 360)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(tmHex: 0xE6E6EC), lineWidth: 0.5)
        )
    }

    private func statColumn(value: String, label: String, valueColor: Color = .primary) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(tmHex: 0x8A8A90))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Map Share Card

struct MapShareCard: View {
    let username: String
    let mapImage: UIImage
    let regionCount: Int
    let routeCount: Int

    var body: some View {
        VStack(spacing: 0) {
            // Map image with gradient overlay
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: mapImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 360, height: 240)
                    .clipped()

                // Bottom gradient
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 80)

                // Overlay text
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(username)'s Map")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                    Text("\(regionCount.formatted()) regions, \(routeCount.formatted()) routes")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(12)
            }

            // CTA footer
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "hand.tap.fill")
                        .font(.caption2)
                    Text("Tap to explore the interactive map")
                        .font(.caption)
                }
                .foregroundStyle(Color(tmHex: 0x2F6BF0))

                Text("travelmapping.net")
                    .font(.caption2)
                    .foregroundStyle(Color(tmHex: 0xB4B4BA))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.white)
        }
        .frame(width: 360)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(tmHex: 0xE6E6EC), lineWidth: 0.5)
        )
    }
}
