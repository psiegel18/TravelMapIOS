import SwiftUI
import MapKit

struct TripShareCard: View {
    let trip: RoadTrip
    let trackImage: UIImage?

    private var durationText: String {
        guard let end = trip.endDate else { return "In progress" }
        let interval = end.timeIntervalSince(trip.startDate)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Gradient header
            VStack(spacing: 6) {
                Image(systemName: "road.lanes")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Travel Mapping")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.7))
                Text(trip.name)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [.blue, .indigo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            // Map image
            if let image = trackImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 360, height: 220)
                    .clipped()
            } else {
                Rectangle()
                    .fill(.blue.opacity(0.05))
                    .frame(width: 360, height: 220)
                    .overlay {
                        Image(systemName: "map")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }

            // Stats
            HStack(spacing: 0) {
                statColumn(value: durationText, label: "Duration")
                Divider().frame(height: 36)
                statColumn(value: trip.rawPoints.count.formatted(), label: "GPS Points")
                Divider().frame(height: 36)
                statColumn(value: trip.matchedSegments.count.formatted(), label: "Segments")
            }
            .padding(.vertical, 14)

            // Date + Footer
            VStack(spacing: 4) {
                Text(trip.startDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Text("travelmapping.net")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: 360)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private func statColumn(value: String, label: String) -> some View {
        VStack(spacing: 2) {
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

@MainActor
func renderTripShareImage(trip: RoadTrip) async -> UIImage? {
    let mapImage = await renderTripMap(trip: trip)
    let card = TripShareCard(trip: trip, trackImage: mapImage)
    return renderShareImage(view: card)
}

@MainActor
private func renderTripMap(trip: RoadTrip) async -> UIImage? {
    guard trip.rawPoints.count >= 2 else { return nil }

    let coords = trip.rawPoints.map(\.coordinate)
    let lats = coords.map(\.latitude)
    let lngs = coords.map(\.longitude)
    let centerLat = (lats.min()! + lats.max()!) / 2
    let centerLng = (lngs.min()! + lngs.max()!) / 2
    let spanLat = max((lats.max()! - lats.min()!) * 1.3, 0.01)
    let spanLng = max((lngs.max()! - lngs.min()!) * 1.3, 0.01)

    let options = MKMapSnapshotter.Options()
    options.region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
        span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLng)
    )
    options.size = CGSize(width: 720, height: 440)
    options.mapType = .standard

    do {
        let snapshot = try await MKMapSnapshotter(options: options).start()
        let image = snapshot.image
        UIGraphicsBeginImageContextWithOptions(image.size, true, image.scale)
        defer { UIGraphicsEndImageContext() }

        image.draw(at: .zero)
        guard let context = UIGraphicsGetCurrentContext() else { return image }

        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(4)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for (i, coord) in coords.enumerated() {
            let point = snapshot.point(for: coord)
            if i == 0 {
                context.move(to: point)
            } else {
                context.addLine(to: point)
            }
        }
        context.strokePath()

        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    } catch {
        return nil
    }
}
