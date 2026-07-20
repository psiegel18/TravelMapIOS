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

    /// One entry per region — each keeps its own coordinate/clinched arrays so
    /// segment and mileage computation never spans region boundaries.
    @State private var allRegionDetails: [TravelMappingAPI.RouteDetail] = []
    @State private var regionBreakdown: [RegionBreakdown] = []
    /// Computed once per detail-load (off the main thread) — body renders read
    /// these cached values instead of recomputing on every map pan.
    @State private var mergedPolylines: [MergedDetailPolyline] = []
    @State private var routeStats = RouteStats()
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var mapPosition: MapCameraPosition = .automatic
    @ObservedObject private var settings = SyncedSettingsService.shared

    struct RouteStats {
        var totalMileage: Double = 0
        var clinchedMileage: Double = 0
        var totalSegments: Int = 0
        var clinchedSegments: Int = 0
    }

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
                } else if !allRegionDetails.isEmpty {
                    loadedContent
                } else {
                    ErrorView(message: "No route data returned for \(listName). The server may be temporarily unavailable.") { await load() }
                }
            }
            .navigationTitle(listName)
            .navigationBarTitleDisplayMode(.inline)
            .sentryScreen("RouteDetail")
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private var loadedContent: some View {
        VStack(spacing: 0) {
            mapView
                .frame(maxHeight: .infinity)

            statsBar

            if regionBreakdown.count > 1 {
                regionBreakdownView
            }
        }
    }

    struct MergedDetailPolyline: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let clinched: Bool
    }

    /// Coalesce consecutive same-clinched segments whose endpoints align into a single
    /// polyline to avoid thousands of MapPolyline objects — the main-thread Metal
    /// teardown of those caused 7s+ app hangs on iPad. Each region's detail keeps its
    /// own arrays; merging and mileage never span a region boundary. Also accumulates
    /// the stats-bar totals in the same pass, using an equirectangular approximation
    /// instead of allocating CLLocation pairs per coordinate.
    nonisolated static func computeRenderData(
        for details: [TravelMappingAPI.RouteDetail]
    ) -> (polylines: [MergedDetailPolyline], stats: RouteStats, breakdown: [RegionBreakdown]) {
        var result: [MergedDetailPolyline] = []
        var stats = RouteStats()
        var breakdown: [RegionBreakdown] = []
        var nextID = 0

        for detail in details {
            var coords: [CLLocationCoordinate2D] = []
            var currentClinched: Bool? = nil
            var regionTotal = 0.0
            var regionClinched = 0.0
            var regionClinchedSegs = 0

            func flush() {
                guard coords.count >= 2, let clinched = currentClinched else { return }
                result.append(MergedDetailPolyline(id: nextID, coordinates: coords, clinched: clinched))
                nextID += 1
            }

            let segments = detail.segments
            for seg in segments {
                let miles = approxMiles(seg.start, seg.end)
                regionTotal += miles
                if seg.clinched {
                    regionClinched += miles
                    regionClinchedSegs += 1
                }

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
            flush() // hard break at the region boundary — never merge across regions

            stats.totalMileage += regionTotal
            stats.clinchedMileage += regionClinched
            stats.totalSegments += segments.count
            stats.clinchedSegments += regionClinchedSegs
            breakdown.append(RegionBreakdown(
                id: detail.listName,
                listName: detail.listName,
                clinchedMileage: regionClinched,
                totalMileage: regionTotal,
                clinchedSegments: regionClinchedSegs,
                totalSegments: segments.count
            ))
        }

        breakdown.sort { $0.listName < $1.listName }
        return (result, stats, breakdown)
    }

    /// Equirectangular distance approximation in miles — avoids per-pair CLLocation allocation.
    nonisolated private static func approxMiles(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = (a.latitude - b.latitude) * 111_320
        let dLng = (a.longitude - b.longitude) * 111_320 * cos(((a.latitude + b.latitude) / 2) * .pi / 180)
        return sqrt(dLat * dLat + dLng * dLng) / 1609.34
    }

    private var mapView: some View {
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
            if let first = allRegionDetails.first?.coordinates.first {
                Marker("Start", coordinate: first).tint(.green)
            }
            if let last = allRegionDetails.last?.coordinates.last {
                Marker("End", coordinate: last).tint(.red)
            }
        }
        .mapStyle(.standard)
        .onAppear {
            zoomToRoute()
        }
    }

    private var statsBar: some View {
        let total = routeStats.totalMileage
        let clinched = routeStats.clinchedMileage
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
                    Text("\(routeStats.clinchedSegments.formatted()) / \(routeStats.totalSegments.formatted())")
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

    private func zoomToRoute() {
        let allCoordinates = allRegionDetails.flatMap(\.coordinates)
        guard !allCoordinates.isEmpty else { return }
        let lats = allCoordinates.map(\.latitude)
        let lngs = allCoordinates.map(\.longitude)
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
                roots: roots,
                traveler: username
            )

            // Each region's detail keeps its own coordinate/clinched arrays —
            // never concatenated, so no phantom cross-boundary segments and no
            // clinched-flag shift. Polylines + stats computed once per load,
            // off the main thread.
            let computed = await Task.detached(priority: .userInitiated) {
                Self.computeRenderData(for: details)
            }.value

            allRegionDetails = details
            mergedPolylines = computed.polylines
            routeStats = computed.stats
            regionBreakdown = details.count > 1 ? computed.breakdown : []
        } catch {
            errorMessage = error.localizedDescription
            allRegionDetails = []
            mergedPolylines = []
            routeStats = RouteStats()
            regionBreakdown = []
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
