import SwiftUI
import MapKit

struct RouteDetailView: View {
    let root: String
    let listName: String
    let username: String
    var isRail: Bool = false

    @State private var routeDetail: TravelMappingAPI.RouteDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var mapPosition: MapCameraPosition = .automatic
    @ObservedObject private var settings = SyncedSettingsService.shared

    private var unit: String { settings.useMiles ? "mi" : "km" }
    private func convert(_ miles: Double) -> Double { settings.useMiles ? miles : miles * 1.60934 }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading route...")
            } else if let error = errorMessage {
                ErrorView(message: error) { await load() }
            } else if let detail = routeDetail {
                loadedContent(detail: detail)
            }
        }
        .navigationTitle(listName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func loadedContent(detail: TravelMappingAPI.RouteDetail) -> some View {
        VStack(spacing: 0) {
            mapView(detail: detail)
                .frame(maxHeight: .infinity)

            statsBar(detail: detail)
        }
    }

    private func mapView(detail: TravelMappingAPI.RouteDetail) -> some View {
        Map(position: $mapPosition) {
            // Draw segments colored by clinched status
            ForEach(Array(detail.segments.enumerated()), id: \.offset) { index, segment in
                MapPolyline(coordinates: [segment.start, segment.end])
                    .stroke(
                        segment.clinched ? Color.blue : Color.gray.opacity(0.7),
                        style: StrokeStyle(
                            lineWidth: segment.clinched ? 4 : 2,
                            lineCap: .round
                        )
                    )
            }

            // Start and end markers
            if let first = detail.coordinates.first {
                Marker("Start", coordinate: first).tint(.green)
            }
            if let last = detail.coordinates.last {
                Marker("End", coordinate: last).tint(.red)
            }
        }
        .mapStyle(.standard)
        .onAppear {
            zoomToRoute(detail: detail)
        }
    }

    private func statsBar(detail: TravelMappingAPI.RouteDetail) -> some View {
        let total = detail.totalMileage
        let clinched = detail.clinchedMileage
        let pct = total > 0 ? clinched / total * 100 : 0

        return VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1f / %.1f %@", convert(clinched), convert(total), unit))
                        .font(.headline.bold())
                        .monospacedDigit()
                    Text(String(format: "%.1f%% clinched", pct))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(detail.segments.filter(\.clinched).count) / \(detail.segments.count)")
                        .font(.headline.bold())
                        .monospacedDigit()
                    Text("segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: clinched, total: max(total, 1))
                .tint(pct >= 100 ? .green : .blue)

            // Legend
            HStack(spacing: 16) {
                legendItem(color: .blue, label: "Traveled")
                legendItem(color: .gray.opacity(0.7), label: "Remaining")
                Spacer()
            }
            .font(.caption2)
            .padding(.top, 4)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 16, height: 3)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func zoomToRoute(detail: TravelMappingAPI.RouteDetail) {
        guard !detail.coordinates.isEmpty else { return }
        let lats = detail.coordinates.map(\.latitude)
        let lngs = detail.coordinates.map(\.longitude)
        let centerLat = (lats.min()! + lats.max()!) / 2
        let centerLng = (lngs.min()! + lngs.max()!) / 2
        let spanLat = max((lats.max()! - lats.min()!) * 1.3, 0.05)
        let spanLng = max((lngs.max()! - lngs.min()!) * 1.3, 0.05)

        withAnimation {
            mapPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLng)
            ))
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let api = isRail ? TravelMappingAPI.rail : TravelMappingAPI.shared
            let details = try await api.getRouteData(
                roots: [root],
                traveler: username
            )
            routeDetail = details.first
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// Helper extensions for RouteDetail
extension TravelMappingAPI.RouteDetail {
    var segments: [(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D, clinched: Bool)] {
        guard coordinates.count >= 2 else { return [] }
        var segs: [(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D, clinched: Bool)] = []
        for i in 0..<(coordinates.count - 1) {
            let isClinched = i < clinched.count ? clinched[i] : false
            segs.append((start: coordinates[i], end: coordinates[i+1], clinched: isClinched))
        }
        return segs
    }

    var clinchedMileage: Double {
        // Approximate clinched miles by counting clinched segments proportionally
        let clinchedCount = clinched.filter { $0 }.count
        let totalCount = clinched.count
        guard totalCount > 0 else { return 0 }
        return totalMileage * Double(clinchedCount) / Double(totalCount)
    }

    var totalMileage: Double {
        // Sum Haversine distances between consecutive coordinates
        guard coordinates.count >= 2 else { return 0 }
        var total: Double = 0
        for i in 0..<(coordinates.count - 1) {
            let a = coordinates[i]
            let b = coordinates[i+1]
            let aLoc = CLLocation(latitude: a.latitude, longitude: a.longitude)
            let bLoc = CLLocation(latitude: b.latitude, longitude: b.longitude)
            total += aLoc.distance(from: bLoc) / 1609.34 // meters → miles
        }
        return total
    }
}
