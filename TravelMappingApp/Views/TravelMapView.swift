import Sentry
import SentrySwiftUI
import SwiftUI
import MapKit
import CoreLocation

struct TravelMapView: View {
    let username: String
    let dataService: DataService
    @Binding var loadedRegionsBinding: Set<String>
    var isActiveTab: Bool = true
    @State private var segments: [TravelMappingAPI.MapSegment] = []
    @State private var routeMetadata: [TravelMappingAPI.RouteMetadata] = []
    @State private var isLoading = true
    @State private var loadingProgress: String?
    @State private var errorMessage: String?
    @State private var showClinched = true
    @State private var showUnclinched = false
    @State private var showRail = true
    @State private var railSegments: [TravelMappingAPI.MapSegment] = []
    @State private var railMetadata: [TravelMappingAPI.RouteMetadata] = []
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedRegions: Set<String> = []
    @State private var pendingRegions: Set<String> = [] // Editable copy for picker
    @State private var availableRegions: [String] = []
    @State private var allRegionsByCountry: [(country: String, regions: [String])] = []
    @State private var regionCountryMap: [String: String] = [:]
    @State private var showRegionPicker = false
    @ObservedObject private var settings = SyncedSettingsService.shared
    @State private var mapStyle: MapStyleOption = .standard
    @State private var currentSpanLat: Double = 5.0
    @State private var currentSpanLng: Double = 5.0
    @State private var visibleRegion: MKCoordinateRegion?
    @StateObject private var locationManager = LocationManager()
    @State private var showLegend = false
    @State private var zoomToUserOnNextFix = false
    @State private var isSelectMode = false
    @State private var selectedSegmentIDs: Set<Int> = []
    @State private var showSelectionDetail = false
    @State private var routeSearchText = ""
    @State private var tappedSegmentDetail: SegmentDetail?

    struct SegmentDetail: Identifiable {
        let id = UUID()
        let root: String
        let listName: String
        let startName: String
        let endName: String
        let isClinched: Bool
        let isRail: Bool
    }

    enum MapStyleOption: String, CaseIterable {
        case standard = "Standard"
        case satellite = "Satellite"
        case hybrid = "Hybrid"
        case hybrid3D = "3D Hybrid"

        var style: MapStyle {
            switch self {
            case .standard: return .standard
            case .satellite: return .imagery
            case .hybrid: return .hybrid
            case .hybrid3D: return .hybrid(elevation: .realistic)
            }
        }

        var icon: String {
            switch self {
            case .standard: return "map"
            case .satellite: return "globe.americas"
            case .hybrid: return "square.stack.3d.up"
            case .hybrid3D: return "mountain.2"
            }
        }
    }

