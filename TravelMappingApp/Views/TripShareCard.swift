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
            // Header
            VStack(spacing: 6) {
                HStack {
                    Image(systemName: "road.lanes")
                        .foregroundStyle(.blue)
                    Text("Travel Mapping")
                        .font(.headline.bold())
                    Spacer()
                }
                HStack {
                    Text(trip.name)
                        .font(.title2.bold())
                    Spacer()
                }
            }
            .padding()

            // Map image
            if let image = trackImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 340, height: 220)
                    .clipped()
            } else {
                Rectangle()
                    .fill(.blue.opacity(0.1))
                    .frame(width: 340, height: 220)
                    .overlay {
                        Image(systemName: "map")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }

            // Stats
            HStack(spacing: 24) {
                VStack(spacing: 2) {
                    Text(durationText)
                        .font(.title3.bold())
                    Text("Duration")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 2) {
                    Text("\(trip.rawPoints.count)")
                        .font(.title3.bold())
                    Text("GPS Points")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 2) {
                    Text("\(trip.matchedSegments.count)")
                        .font(.title3.bold())
                    Text("Segments")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            // Footer
            Text("travelmapping.net")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(width: 340)
        .background(Color(.systemBackground))
    }
}

@MainActor
func renderTripShareImage(trip: RoadTrip) async -> UIImage? {
    // Render the map to an image first
    let mapImage = await renderTripMap(trip: trip)

    // Now render the full card
    let card = TripShareCard(trip: trip, trackImage: mapImage)
    let renderer = ImageRenderer(content: card)
    renderer.scale = UIScreen.main.scale
    return renderer.uiImage
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
    options.size = CGSize(width: 680, height: 440)
    options.mapType = .standard

    let snapshotter = MKMapSnapshotter(options: options)

    do {
        let snapshot = try await snapshotter.start()

        // Draw the GPS track on top of the map image
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
