import SwiftUI
import MapKit

struct TripShareCard: View {
    let trip: RoadTrip
    let trackImage: UIImage?
    /// Units preference, injected by renderTripShareImage (the card renders to an
    /// image, so it can't observe settings itself).
    var useMiles: Bool = true

    private var durationText: String {
        guard let end = trip.endDate else { return "In progress" }
        let interval = end.timeIntervalSince(trip.startDate)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// Trip distance summed from the recorded GPS track (meters → mi/km).
    /// The audit flagged that the recap shared duration/points/segments but
    /// never the miles actually driven.
    private var distanceText: String {
        let points = trip.rawPoints
        guard points.count > 1 else { return useMiles ? "0 mi" : "0 km" }
        var meters: Double = 0
        var prev = CLLocation(latitude: points[0].latitude, longitude: points[0].longitude)
        for point in points.dropFirst() {
            let next = CLLocation(latitude: point.latitude, longitude: point.longitude)
            meters += next.distance(from: prev)
            prev = next
        }
        let value = useMiles ? meters / 1609.344 : meters / 1000
        return String(format: "%.1f %@", value, useMiles ? "mi" : "km")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header band — brand gradient (audit §12)
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "road.lanes")
                        .font(.system(size: 12, weight: .bold))
                    Text("TRAVEL MAPPING")
                        .font(.system(size: 13, weight: .bold))
                        .kerning(1.2)
                }
                .foregroundStyle(.white.opacity(0.8))
                Text(trip.name)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .background(
                LinearGradient(
                    colors: [Color(tmHex: 0x2F6BF0), Color(tmHex: 0x1E3FA8)],
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
                    .fill(Color(tmHex: 0x2F6BF0).opacity(0.05))
                    .frame(width: 360, height: 220)
                    .overlay {
                        Image(systemName: "map")
                            .font(.largeTitle)
                            .foregroundStyle(Color(tmHex: 0x8A8A90))
                    }
            }

            // Stats 3-up: duration / distance / segments (audit §8 — distance
            // was missing from the recap; GPS points demoted to the footer).
            HStack(spacing: 0) {
                statColumn(value: durationText, label: "Duration")
                Divider().frame(height: 40)
                statColumn(value: distanceText, label: useMiles ? "Miles" : "Kilometers")
                Divider().frame(height: 40)
                statColumn(
                    value: trip.matchedSegments.count.formatted(),
                    label: "Segments",
                    valueColor: Color(tmHex: 0x2FB170)
                )
            }
            .padding(.vertical, 16)

            // Date + Footer
            VStack(spacing: 4) {
                Text("\(trip.startDate.formatted(date: .abbreviated, time: .omitted)) · \(trip.rawPoints.count.formatted()) GPS points")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(tmHex: 0x8A8A90))
                Divider()
                Text("travelmapping.net")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(tmHex: 0xB4B4BA))
                    .padding(.vertical, 6)
            }
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

@MainActor
func renderTripShareImage(trip: RoadTrip) async -> UIImage? {
    let mapImage = await renderTripMap(trip: trip)
    let card = TripShareCard(
        trip: trip,
        trackImage: mapImage,
        useMiles: SyncedSettingsService.shared.useMiles
    )
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

        context.setStrokeColor(UIColor(red: 0x2F / 255, green: 0x6B / 255, blue: 0xF0 / 255, alpha: 1).cgColor)
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