    /// A merged polyline from consecutive segments on the same route.
    private struct MergedPolyline: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let isClinched: Bool
        let root: String
    }

    @State private var mergedPolylines: [MergedPolyline] = []
    @State private var mergedRailPolylines: [MergedPolyline] = []

    private var displayedPolylines: [MergedPolyline] {
        mergedPolylines.filter { poly in
            if showClinched && poly.isClinched { return true }
            if showUnclinched && !poly.isClinched { return true }
            return false
        }
    }

    private var displayedRailPolylines: [MergedPolyline] {
        guard showRail else { return [] }
        return mergedRailPolylines.filter { poly in
            if showClinched && poly.isClinched { return true }
            if showUnclinched && !poly.isClinched { return true }
            return false
        }
    }

    private var clinchedCount: Int { segments.filter(\.isClinched).count + railSegments.filter(\.isClinched).count }
    private var totalCount: Int { segments.count + railSegments.count }

    /// Merge consecutive 2-point segments on the same route into multi-point polylines.
    /// Runs the expensive sort/merge on a background thread to avoid main-thread hangs.
    private func rebuildPolylines() {
        let roadSegs = segments
        let railSegs = railSegments
        let maxCoords = maxPolylineCoords

        Task.detached(priority: .userInitiated) {
            let roads = Self.buildMergedPolylines(from: roadSegs, startID: 0, maxCoords: maxCoords)
            let rails = Self.buildMergedPolylines(from: railSegs, startID: 500_000, maxCoords: maxCoords)
            await MainActor.run {
                mergedPolylines = roads
                mergedRailPolylines = rails
            }
        }
    }

    nonisolated private static func buildMergedPolylines(
        from segs: [TravelMappingAPI.MapSegment],
        startID: Int,
        maxCoords: Int
    ) -> [MergedPolyline] {
        let filtered = segs.sorted { $0.root < $1.root || ($0.root == $1.root && $0.id < $1.id) }
        var result: [MergedPolyline] = []
        var currentCoords: [CLLocationCoordinate2D] = []
        var currentRoot = ""
        var currentClinched = false
        var polyID = startID

        for seg in filtered {
            let sameLine = seg.root == currentRoot && seg.isClinched == currentClinched

            if sameLine, let last = currentCoords.last,
               coordDistance(last, seg.start) < 500 {
                currentCoords.append(seg.end)
                if currentCoords.count >= maxCoords {
                    result.append(MergedPolyline(id: polyID, coordinates: currentCoords, isClinched: currentClinched, root: currentRoot))
                    polyID += 1
                    currentCoords = [seg.end]
                }
            } else {
                if currentCoords.count >= 2 {
                    result.append(MergedPolyline(id: polyID, coordinates: currentCoords, isClinched: currentClinched, root: currentRoot))
                    polyID += 1
                }
                currentCoords = [seg.start, seg.end]
                currentRoot = seg.root
                currentClinched = seg.isClinched
            }
        }
        if currentCoords.count >= 2 {
            result.append(MergedPolyline(id: polyID, coordinates: currentCoords, isClinched: currentClinched, root: currentRoot))
        }
        return result
    }

    /// Static version of distance for use in static methods
    nonisolated private static func coordDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = (a.latitude - b.latitude) * 111_320
        let dLng = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return sqrt(dLat * dLat + dLng * dLng)
    }

    /// Max coordinates per polyline — keeps MapKit dash rendering consistent on long routes.
    /// MapKit stops rendering dash patterns on geographically long polylines,
    /// so we keep this low to ensure dashes stay visible.
    private let maxPolylineCoords = 15

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = (a.latitude - b.latitude) * 111_320
        let dLng = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return sqrt(dLat * dLat + dLng * dLng)
    }

    var body: some View {
        SentryTracedView("TravelMapView", waitForFullDisplay: true) {
            bodyContent
        }
    }

    private var bodyContent: some View {
        ZStack(alignment: .bottom) {
            mapLayer

            // Right-side controls — padded below compass/nav bar to avoid overlap
            VStack {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        zoomControls
                        mapStyleButton
                        locationButton
                        selectModeButton
                        legendButton
                    }
                    .padding(.trailing, 12)
                    .padding(.top, 70)
                }
                Spacer()
            }

            // Legend overlay
            if showLegend {
                VStack {
                    Spacer()
                    HStack {
                        mapLegend
                            .padding(.leading, 12)
                            .padding(.bottom, 80)
                        Spacer()
                    }
                }
            }

            VStack(spacing: 8) {
                if isLoading {
                    loadingIndicator
                }

                // Selection bar
                if isSelectMode && !selectedSegmentIDs.isEmpty {
                    selectionBar
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Error: \(error)")
                }

                controlBar
                    .padding(.bottom, 8)
            }
        }
        .navigationTitle("\(username)'s Map")
        .navigationBarTitleDisplayMode(.inline)
        .if(isActiveTab) { view in
            view.searchable(text: $routeSearchText, prompt: "Search routes (e.g. I-95)")
        }
        .onChange(of: routeSearchText) {
            if !routeSearchText.isEmpty {
                zoomToRoute(routeSearchText)
            }
        }
        .sheet(item: $tappedSegmentDetail) { detail in
            SegmentDetailSheet(
                detail: detail,
                username: username,
                onSelectAll: { root in
                    isSelectMode = true
                    let ids = segments.filter { $0.root == root }.map(\.id)
                    selectedSegmentIDs.formUnion(ids)
                    Haptics.success()
                    tappedSegmentDetail = nil
                },
                onSelectClinched: { root in
                    isSelectMode = true
                    let ids = segments.filter { $0.root == root && $0.isClinched }.map(\.id)
                    selectedSegmentIDs.formUnion(ids)
                    Haptics.success()
                    tappedSegmentDetail = nil
                }
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showRegionPicker, onDismiss: {
            // Commit pending selection when sheet closes
            if pendingRegions != selectedRegions {
                selectedRegions = pendingRegions
            }
        }) {
            regionPickerSheet
        }
        .onChange(of: showRegionPicker) {
            if showRegionPicker {
                pendingRegions = selectedRegions
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                regionPicker
            }
        }
        .task {
            await loadRegions()
        }
        .onChange(of: selectedRegions) {
            Task { await loadSegments() }
        }
        .onChange(of: locationManager.lastLocation?.timestamp) {
            if zoomToUserOnNextFix, let loc = locationManager.lastLocation {
                zoomToUserOnNextFix = false
                zoomToLocation(loc)
            }
        }
    }

    // MARK: - Map

    /// Selected segments as merged polylines for rendering
    private var selectedPolylines: [MergedPolyline] {
        let selectedSegs = segments.filter { selectedSegmentIDs.contains($0.id) }
        guard !selectedSegs.isEmpty else { return [] }

        // Simple merge for selected segments
        var result: [MergedPolyline] = []
        var coords: [CLLocationCoordinate2D] = []
        var currentRoot = ""
        var polyID = 100_000

        for seg in selectedSegs.sorted(by: { $0.root < $1.root || ($0.root == $1.root && $0.id < $1.id) }) {
            if seg.root == currentRoot, let last = coords.last, distance(last, seg.start) < 500 {
                coords.append(seg.end)
            } else {
                if coords.count >= 2 {
                    result.append(MergedPolyline(id: polyID, coordinates: coords, isClinched: true, root: currentRoot))
                    polyID += 1
                }
                coords = [seg.start, seg.end]
                currentRoot = seg.root
            }
        }
        if coords.count >= 2 {
            result.append(MergedPolyline(id: polyID, coordinates: coords, isClinched: true, root: currentRoot))
        }
        return result
    }

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $mapPosition) {
                UserAnnotation()

                // Road segments
                ForEach(displayedPolylines) { poly in
                    MapPolyline(coordinates: poly.coordinates)
                        .stroke(
                            poly.isClinched ? colorForRoot(poly.root) : .gray.opacity(0.7),
                            style: MapStyleService.strokeStyle(
                                for: MapStyleService.parse(settings.roadLineStyle),
                                baseWidth: poly.isClinched ? settings.roadLineWidth : 1.5
                            )
                        )
                }

                // Rail segments — use double-line "railroad" style since
                // MapKit doesn't reliably render StrokeStyle dash patterns on MapPolyline.
                // Outer stroke (wider, colored)
                ForEach(displayedRailPolylines) { poly in
                    let width = poly.isClinched ? settings.railLineWidth : 2.0
                    MapPolyline(coordinates: poly.coordinates)
                        .stroke(
                            poly.isClinched ? .red : .gray.opacity(0.6),
                            lineWidth: width
                        )
                }
                // Inner stroke (thinner, white) creates the "track" look
                ForEach(displayedRailPolylines) { poly in
                    let width = poly.isClinched ? settings.railLineWidth : 2.0
                    if width > 2 {
                        MapPolyline(coordinates: poly.coordinates)
                            .stroke(.white.opacity(0.5), lineWidth: width * 0.4)
                    }
                }

                // Selected segments: white outline for contrast on any background
                ForEach(selectedPolylines) { poly in
                    MapPolyline(coordinates: poly.coordinates)
                        .stroke(.white, lineWidth: 9)
                }
                // Selected segments: yellow highlight on top
                ForEach(selectedPolylines) { poly in
                    MapPolyline(coordinates: poly.coordinates)
                        .stroke(.yellow, lineWidth: 7)
                }
            }
            .mapStyle(mapStyle.style)
            .onMapCameraChange { context in
                visibleRegion = context.region
            }
            .mapControls {
                // Only show compass and scale — suppress all other default controls
                // (pitch toggle, user location button, etc.) since we have custom versions
                MapCompass()
                MapScaleView()
            }
            .mapControlVisibility(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onTapGesture { screenPoint in
                if let coordinate = proxy.convert(screenPoint, from: .local) {
                    handleSegmentTap(at: coordinate)
                }
            }
        }
    }

    private func handleSegmentTap(at coordinate: CLLocationCoordinate2D) {
        // Pre-filter to segments within the visible map region to avoid iterating all segments
        let region = visibleRegion ?? MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
        )
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLng = region.center.longitude - region.span.longitudeDelta / 2
        let maxLng = region.center.longitude + region.span.longitudeDelta / 2

        func inBounds(_ seg: TravelMappingAPI.MapSegment) -> Bool {
            (seg.start.latitude >= minLat && seg.start.latitude <= maxLat &&
             seg.start.longitude >= minLng && seg.start.longitude <= maxLng) ||
            (seg.end.latitude >= minLat && seg.end.latitude <= maxLat &&
             seg.end.longitude >= minLng && seg.end.longitude <= maxLng)
        }

        var visibleSegs: [TravelMappingAPI.MapSegment] = []
        for seg in segments where inBounds(seg) {
            if showClinched && seg.isClinched { visibleSegs.append(seg) }
            else if showUnclinched && !seg.isClinched { visibleSegs.append(seg) }
        }
        if showRail {
            for seg in railSegments where inBounds(seg) {
                if showClinched && seg.isClinched { visibleSegs.append(seg) }
                else if showUnclinched && !seg.isClinched { visibleSegs.append(seg) }
            }
        }

        // Find nearest visible segment within 200m
        var bestSeg: TravelMappingAPI.MapSegment?
        var bestDist: Double = .greatestFiniteMagnitude

        for seg in visibleSegs {
            let dist = distanceToSegment(point: coordinate, start: seg.start, end: seg.end)
            if dist < bestDist {
                bestDist = dist
                bestSeg = seg
            }
        }

        guard let seg = bestSeg, bestDist < 200 else { return }

        if isSelectMode {
            if selectedSegmentIDs.contains(seg.id) {
                selectedSegmentIDs.remove(seg.id)
                Haptics.light()
            } else {
                selectedSegmentIDs.insert(seg.id)
                Haptics.selection()
            }
        } else {
            // Show segment detail — check both road and rail metadata
            let isRail = railMetadata.contains(where: { $0.root == seg.root })
            let listName = routeMetadata.first(where: { $0.root == seg.root })?.listName
                ?? railMetadata.first(where: { $0.root == seg.root })?.listName
                ?? seg.root
            Haptics.light()
            tappedSegmentDetail = SegmentDetail(
                root: seg.root,
                listName: listName,
                startName: seg.startName,
                endName: seg.endName,
                isClinched: seg.isClinched,
                isRail: isRail
            )
        }
    }

    private func distanceToSegment(point: CLLocationCoordinate2D, start: CLLocationCoordinate2D, end: CLLocationCoordinate2D) -> Double {
        let cosLat = cos(point.latitude * .pi / 180)
        let px = (point.longitude - start.longitude) * cosLat
        let py = point.latitude - start.latitude
        let dx = (end.longitude - start.longitude) * cosLat
        let dy = end.latitude - start.latitude
        let segLenSq = dx * dx + dy * dy
        guard segLenSq > 0 else {
            return sqrt(px * px + py * py) * 111_320
        }
        let t = max(0, min(1, (px * dx + py * dy) / segLenSq))
        let closestX = start.longitude * cosLat + t * dx
        let closestY = start.latitude + t * dy
        let distX = point.longitude * cosLat - closestX
        let distY = point.latitude - closestY
        return sqrt(distX * distX + distY * distY) * 111_320
    }

    // MARK: - Right Side Controls

    private var zoomControls: some View {
        VStack(spacing: 0) {
            Button {
                Haptics.light()
                zoomIn()
            } label: {
                Image(systemName: "plus")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Zoom in")

            Divider()
                .frame(width: 44)

            Button {
                Haptics.light()
                zoomOut()
            } label: {
                Image(systemName: "minus")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Zoom out")
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .buttonStyle(.plain)
    }

    private var mapStyleButton: some View {
        Menu {
            ForEach(MapStyleOption.allCases, id: \.self) { option in
                Button {
                    Haptics.light()
                    mapStyle = option
                } label: {
                    Label(option.rawValue, systemImage: option.icon)
                }
            }
        } label: {
            Image(systemName: mapStyle.icon)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map style: \(mapStyle.rawValue)")
        .accessibilityHint("Double tap to change map style")
    }

    private var locationButton: some View {
        Button {
            Haptics.light()
            if let loc = locationManager.lastLocation {
                // Already have a location, zoom to it
                zoomToLocation(loc)
            } else {
                // Request and zoom when it arrives
                zoomToUserOnNextFix = true
                locationManager.requestLocation()
            }
        } label: {
            Image(systemName: locationManager.lastLocation != nil ? "location.fill" : "location")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show my location")
    }

    private func zoomToLocation(_ loc: CLLocation) {
        withAnimation {
            mapPosition = .region(MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            ))
        }
    }

    private var legendButton: some View {
        Button {
            Haptics.selection()
            withAnimation { showLegend.toggle() }
        } label: {
            Image(systemName: showLegend ? "info.circle.fill" : "info.circle")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showLegend ? "Hide legend" : "Show legend")
    }

    private var mapLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Legend").font(.caption.bold())
            Divider()
            legendRow(color: .blue, style: MapStyleService.parse(settings.roadLineStyle), label: "Traveled road")
            legendRow(color: .gray.opacity(0.5), style: .solid, label: "Remaining road")
            railLegendRow(label: "Traveled rail")
            legendRow(color: .yellow, style: .thick, label: "Selected")
        }
        .font(.caption2)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func railLegendRow(label: String) -> some View {
        HStack(spacing: 6) {
            Canvas { ctx, size in
                let y = size.height / 2
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(path, with: .color(.red), lineWidth: 3)
                ctx.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 1.2)
            }
            .frame(width: 28, height: 8)
            Text(label)
        }
    }

    private func legendRow(color: Color, style: MapStyleService.LineStyle, label: String) -> some View {
        HStack(spacing: 6) {
            Canvas { ctx, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(path, with: .color(color), style: MapStyleService.strokeStyle(for: style, baseWidth: 2))
            }
            .frame(width: 28, height: 8)
            Text(label)
        }
    }

    private var selectModeButton: some View {
        Button {
            Haptics.selection()
            isSelectMode.toggle()
            if !isSelectMode {
                selectedSegmentIDs.removeAll()
            }
        } label: {
            Image(systemName: isSelectMode ? "pencil.circle.fill" : "pencil.circle")
                .font(.title3)
                .foregroundStyle(isSelectMode ? .yellow : .primary)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelectMode ? "Exit select mode" : "Enter select mode")
        .accessibilityHint("Tap segments on the map to select them for export")
    }

    /// Merged lines for the selection detail panel — consecutive segments on the same route
    /// become a single line (e.g., "IRL E20 11(M7) 6(N7)" instead of 6 separate lines).
    private var selectionLines: [(ids: Set<Int>, text: String)] {
        let selected = segments.filter { selectedSegmentIDs.contains($0.id) }
        let rootToName = Dictionary(routeMetadata.map { ($0.root, $0.listName) }, uniquingKeysWith: { a, _ in a })

        let sorted = selected.sorted { a, b in
            if a.root != b.root { return a.root < b.root }
            return a.id < b.id
        }

        struct MergedLine {
            var ids: Set<Int>
            let root: String
            let listName: String
            var startWP: String
            var endWP: String

            var text: String {
                let parts = listName.split(separator: " ", maxSplits: 1)
                let region = parts.count > 0 ? String(parts[0]) : ""
                let route = parts.count > 1 ? String(parts[1]) : ""
                return "\(region) \(route) \(startWP) \(endWP)"
            }
        }

        var result: [MergedLine] = []
        var current: MergedLine?

        for seg in sorted {
            let listName = rootToName[seg.root] ?? seg.root
            if var cur = current, cur.root == seg.root, cur.endWP == seg.startName {
                cur.endWP = seg.endName
                cur.ids.insert(seg.id)
                current = cur
            } else {
                if let cur = current { result.append(cur) }
                current = MergedLine(ids: [seg.id], root: seg.root, listName: listName, startWP: seg.startName, endWP: seg.endName)
            }
        }
        if let cur = current { result.append(cur) }

        return result.map { (ids: $0.ids, text: $0.text) }
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSelectionDetail.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showSelectionDetail ? "chevron.down" : "chevron.right")
                            .font(.caption2.bold())
                        Text("\(selectedSegmentIDs.count) selected")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    Haptics.success()
                    UIPasteboard.general.string = generateSelectionText()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy .list text to clipboard")

                ShareLink(item: generateSelectionText()) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share .list file")

                Button {
                    Haptics.light()
                    selectedSegmentIDs.removeAll()
                    showSelectionDetail = false
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear selection")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Expandable detail panel
            if showSelectionDetail {
                Divider()
                    .background(.yellow.opacity(0.3))

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(selectionLines, id: \.text) { line in
                            HStack {
                                Text(line.text)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Button {
                                    Haptics.light()
                                    selectedSegmentIDs.subtract(line.ids)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .background(.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.yellow, lineWidth: 1))
        .padding(.horizontal)
    }

    private func generateSelectionText() -> String {
        let selected = segments.filter { selectedSegmentIDs.contains($0.id) }
        return ListFileGenerator.generateFromMapSegments(selected, routeMetadata: routeMetadata)
    }

    /// Normalize a string for flexible route matching by removing hyphens,
    /// dots, spaces, and leading zeros in numeric portions (e.g. "I-094" → "i94").
    private func normalizeRouteString(_ s: String) -> String {
        let stripped = s.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
        // Remove leading zeros from numeric segments: "i094" → "i94"
        var result = ""
        var inDigits = false
        var leadingZero = true
        for ch in stripped {
            if ch.isNumber {
                if !inDigits { inDigits = true; leadingZero = true }
                if leadingZero && ch == "0" { continue }
                leadingZero = false
                result.append(ch)
            } else {
                if inDigits && result.last?.isNumber != true {
                    // All digits were zeros — keep a single "0"
                    result.append("0")
                }
                inDigits = false
                result.append(ch)
            }
        }
        if inDigits && (result.isEmpty || !result.last!.isNumber) {
            result.append("0")
        }
        return result
    }

    private func zoomToRoute(_ search: String) {
        let normalizedSearch = normalizeRouteString(search)
        // Find matching route in road or rail metadata
        let allMetadata = routeMetadata + railMetadata
        guard let meta = allMetadata.first(where: {
            normalizeRouteString($0.listName).contains(normalizedSearch) ||
            normalizeRouteString($0.root).contains(normalizedSearch)
        }) else { return }

        // Find all segments for that route in both road and rail
        let routeSegs = (segments + railSegments).filter { $0.root == meta.root }
        guard !routeSegs.isEmpty else { return }

        let lats = routeSegs.flatMap { [$0.start.latitude, $0.end.latitude] }
        let lngs = routeSegs.flatMap { [$0.start.longitude, $0.end.longitude] }
        let centerLat = (lats.min()! + lats.max()!) / 2
        let centerLng = (lngs.min()! + lngs.max()!) / 2
        let spanLat = max((lats.max()! - lats.min()!) * 1.3, 0.05)
        let spanLng = max((lngs.max()! - lngs.min()!) * 1.3, 0.05)

        Haptics.success()
        withAnimation {
            mapPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLng)
            ))
        }
    }

    private func zoomIn() { adjustZoom(factor: 0.5) }
    private func zoomOut() { adjustZoom(factor: 2.0) }

    private func adjustZoom(factor: Double) {
        // Use the tracked visible region so zoom stays in place
        guard let currentRegion = visibleRegion else { return }
        let center = currentRegion.center

        currentSpanLat = min(max(currentRegion.span.latitudeDelta * factor, 0.001), 180)
        currentSpanLng = min(max(currentRegion.span.longitudeDelta * factor, 0.001), 360)

        withAnimation {
            mapPosition = .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: currentSpanLat, longitudeDelta: currentSpanLng)
            ))
        }
    }

    // MARK: - Subviews

    private var loadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(loadingProgress ?? "Loading routes...")
                .font(.caption)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.selection()
                showClinched.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showClinched ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.blue)
                    Text("Traveled (\(clinchedCount.formatted()))")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show traveled segments: \(showClinched ? "on" : "off"), \(clinchedCount) segments")
            .accessibilityAddTraits(.isToggle)

            Button {
                Haptics.selection()
                showUnclinched.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showUnclinched ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.gray)
                    Text("Remaining (\((totalCount - clinchedCount).formatted()))")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show remaining segments: \(showUnclinched ? "on" : "off"), \(totalCount - clinchedCount) segments")
            .accessibilityAddTraits(.isToggle)

            // Rail toggle
            Button {
                Haptics.selection()
                showRail.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showRail ? "tram.fill" : "tram")
                        .foregroundStyle(showRail ? .red : .gray)
                    Text("Rail")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show rail: \(showRail ? "on" : "off")")
            .accessibilityAddTraits(.isToggle)

            Spacer()

            if !routeMetadata.isEmpty {
                MileageLabel(routeMetadata: routeMetadata)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var regionLabel: String {
        if selectedRegions.isEmpty { return "All" }
        if selectedRegions.count == 1 { return selectedRegions.first! }
        return "\(selectedRegions.count) regions"
    }

    private var regionPicker: some View {
        Button {
            showRegionPicker = true
        } label: {
            Label(regionLabel, systemImage: "globe")
                .font(.caption)
        }
        .accessibilityLabel("Region filter: \(regionLabel)")
    }

    /// Traveled regions grouped by country, favorites first within each country
    private var traveledRegionsByCountry: [(country: String, regions: [String])] {
        let favs = Set(settings.favoriteRegions)
        var byCountry: [String: [String]] = [:]
        for region in availableRegions {
            let country = regionCountryMap[region] ?? "Other"
            byCountry[country, default: []].append(region)
        }
        return byCountry
            .sorted { $0.key < $1.key }
            .map { country, regions in
                let sorted = regions.sorted { a, b in
                    let aFav = favs.contains(a)
                    let bFav = favs.contains(b)
                    if aFav != bFav { return aFav }
                    return a < b
                }
                return (country: country, regions: sorted)
            }
    }

    /// All regions NOT in the user's traveled set, grouped by country
    private var otherRegionsByCountry: [(country: String, regions: [String])] {
        let traveled = Set(availableRegions)
        return allRegionsByCountry.compactMap { country, regions in
            let other = regions.filter { !traveled.contains($0) }
            return other.isEmpty ? nil : (country: country, regions: other)
        }
    }

    @ViewBuilder
    private func regionRow(_ region: String) -> some View {
        HStack {
            Button {
                Haptics.selection()
                settings.toggleFavoriteRegion(region)
            } label: {
                Image(systemName: settings.isFavoriteRegion(region) ? "star.fill" : "star")
                    .foregroundStyle(settings.isFavoriteRegion(region) ? .yellow : .secondary)
                    .font(.subheadline)
            }
            .buttonStyle(.plain)

            Button {
                Haptics.selection()
                if pendingRegions.contains(region) {
                    pendingRegions.remove(region)
                } else {
                    pendingRegions.insert(region)
                }
            } label: {
                HStack {
                    Text(region)
                        .foregroundStyle(.primary)
                    Spacer()
                    if pendingRegions.contains(region) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var regionPickerSheet: some View {
        NavigationStack {
            List {
                // All Regions toggle
                Section {
                    Button {
                        Haptics.selection()
                        pendingRegions = []
                    } label: {
                        HStack {
                            Text("All Traveled Regions")
                                .foregroundStyle(.primary)
                            Spacer()
                            if pendingRegions.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Traveled regions grouped by country
                let traveled = traveledRegionsByCountry
                Section {
                    ForEach(traveled, id: \.country) { country, regions in
                        if traveled.count > 1 {
                            Text(country)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 2, trailing: 16))
                        }
                        ForEach(regions, id: \.self) { region in
                            regionRow(region)
                        }
                    }
                } header: {
                    Text("Your Regions")
                } footer: {
                    Text("Tap the star to mark favorites. Favorites auto-load when you open a user's map.")
                }

                // Other regions (not traveled) grouped by country
                let other = otherRegionsByCountry
                if !other.isEmpty {
                    Section {
                        ForEach(other, id: \.country) { country, regions in
                            DisclosureGroup(country) {
                                ForEach(regions, id: \.self) { region in
                                    regionRow(region)
                                }
                            }
                        }
                    } header: {
                        Text("Other Regions")
                    } footer: {
                        Text("Load regions you haven't traveled yet to see all routes in that area.")
                    }
                }
            }
            .navigationTitle("Regions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showRegionPicker = false
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Data Loading

    private func loadRegions() async {
        guard let profile = await dataService.loadUserProfile(username: username) else {
            errorMessage = "Could not load user profile"
            isLoading = false
            return
        }

        let regions = Array(profile.allRegions).sorted()
        availableRegions = regions

        // Load full region catalog for "Other Regions" picker + country grouping
        if allRegionsByCountry.isEmpty {
            if let catalog = try? await TravelMappingAPI.shared.getAllRoutes() {
                var countryMap: [String: String] = [:]
                var byCountry: [String: Set<String>] = [:]
                let catalogRegions = catalog.regions ?? []
                let countries = catalog.countries ?? []
                for (i, region) in catalogRegions.enumerated() where i < countries.count {
                    if countryMap[region] == nil {
                        countryMap[region] = countries[i]
                        byCountry[countries[i], default: []].insert(region)
                    }
                }
                regionCountryMap = countryMap
                allRegionsByCountry = byCountry
                    .sorted { $0.key < $1.key }
                    .map { (country: $0.key, regions: $0.value.sorted()) }
            }
        }

        // Favorite regions take priority if any exist
        let favoritesInThisProfile = Set(settings.favoriteRegions).intersection(regions)
        if !favoritesInThisProfile.isEmpty {
            selectedRegions = favoritesInThisProfile
            await loadSegments()
            return
        }

        if regions.count <= 3 {
            selectedRegions = []
            await loadSegments()
        } else {
            let regionCounts = profile.categories.values.flatMap { $0 }
                .reduce(into: [String: Int]()) { counts, seg in
                    counts[seg.primaryRegion, default: 0] += 1
                }
            if let topRegion = regionCounts.max(by: { $0.value < $1.value })?.key {
                selectedRegions = [topRegion]
            }
        }
    }

    private func loadSegments() async {
        isLoading = true
        loadingProgress = nil
        errorMessage = nil
        segments = []
        routeMetadata = []

        let regionsToLoad: [String]
        let clinchedOnly: Bool

        if selectedRegions.isEmpty {
            // "All Regions" — load everything but only keep clinched
            guard let profile = await dataService.loadUserProfile(username: username) else {
                errorMessage = "Could not load profile"
                isLoading = false
                return
            }
            regionsToLoad = Array(profile.allRegions).sorted()
            clinchedOnly = true
        } else {
            // Specific regions — load full data (clinched + unclinched)
            regionsToLoad = Array(selectedRegions).sorted()
            clinchedOnly = false
        }

        let total = regionsToLoad.count
        var allSegments: [TravelMappingAPI.MapSegment] = []
        var allRoutes: [TravelMappingAPI.RouteMetadata] = []
        var completed = 0
        let batchSize = 6

        for batchStart in stride(from: 0, to: regionsToLoad.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, regionsToLoad.count)
            let batch = Array(regionsToLoad[batchStart..<batchEnd])

            loadingProgress = "Loading \(completed)/\(total) regions..."

            await withTaskGroup(
                of: (segments: [TravelMappingAPI.MapSegment], routes: [TravelMappingAPI.RouteMetadata])?.self
            ) { group in
                for region in batch {
                    group.addTask {
                        do {
                            return try await TravelMappingAPI.shared.getRegionSegments(
                                region: region,
                                traveler: self.username
                            )
                        } catch {
                            SentrySDK.capture(error: error)
                            return nil
                        }
                    }
                }

                for await result in group {
                    if let result {
                        if clinchedOnly {
                            allSegments.append(contentsOf: result.segments.filter(\.isClinched))
                        } else {
                            allSegments.append(contentsOf: result.segments)
                        }
                        allRoutes.append(contentsOf: result.routes)
                    }
                    completed += 1
                }
            }

            // Update map after each batch
            segments = allSegments
            routeMetadata = allRoutes
            rebuildPolylines()
            loadingProgress = "Loading \(completed)/\(total) regions..."
        }

        segments = allSegments
        routeMetadata = allRoutes

        // Load rail data in parallel
        loadingProgress = "Loading rail data..."
        railSegments = []
        railMetadata = []
        var allRailSegs: [TravelMappingAPI.MapSegment] = []
        var allRailRoutes: [TravelMappingAPI.RouteMetadata] = []

        for region in regionsToLoad {
            do {
                let r = try await TravelMappingAPI.rail.getRegionSegments(
                    region: region,
                    traveler: username
                )
                if clinchedOnly {
                    allRailSegs.append(contentsOf: r.segments.filter(\.isClinched))
                } else {
                    allRailSegs.append(contentsOf: r.segments)
                }
                allRailRoutes.append(contentsOf: r.routes)
            } catch {
                // Region may not have rail data — that's fine
            }
        }

        railSegments = allRailSegs
        railMetadata = allRailRoutes

        rebuildPolylines()
        zoomToLoadedSegments()
        Haptics.success()

        // Report loaded regions to parent for share
        loadedRegionsBinding = Set(regionsToLoad)

        loadingProgress = nil
        isLoading = false
        SentrySDK.reportFullyDisplayed()
    }

    /// Zoom the map to fit the currently loaded clinched segments
    private func zoomToLoadedSegments() {
        // Use clinched road segments to determine bounds
        let clinchedCoords = segments.filter(\.isClinched).flatMap { [$0.start, $0.end] }
        guard !clinchedCoords.isEmpty else { return }

        let lats = clinchedCoords.map(\.latitude)
        let lngs = clinchedCoords.map(\.longitude)

        let minLat = lats.min()!
        let maxLat = lats.max()!
        let minLng = lngs.min()!
        let maxLng = lngs.max()!

        let centerLat = (minLat + maxLat) / 2
        let centerLng = (minLng + maxLng) / 2
        let spanLat = max((maxLat - minLat) * 1.2, 0.5)
        let spanLng = max((maxLng - minLng) * 1.2, 0.5)

        currentSpanLat = spanLat
        currentSpanLng = spanLng

        withAnimation {
            mapPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLng)
            ))
        }
    }

    // MARK: - Helpers

    private func colorForRoot(_ root: String) -> Color {
        guard let meta = routeMetadata.first(where: { $0.root == root }) else {
            return .blue
        }
        return Color(hex: meta.displayColorHex)
    }
}

// MARK: - Location Manager

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocation() {
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        SentrySDK.capture(error: error)
    }
}

// MARK: - Haptics

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - Mileage Label with unit toggle

struct MileageLabel: View {
    let routeMetadata: [TravelMappingAPI.RouteMetadata]
    @AppStorage("useMiles") private var useMiles = true

    private var totalMi: Double { routeMetadata.reduce(0.0) { $0 + $1.mileage } }
    private var clinchedMi: Double { routeMetadata.reduce(0.0) { $0 + $1.clinchedMileage } }

    private var displayClinched: Double { useMiles ? clinchedMi : clinchedMi * 1.60934 }
    private var displayTotal: Double { useMiles ? totalMi : totalMi * 1.60934 }
    private var unit: String { useMiles ? "mi" : "km" }

    var body: some View {
        Button {
            Haptics.selection()
            useMiles.toggle()
        } label: {
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f / %.1f %@", displayClinched, displayTotal, unit))
                    .font(.caption2.bold())
                if displayTotal > 0 {
                    Text(String(format: "%.1f%%", displayClinched / displayTotal * 100))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(format: "%.1f of %.1f %@ traveled, %.1f percent", displayClinched, displayTotal, unit, displayTotal > 0 ? displayClinched / displayTotal * 100 : 0))
        .accessibilityHint("Tap to switch between miles and kilometers")
    }
}

// MARK: - Segment Detail Sheet

struct SegmentDetailSheet: View {
    let detail: TravelMapView.SegmentDetail
    let username: String
    var onSelectAll: ((String) -> Void)? = nil
    var onSelectClinched: ((String) -> Void)? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Route info
                VStack(spacing: 8) {
                    Text(detail.listName)
                        .font(.title2.bold())

                    HStack(spacing: 16) {
                        Label(detail.startName, systemImage: "mappin")
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Label(detail.endName, systemImage: "mappin")
                    }
                    .font(.subheadline)

                    HStack {
                        Image(systemName: detail.isClinched ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(detail.isClinched ? .green : .gray)
                        Text(detail.isClinched ? "Traveled" : "Not yet traveled")
                            .font(.subheadline)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))

                // Route detail link
                NavigationLink {
                    RouteDetailView(
                        root: detail.root,
                        listName: detail.listName,
                        username: username,
                        isRail: detail.isRail
                    )
                } label: {
                    Label("View Full Route", systemImage: "map")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                // Route-level selection actions
                if onSelectAll != nil || onSelectClinched != nil {
                    VStack(spacing: 10) {
                        if let onSelectAll {
                            Button {
                                onSelectAll(detail.root)
                            } label: {
                                Label("Select All Segments on Route", systemImage: "checkmark.circle")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }

                        if let onSelectClinched {
                            Button {
                                onSelectClinched(detail.root)
                            } label: {
                                Label("Select Traveled Segments on Route", systemImage: "checkmark.circle.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Segment Detail")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Color from Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
