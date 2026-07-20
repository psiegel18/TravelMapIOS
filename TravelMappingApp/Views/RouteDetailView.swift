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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerView
                mapView
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                statusCard
                if regionBreakdown.count > 1 {
                    byRegionCard
                }
            }
            .padding()
        }
    }

    // MARK: Header — 30pt/800 title + region count (audit §7)

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(listName)
                .font(.system(size: 30, weight: .heavy))
                .lineLimit(2)
            Text(headerSubtitle)
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(TMDesign.tertiaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private var headerSubtitle: String {
        if allRegionDetails.count > 1 {
            return "Crosses \(allRegionDetails.count.formatted()) regions"
        }
        // Single region: show the full region name when the catalog knows it.
        if let code = allRegionDetails.first.map({ Self.regionCode(from: $0.listName) }),
           let name = GetStartedView.regionName(for: code) {
            return name
        }
        return "1 region"
    }

    /// "IL I-90" → "IL". List names lead with the region code.
    nonisolated static func regionCode(from listName: String) -> String {
        String(listName.prefix(while: { $0 != " " }))
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
                        poly.clinched ? Color.blue : TMDesign.frontier.opacity(0.85),
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

    // MARK: Status card — clinched mileage + segmented per-region bar (audit §7)

    private var isFullyClinched: Bool {
        routeStats.totalMileage > 0 &&
            routeStats.clinchedMileage >= routeStats.totalMileage - 0.001
    }

    private var statusCard: some View {
        let total = routeStats.totalMileage
        let clinched = routeStats.clinchedMileage
        let pct = total > 0 ? clinched / total * 100 : 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: isFullyClinched ? "checkmark.seal.fill" : "checkmark.seal")
                    .font(.system(size: 16, weight: .bold))
                    .accessibilityHidden(true)
                Text(isFullyClinched
                     ? "Fully clinched · \(String(format: "%.1f", convert(total))) \(unit)"
                     : "\(String(format: "%.1f", convert(clinched))) of \(String(format: "%.1f", convert(total))) \(unit) · \(Int(pct.rounded()))% clinched")
                    .font(.system(size: 16, weight: .heavy))
                    .monospacedDigit()
            }
            .foregroundStyle(isFullyClinched ? TMDesign.clinched : TMDesign.accent)

            segmentedProgressBar

            HStack {
                Text("\(routeStats.clinchedSegments.formatted()) of \(routeStats.totalSegments.formatted()) segments")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(TMDesign.tertiaryText)
                Spacer()
                legendItem(color: .blue, label: "Traveled")
                legendItem(color: TMDesign.frontier.opacity(0.85), label: "Remaining")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// One segment per region, width proportional to that region's mileage, each
    /// green-filled to the region's own clinched fraction (1px gaps between regions).
    /// Interpretation: the audit mock shows solid green per-region segments for a
    /// fully clinched route; partially clinched regions render a partial green fill
    /// over the neutral track so the bar stays honest for in-progress routes.
    private var segmentedProgressBar: some View {
        let segments: [(weight: Double, fraction: Double)] = regionBreakdown.count > 1
            ? regionBreakdown.map { (
                weight: $0.totalMileage,
                fraction: $0.totalMileage > 0 ? $0.clinchedMileage / $0.totalMileage : 0
            ) }
            : [(
                weight: 1,
                fraction: routeStats.totalMileage > 0
                    ? routeStats.clinchedMileage / routeStats.totalMileage : 0
            )]
        let totalWeight = max(segments.reduce(0) { $0 + $1.weight }, 0.000001)

        return GeometryReader { geo in
            let gapTotal = CGFloat(segments.count - 1) * 1
            let available = max(geo.size.width - gapTotal, 0)
            HStack(spacing: 1) {
                ForEach(segments.indices, id: \.self) { i in
                    let seg = segments[i]
                    let width = available * CGFloat(seg.weight / totalWeight)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(TMDesign.progressTrack)
                        Rectangle()
                            .fill(TMDesign.clinched)
                            .frame(width: width * CGFloat(min(max(seg.fraction, 0), 1)))
                    }
                    .frame(width: width)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 16, height: 3)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(TMDesign.secondaryText)
        }
    }

    // MARK: "By region" rows (audit §7)

    private var byRegionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TMDesign.sectionHeader("By region")
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)

            ForEach(Array(regionBreakdown.enumerated()), id: \.element.id) { index, region in
                byRegionRow(region)
                if index < regionBreakdown.count - 1 {
                    Rectangle().fill(TMDesign.hairline).frame(height: 1)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func byRegionRow(_ region: RegionBreakdown) -> some View {
        let code = Self.regionCode(from: region.listName)
        let name = GetStartedView.regionName(for: code) ?? code
        let pct = Int(region.percentage.rounded())

        return HStack(spacing: 12) {
            Text(code)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(TMDesign.blueChipFG)
                .frame(width: 34, height: 34)
                .background(TMDesign.blueChipBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                Text("\(region.clinchedSegments.formatted()) of \(region.totalSegments.formatted()) segments")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(TMDesign.tertiaryText)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(String(format: "%.1f", convert(region.totalMileage))) \(unit)")
                    .font(.system(size: 15, weight: .heavy))
                    .monospacedDigit()
                Text("\(pct)%")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(pct >= 100 ? TMDesign.clinched : TMDesign.frontier)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(pct) percent clinched, \(String(format: "%.1f", convert(region.totalMileage))) \(unit), \(region.clinchedSegments.formatted()) of \(region.totalSegments.formatted()) segments")
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
