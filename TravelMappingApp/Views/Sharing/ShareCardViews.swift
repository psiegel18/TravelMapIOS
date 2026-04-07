import SwiftUI

// MARK: - Profile Stats Card

struct ProfileShareCard: View {
    let username: String
    let regions: Int
    let routes: Int
    let clinchedMiles: Double
    let useMiles: Bool
    let rank: (rank: Int, total: Int)?

    private var distanceText: String {
        let value = useMiles ? clinchedMiles : clinchedMiles * 1.60934
        let unit = useMiles ? "mi" : "km"
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return "\(formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))") \(unit)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Gradient header
            VStack(spacing: 8) {
                Image(systemName: "road.lanes")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Travel Mapping")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.7))
                Text(username)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                LinearGradient(
                    colors: [.blue, .indigo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            // Stats grid
            VStack(spacing: 16) {
                HStack(spacing: 0) {
                    statColumn(value: regions.formatted(), label: "Regions", icon: "globe")
                    Divider().frame(height: 40)
                    statColumn(value: routes.formatted(), label: "Routes", icon: "road.lanes")
                    Divider().frame(height: 40)
                    statColumn(value: distanceText, label: "Traveled", icon: "point.topleft.down.to.point.bottomright.curvepath")
                }

                if let rank {
                    HStack(spacing: 4) {
                        Image(systemName: "trophy.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption2)
                        Text("Ranked #\(rank.rank.formatted()) of \(rank.total.formatted())")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 12)

            // Footer
            Divider()
            Text("travelmapping.net/user/?u=\(username)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 8)
        }
        .frame(width: 360)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private func statColumn(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.blue)
            Text(value)
                .font(.title3.bold())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.blue)

                Text("travelmapping.net")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
        }
        .frame(width: 360)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}
