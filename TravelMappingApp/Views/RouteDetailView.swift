import SwiftUI
import MapKit
import Sentry
import SentrySwiftUI

struct RouteDetailView: View {
    let roots: [String]
    let listName: String
    let username: String
    var isRail: Bool = false

    /// Convenience init for single-root (backward compatible)
    init(root: String, listName: String, username: String, isRail: Bool = false) {
        self.roots = [root]
        self.listName = listName
        self.username = username
        self.isRail = isRail
    }

    init(roots: [String], listName: String, username: String, isRail: Bool = false) {
        self.roots = roots
        self.listName = listName
        self.username = username
        self.isRail = isRail
    }

    @State private var routeDetail: TravelMappingAPI.RouteDetail?
    @State private var allRegionDetails: [TravelMappingAPI.RouteDetail] = []
    @State private var regionBreakdown: [RegionBreakdown] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var mapPosition: MapCameraPosition = .automatic
    @ObservedObject private var settings = SyncedSettingsService.shared

    struct RegionBreakdown: Identifiable {
        let id: String // listName
        let listName: String
        let clinchedMileage: Double
        let totalMileage: Double
        let clinchedSegments: Int
        let totalSegments: Int
        var percentage: Double { totalMileage > 0 ? clinchedMileage / totalMileage * 100 : 0 }
    }

    private var unit: String { settings.useMiles ? "mi" : "km" }
    private func convert(_ miles: Double) -> Double { settings.useMiles ? miles : miles * 1.60934 }

    var body: some View {
        SentryTracedView("RouteDetailView", waitForFullDisplay: true) {
            Group {
                if isLoading {
                    ProgressView("Loading route...")
                } else if let error = errorMessage {
                    ErrorView(message: error) { await load() }
                } else if let detail = routeDetail {
                    loadedContent(detail: detail)
                } else {
                    ErrorView(message: "No route data returned for \(listName). The server may be temporarily unavailable.") { await load() }
                }
            }
            .navigationTitle(listName)
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .refreshable { await load() }
        }
    }

    @ViewBuilder
    private func loadedContent(detail: TravelMappingAPI.RouteDetail) -> some View {
        VStack(spacing: 0) {
            mapView(detail: detail)
                .frame(maxHeight: .infinity)

            statsBar(detail: detail)

            if regionBreakdown.count > 1 {
                regionBreakdownView
            }
        }
    }

    private struct MergedDetailPolyline: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let clinched: Bool
    }

    private var mergedPolylines: [MergedDetailPolyline] {
        // Coalesce consecutive same-clinched segments whose endpoints align into a single polyline
        // to avoid thousands of MapPolyline objects — the main-thread Metal teardown of those
        // caused 7s+ app hangs on iPad.
        let segments: [(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D, clinched: Bool)]
        if !allRegionDetails.isEmpty {
            segments = allRegionDetails.flatMap(\.segments)
        } else {
            segments = routeDetail?.segments ?? []
        }

        var result: [MergedDetailPolyline] = []
        var coords: [CLLocationCoordinate2D] = []
        var currentClinched: Bool? = nil
        var nextID = 0

        func flush() {
            guard coords.count >= 2, let clinched = currentClinched else { return }
            result.append(MergedDetailPolyline(id: nextID, coordinates: coords, clinched: clinched))
            nextID += 1
        }

        for seg in segments {
            if currentClinched == seg.clinched,
               let last = coords.last,
               abs(last.latitude - seg.start.latitude) < 1e-6,
               abs(last.longitude - seg.start.longitude) < 1e-6 {
                coords.append(seg.end)
            } else {
                flush()
                coords = [seg.start, seg.end]
                currentClinched = seg.clinched
            }
        }
        flush()
        return result
    }

    private func mapView(detail: TravelMappingAPI.RouteDetail) -> some View {
        Map(position: $mapPosition) {
            // Draw merged polylines colored by clinched status
            ForEach(mergedPolylines) { poly in
                MapPolyline(coordinates: poly.coordinates)
                    .stroke(
                        poly.clinched ? Color.blue : Color.gray.opacity(0.7),
                        style: StrokeStyle(
                            lineWidth: poly.clinched ? 4 : 2,
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

    private var regionBreakdownView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By Region")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            ForEach(regionBreakdown) { region in
                HStack(spacing: 8) {
                    Text(region.listName)
                        .font(.caption.bold())
                        .frame(width: 80, alignment: .leading)

                    ProgressView(value: region.clinchedMileage, total: max(region.totalMileage, 1))
                        .tint(region.percentage >= 100 ? .green : .blue)

                    Text(String(format: "%.1f / %.1f %@", convert(region.clinchedMileage), convert(region.totalMileage), unit))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
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
        regionBreakdown = []
        allRegionDetails = []
        do {
            let api = isRail ? TravelMappingAPI.rail : TravelMappingAPI.shared
            let details = try await api.getRouteData(
                roots: roots,
                traveler: username
            )
            if details.count > 1 {
                // Build per-region breakdown
                regionBreakdown = details.map { detail in
                    let segs = detail.segments
                    let clinchedSegs = segs.filter(\.clinched)
                    return RegionBreakdown(
                        id: detail.listName,
                        listName: detail.listName,
                        clinchedMileage: detail.clinchedMileage,
                        totalMileage: detail.totalMileage,
                        clinchedSegments: clinchedSegs.count,
                        totalSegments: segs.count
                    )
                }.sorted { $0.listName < $1.listName }

                // Store individual region details for proper map rendering (no cross-region lines)
                allRegionDetails = details

                // Also create a combined detail for aggregate stats bar
                var allCoords: [CLLocationCoordinate2D] = []
                var allClinched: [Bool] = []
                for detail in details {
                    allCoords.append(contentsOf: detail.coordinates)
                    allClinched.append(contentsOf: detail.clinched)
                }
                routeDetail = TravelMappingAPI.RouteDetail(
                    id: listName,
                    listName: listName,
                    coordinates: allCoords,
                    clinched: allClinched
                )
            } else {
                routeDetail = details.first
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        SentrySDK.reportFullyDisplayed()
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
