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
    /// Monotonically increasing load generation — each loadSegments call bumps it
    /// and checks it before every state write so stale loads can't overwrite newer state.
    @State private var loadGeneration = 0
    /// .task restarts whenever this view reappears (app tab switch, returning from a push).
    /// These stop that from reloading every region and resetting the user's region choice.
    @State private var didChooseInitialRegions = false
    @State private var mapDataLoaded = false
    /// Loads started from a region change. They outlive the view, unlike the .task-owned load,
    /// so while one is running a reappearing view must not restart loading.
    @State private var regionChangeLoads = 0
    @State private var errorMessage: String?
    /// Status filter (Traveled / Remaining), applied within the enabled modes. At least one
    /// stays on — turning one off with the other already off switches the other on.
    @State private var showClinched = true
    @State private var showUnclinched = false
    @State private var showRail = true
    /// Mode filter, independent of the Traveled/Remaining status filter — without it
    /// there was no way to see only rail (turning Traveled off hid traveled rail too)
    @State private var showRoads = true
    @State private var railSegments: [TravelMappingAPI.MapSegment] = []
    @State private var railMetadata: [TravelMappingAPI.RouteMetadata] = []
    /// Latest programmatic camera move; TravelMapCanvas applies each request once
    @State private var cameraRequest: TravelMapCanvas.CameraRequest?
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
    /// Last camera region, for tap hit-testing and zoom buttons. A plain reference, not
    /// @State: writing @State on every camera change re-ran this body and made SwiftUI
    /// re-diff thousands of MapPolylines after each pan (Sentry app-hang TRAVELMAPPING-H)
    @State private var camera = CameraTracker()

    private final class CameraTracker {
        var region: MKCoordinateRegion?
    }
    @StateObject private var locationManager = LocationManager()
    @State private var showLayersSheet = false
    @State private var zoomToUserOnNextFix = false
    @State private var isSelectMode = false
    @State private var selectedSegmentIDs: Set<String> = []
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

        var configuration: MKMapConfiguration {
            switch self {
            case .standard: return MKStandardMapConfiguration()
            case .satellite: return MKImageryMapConfiguration()
            case .hybrid: return MKHybridMapConfiguration()
            case .hybrid3D: return MKHybridMapConfiguration(elevationStyle: .realistic)
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

    /// Every drawable line, already grouped for TravelMapCanvas. Built off the main thread.
    @State private var lineGroups = MapLineGroups()
    /// Bumped per rebuild request, so a slower older rebuild can't overwrite a newer one
    @State private var rebuildRequest = 0
    /// Bumped each time lineGroups is replaced; part of the canvas's "what to draw" key
    @State private var polylineGeneration = 0

    /// Counts cover the modes currently shown, so Traveled/Remaining match the map
    private var clinchedCount: Int {
        (showRoads ? segments.filter(\.isClinched).count : 0) + (showRail ? railSegments.filter(\.isClinched).count : 0)
    }
    private var totalCount: Int { (showRoads ? segments.count : 0) + (showRail ? railSegments.count : 0) }

    private var showClinchedBinding: Binding<Bool> {
        Binding(get: { showClinched }, set: { setStatus(traveled: $0, remaining: $0 ? showUnclinched : true) })
    }
    private var showUnclinchedBinding: Binding<Bool> {
        Binding(get: { showUnclinched }, set: { setStatus(traveled: $0 ? showClinched : true, remaining: $0) })
    }
    private func setStatus(traveled: Bool, remaining: Bool) {
        showClinched = traveled
        showUnclinched = remaining
    }

    /// Merge consecutive 2-point segments on the same route into multi-point polylines.
    /// Runs the expensive sort/merge on a background thread to avoid main-thread hangs.
    private func rebuildPolylines() {
        let roadSegs = segments
        let railSegs = railSegments
        let maxCoords = maxPolylineCoords
        // First entry wins, matching the old per-polyline routeMetadata.first(where:)
        let colorHexByRoot = Dictionary(
            routeMetadata.map { ($0.root, $0.displayColorHex) },
            uniquingKeysWith: { first, _ in first }
        )
        rebuildRequest += 1
        let request = rebuildRequest

        Task.detached(priority: .userInitiated) {
            var groups = MapLineGroups()
            for line in Self.mergedLines(from: roadSegs, maxCoords: maxCoords) {
                if line.isClinched {
                    groups.traveledRoadsByColorHex[colorHexByRoot[line.root] ?? MapLineGroups.fallbackColorHex, default: []]
                        .append(line.polyline)
                } else {
                    groups.remainingRoads.append(line.polyline)
                }
            }
            // Rail draws as a solid double stroke, never dashed, so it doesn't need the dash cap
            for line in Self.mergedLines(from: railSegs, maxCoords: 200) {
                if line.isClinched {
                    groups.traveledRail.append(line.polyline)
                } else {
                    groups.remainingRail.append(line.polyline)
                }
            }
            let built = groups
            await MainActor.run {
                guard request == rebuildRequest else { return }
                lineGroups = built
                polylineGeneration += 1
            }
        }
    }

    nonisolated private static func mergedLines(
        from segs: [TravelMappingAPI.MapSegment],
        maxCoords: Int
    ) -> [(polyline: MKPolyline, isClinched: Bool, root: String)] {
        let filtered = segs.sorted { $0.root < $1.root || ($0.root == $1.root && $0.orderIndex < $1.orderIndex) }
        var result: [(polyline: MKPolyline, isClinched: Bool, root: String)] = []
        var currentCoords: [CLLocationCoordinate2D] = []
        var currentRoot = ""
        var currentClinched = false

        func emit() {
            result.append((
                MKPolyline(coordinates: currentCoords, count: currentCoords.count),
                currentClinched,
                currentRoot
            ))
        }

        for seg in filtered {
            let sameLine = seg.root == currentRoot && seg.isClinched == currentClinched

            if sameLine, let last = currentCoords.last,
               coordDistance(last, seg.start) < 500 {
                currentCoords.append(seg.end)
                if currentCoords.count >= maxCoords {
                    emit()
                    currentCoords = [seg.end]
                }
            } else {
                if currentCoords.count >= 2 {
                    emit()
                }
                currentCoords = [seg.start, seg.end]
                currentRoot = seg.root
                currentClinched = seg.isClinched
            }
        }
        if currentCoords.count >= 2 {
            emit()
        }
        return result
    }

    /// Static version of distance for use in static methods
    nonisolated private static func coordDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = (a.latitude - b.latitude) * 111_320
        let dLng = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return sqrt(dLat * dLat + dLng * dLng)
    }

    /// Max coordinates per polyline. MapKit stops rendering dash patterns on
    /// geographically long polylines, so dashed/dotted road styles need short
    /// polylines (15 coords) to keep dashes visible. Solid styles have no such
    /// limit — and a low cap multiplies the overlay count enormously (a 20k-segment
    /// region becomes ~1,400 MapPolylines), which blocks the main thread for
    /// 10+ seconds inside MKMapView addOverlays: (Sentry app-hang TRAVELMAPPING-H).
    private var maxPolylineCoords: Int {
        switch MapStyleService.parse(settings.roadLineStyle) {
        case .dashed, .dotted: return 15
        case .solid, .thick, .thin: return 200
        }
    }

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

            // Right-side controls — zoom, locate, and one accented Layers button
            // (map style, show/hide toggles, legend and select mode live in the
            // Layers sheet). Padded below compass/nav bar to avoid overlap.
            VStack {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        zoomControls
                        locationButton
                        if isSelectMode {
                            exitSelectButton
                        }
                        layersButton
                    }
                    .padding(.trailing, 12)
                    .padding(.top, 70)
                }
                Spacer()
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TMDesign.redChipFG)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel("Error: \(error)")
                }

                // Mileage chip, bottom-left (audit §6)
                HStack {
                    if !routeMetadata.isEmpty {
                        MileageLabel(routeMetadata: routeMetadata)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)

                // Select mode swaps the filter pills for the selection/export UI
                if isSelectMode {
                    if selectedSegmentIDs.isEmpty {
                        selectModeHint
                    }
                } else {
                    filterPills
                }
            }
            .padding(.bottom, 8)
        }
        .navigationTitle("\(username)'s Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Shown in place of the plain title so replays can mask the username
            ToolbarItem(placement: .principal) {
                Text("\(username)'s Map")
                    .font(.headline)
                    .lineLimit(1)
                    .sentryReplayMask()
            }
        }
        .background {
            // .searchable applied conditionally above the Map would swap the view
            // tree on every tab switch and tear down the MapKit layer (the 5-7s
            // iPad Metal-teardown hang class). Hosting it on a background leaf
            // keeps the Map's identity stable — only this Color.clear comes and
            // goes with isActiveTab, while the search field still only appears
            // when this tab is active.
            if isActiveTab {
                Color.clear
                    .searchable(text: $routeSearchText, prompt: "Search routes (e.g. I-95)")
            }
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
            .presentationCornerRadius(26)
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLayersSheet) {
            layersSheet
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
            guard !mapDataLoaded else { return }
            if !didChooseInitialRegions {
                await loadRegions()
            } else if isLoading && regionChangeLoads == 0 {
                // Going away cancelled the .task-owned load. This one supersedes it, so it stops
                // at its next check whether or not it has got there yet.
                await loadSegments()
            }
        }
        .task {
            // Separate from the load above so a failed fetch is retried on the next appearance
            if allRegionsByCountry.isEmpty {
                await loadRegionCatalog()
            }
        }
        .onChange(of: selectedRegions) {
            regionChangeLoads += 1
            Task {
                await loadSegments()
                regionChangeLoads -= 1
            }
        }
        .onChange(of: settings.roadLineStyle) {
            // The merge cap depends on the line style (dashes need short polylines)
            rebuildPolylines()
        }
        .onChange(of: locationManager.lastLocation?.timestamp) {
            if zoomToUserOnNextFix, let loc = locationManager.lastLocation {
                zoomToUserOnNextFix = false
                zoomToLocation(loc)
            }
        }
    }

    // MARK: - Map

    /// Selected segments as merged polylines. Only called when the selection changes.
    private func selectedLines() -> [MKPolyline] {
        let selectedSegs = segments.filter { selectedSegmentIDs.contains($0.id) }
        var result: [MKPolyline] = []
        var coords: [CLLocationCoordinate2D] = []
        var currentRoot = ""

        for seg in selectedSegs.sorted(by: { $0.root < $1.root || ($0.root == $1.root && $0.orderIndex < $1.orderIndex) }) {
            if seg.root == currentRoot, let last = coords.last, distance(last, seg.start) < 500 {
                coords.append(seg.end)
            } else {
                if coords.count >= 2 {
                    result.append(MKPolyline(coordinates: coords, count: coords.count))
                }
                coords = [seg.start, seg.end]
                currentRoot = seg.root
            }
        }
        if coords.count >= 2 {
            result.append(MKPolyline(coordinates: coords, count: coords.count))
        }
        return result
    }

    private var mapLayer: some View {
        TravelMapCanvas(
            groups: lineGroups,
            contentKey: TravelMapCanvas.ContentKey(
                polylineGeneration: polylineGeneration,
                showRoads: showRoads,
                showRail: showRail,
                showClinched: showClinched,
                showUnclinched: showUnclinched
            ),
            selectedSegmentIDs: selectedSegmentIDs,
            selectedLines: selectedLines,
            style: TravelMapCanvas.Style(
                mapStyle: mapStyle,
                roadLineStyle: MapStyleService.parse(settings.roadLineStyle),
                roadLineWidth: settings.roadLineWidth,
                railLineWidth: settings.railLineWidth,
                untraveledVisibility: settings.untraveledVisibility
            ),
            cameraRequest: cameraRequest,
            onCameraChange: { region in
                camera.region = region
            },
            onTap: { coordinate in
                handleSegmentTap(at: coordinate)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func handleSegmentTap(at coordinate: CLLocationCoordinate2D) {
        // Pre-filter to segments within the visible map region to avoid iterating all segments
        let region = camera.region ?? MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
        )
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLng = region.center.longitude - region.span.longitudeDelta / 2
        let maxLng = region.center.longitude + region.span.longitudeDelta / 2
        let spanLng = region.span.longitudeDelta

        // Antimeridian-aware longitude test: when the visible window crosses ±180°
        // the raw min/max wraps out of [-180, 180], so normalize the segment
        // longitude into the window's frame; skip the filter for near-global spans.
        func lngInBounds(_ lng: Double) -> Bool {
            if spanLng >= 180 { return true }
            if minLng < -180 { return lng >= minLng + 360 || lng <= maxLng }
            if maxLng > 180 { return lng >= minLng || lng <= maxLng - 360 }
            return lng >= minLng && lng <= maxLng
        }

        func inBounds(_ seg: TravelMappingAPI.MapSegment) -> Bool {
            (seg.start.latitude >= minLat && seg.start.latitude <= maxLat &&
             lngInBounds(seg.start.longitude)) ||
            (seg.end.latitude >= minLat && seg.end.latitude <= maxLat &&
             lngInBounds(seg.end.longitude))
        }

        var visibleSegs: [TravelMappingAPI.MapSegment] = []
        for seg in segments where showRoads && inBounds(seg) {
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
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
            }
            .accessibilityLabel("Zoom in")

            Divider()
                .frame(width: 46)

            Button {
                Haptics.light()
                zoomOut()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
            }
            .accessibilityLabel("Zoom out")
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 7, y: 2)
        .buttonStyle(.plain)
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
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 7, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show my location")
    }

    private func zoomToLocation(_ loc: CLLocation) {
        cameraRequest = TravelMapCanvas.CameraRequest(region: MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        ))
    }

    /// The one accented control: opens the Layers sheet (audit §6).
    private var layersButton: some View {
        Button {
            Haptics.light()
            showLayersSheet = true
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(TMDesign.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: Color(tmHex: 0x2F6BF0, opacity: 0.4), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map layers")
        .accessibilityHint("Show or hide lines, change the base map, and start select mode")
    }

    /// Visible only in select mode — dedicated exit that mirrors the old pencil toggle.
    private var exitSelectButton: some View {
        Button {
            Haptics.selection()
            isSelectMode = false
            selectedSegmentIDs.removeAll()
        } label: {
            Image(systemName: "pencil.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.yellow)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 7, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Exit select mode")
        .accessibilityHint("Clears the current selection")
    }

    /// Shown while select mode is on but nothing is selected yet.
    private var selectModeHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.yellow)
            Text("Select mode — tap segments to add them")
                .font(.system(size: 15, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.yellow.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Layers Sheet

    /// Bottom sheet consolidating show/hide toggles (the real legend), base-map
    /// picker, and the select-mode toggle (audit §6).
    private var layersSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Map layers")
                    .font(.system(size: 22, weight: .heavy))
                    .padding(.top, 20)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 8) {
                    TMDesign.sectionHeader("Segments")
                    VStack(spacing: 0) {
                        layerToggleRow(
                            icon: "checkmark",
                            iconBG: TMDesign.blueChipBG,
                            iconFG: TMDesign.blueChipFG,
                            title: "Traveled",
                            subtitle: "\(clinchedCount.formatted()) segments",
                            swatch: AnyView(lineSwatch(
                                color: TMDesign.accent,
                                style: .solid,
                                width: min(settings.roadLineWidth, 5)
                            )),
                            isOn: showClinchedBinding
                        )
                        Divider().padding(.leading, 57)
                        layerToggleRow(
                            icon: "road.lanes",
                            iconBG: TMDesign.amberChipBG,
                            iconFG: TMDesign.amberChipFG,
                            title: "Remaining",
                            subtitle: "\((totalCount - clinchedCount).formatted()) segments",
                            swatch: AnyView(lineSwatch(
                                color: TMDesign.frontier.opacity(settings.untraveledVisibility),
                                style: .solid,
                                width: max(1.5, settings.roadLineWidth * 0.75)
                            )),
                            isOn: showUnclinchedBinding
                        )
                    }
                    .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    TMDesign.sectionHeader("Modes")
                    VStack(spacing: 0) {
                        layerToggleRow(
                            icon: "car.fill",
                            iconBG: TMDesign.blueChipBG,
                            iconFG: TMDesign.blueChipFG,
                            title: "Roads",
                            subtitle: "\(segments.count.formatted()) segments",
                            swatch: AnyView(
                                lineSwatch(
                                    color: TMDesign.accent,
                                    style: MapStyleService.parse(settings.roadLineStyle),
                                    width: min(settings.roadLineWidth, 5)
                                )
                            ),
                            isOn: $showRoads
                        )
                        Divider().padding(.leading, 57)
                        layerToggleRow(
                            icon: "tram.fill",
                            iconBG: TMDesign.redChipBG,
                            iconFG: TMDesign.redChipFG,
                            title: "Rail & transit",
                            subtitle: "\(railSegments.count.formatted()) segments",
                            swatch: AnyView(railSwatch),
                            isOn: $showRail
                        )
                    }
                    .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    TMDesign.sectionHeader("Base map")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(MapStyleOption.allCases, id: \.self) { option in
                            baseMapTile(option)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TMDesign.sectionHeader("Tools")
                    HStack(spacing: 12) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TMDesign.amberChipFG)
                            .frame(width: 32, height: 32)
                            .background(TMDesign.amberChipBG, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Select & export")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Tap segments on the map to build a .list export")
                                .font(.system(size: 13))
                                .foregroundStyle(TMDesign.tertiaryText)
                        }
                        Spacer()
                        Toggle("Select and export segments", isOn: selectModeBinding)
                            .labelsHidden()
                            .tint(TMDesign.clinched)
                    }
                    .padding(13)
                    .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(26)
        .presentationBackground(TMDesign.secondarySurface)
    }

    private var selectModeBinding: Binding<Bool> {
        Binding(
            get: { isSelectMode },
            set: { on in
                Haptics.selection()
                isSelectMode = on
                if !on {
                    selectedSegmentIDs.removeAll()
                }
            }
        )
    }

    private func layerToggleRow(
        icon: String,
        iconBG: Color,
        iconFG: Color,
        title: String,
        subtitle: String,
        swatch: AnyView,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconFG)
                .frame(width: 32, height: 32)
                .background(iconBG, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                HStack(spacing: 6) {
                    swatch
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(TMDesign.tertiaryText)
                }
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(TMDesign.clinched)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    /// Line swatch honoring the user's Map Line Style settings (audit §15).
    private func lineSwatch(color: Color, style: MapStyleService.LineStyle, width: Double) -> some View {
        Canvas { ctx, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(path, with: .color(color), style: MapStyleService.strokeStyle(for: style, baseWidth: width))
        }
        .frame(width: 36, height: 10)
        .accessibilityHidden(true)
    }

    /// Double-stroke rail swatch matching the map's "railroad" rendering.
    private var railSwatch: some View {
        Canvas { ctx, size in
            let y = size.height / 2
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            let width = max(3, settings.railLineWidth)
            ctx.stroke(path, with: .color(.red), lineWidth: width)
            ctx.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: width * 0.4)
        }
        .frame(width: 36, height: 10)
        .accessibilityHidden(true)
    }

    private func baseMapTile(_ option: MapStyleOption) -> some View {
        let isSelected = option == mapStyle
        return Button {
            Haptics.light()
            mapStyle = option
        } label: {
            VStack(spacing: 6) {
                Image(systemName: option.icon)
                    .font(.system(size: 20, weight: .semibold))
                Text(option.rawValue)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isSelected ? TMDesign.accent : TMDesign.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? TMDesign.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Base map: \(option.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// A merged selection line with a stable identity derived from its segment IDs —
    /// duplicate display texts must not collide in ForEach.
    private struct SelectionLine: Identifiable {
        let ids: Set<String>
        let text: String
        var id: String { ids.sorted().joined(separator: ",") }
    }

    /// Merged lines for the selection detail panel — consecutive segments on the same route
    /// become a single line (e.g., "IRL E20 11(M7) 6(N7)" instead of 6 separate lines).
    private var selectionLines: [SelectionLine] {
        let selected = segments.filter { selectedSegmentIDs.contains($0.id) }
        let rootToName = Dictionary(routeMetadata.map { ($0.root, $0.listName) }, uniquingKeysWith: { a, _ in a })

        let sorted = selected.sorted { a, b in
            if a.root != b.root { return a.root < b.root }
            return a.orderIndex < b.orderIndex
        }

        struct MergedLine {
            var ids: Set<String>
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

        return result.map { SelectionLine(ids: $0.ids, text: $0.text) }
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
                            .font(.system(size: 12, weight: .bold))
                        Text("\(selectedSegmentIDs.count.formatted()) selected")
                            .font(.system(size: 15, weight: .bold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    Haptics.success()
                    UIPasteboard.general.string = generateSelectionText()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy .list text to clipboard")

                ShareLink(item: generateSelectionText()) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share .list file")

                Button {
                    Haptics.light()
                    selectedSegmentIDs.removeAll()
                    showSelectionDetail = false
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear selection")
            }
            .padding(.horizontal, 8)

            // Expandable detail panel
            if showSelectionDetail {
                Divider()
                    .background(.yellow.opacity(0.3))

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(selectionLines) { line in
                            HStack {
                                Text(line.text)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Button {
                                    Haptics.light()
                                    selectedSegmentIDs.subtract(line.ids)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 40, height: 34)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(line.text) from selection")
                            }
                            .padding(.leading, 12)
                            .padding(.trailing, 4)
                            .padding(.vertical, 2)
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

    /// Longitude center/span that stays correct for regions straddling the
    /// antimeridian (±180°, e.g. the Aleutians): when the raw span exceeds 180°,
    /// shift western longitudes by +360 and normalize the center back.
    nonisolated private static func longitudeCenterAndSpan(for lngs: [Double]) -> (center: Double, span: Double) {
        guard let rawMin = lngs.min(), let rawMax = lngs.max() else { return (0, 0) }
        if rawMax - rawMin <= 180 {
            return ((rawMin + rawMax) / 2, rawMax - rawMin)
        }
        let shifted = lngs.map { $0 < 0 ? $0 + 360 : $0 }
        let sMin = shifted.min()!
        let sMax = shifted.max()!
        var center = (sMin + sMax) / 2
        if center > 180 { center -= 360 }
        return (center, sMax - sMin)
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
        let (centerLng, lngSpan) = Self.longitudeCenterAndSpan(for: lngs)
        let spanLat = max((lats.max()! - lats.min()!) * 1.3, 0.05)
        let spanLng = min(max(lngSpan * 1.3, 0.05), 360)

        Haptics.success()
        cameraRequest = TravelMapCanvas.CameraRequest(region: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLng)
        ))
    }

    private func zoomIn() { adjustZoom(factor: 0.5) }
    private func zoomOut() { adjustZoom(factor: 2.0) }

    private func adjustZoom(factor: Double) {
        // Use the tracked visible region so zoom stays in place
        guard let currentRegion = camera.region else { return }
        let center = currentRegion.center

        currentSpanLat = min(max(currentRegion.span.latitudeDelta * factor, 0.001), 180)
        currentSpanLng = min(max(currentRegion.span.longitudeDelta * factor, 0.001), 360)

        cameraRequest = TravelMapCanvas.CameraRequest(region: MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: currentSpanLat, longitudeDelta: currentSpanLng)
        ))
    }

    // MARK: - Subviews

    private var loadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(loadingProgress ?? "Loading routes...")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Bottom filter pills with live counts — filled = on (audit §6). These drive
    /// the same showRoads/showRail (mode) and showClinched/showUnclinched (status) state
    /// as the Layers sheet. "Only rail" = Roads off; "only what I haven't driven" =
    /// Traveled off.
    private var filterPills: some View {
        // A fixed row when the pills fit; scroll sideways only when they don't
        ViewThatFits(in: .horizontal) {
            filterPillRow
            ScrollView(.horizontal, showsIndicators: false) {
                filterPillRow
            }
            .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var filterPillRow: some View {
        HStack(spacing: 6) {
            filterPill(
                // Mode pills are icon-only so all four fit; counts live in the Layers sheet
                "",
                icon: "car.fill",
                isOn: showRoads,
                onBG: TMDesign.neutralChipFG,
                offFG: TMDesign.neutralChipFG,
                accessibilityLabel: "Show roads: \(showRoads ? "on" : "off"), \(segments.count) segments"
            ) { showRoads.toggle() }

            filterPill(
                "",
                icon: "tram.fill",
                isOn: showRail,
                onBG: TMDesign.rail,
                offFG: TMDesign.redChipFG,
                accessibilityLabel: "Show rail: \(showRail ? "on" : "off"), \(railSegments.count) segments"
            ) { showRail.toggle() }

            // Divider between the mode pills (Roads/Rail) and the status pills (Traveled/Remaining)
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 1.5, height: 18)
                .accessibilityHidden(true)

            filterPill(
                "Traveled \(clinchedCount.formatted())",
                isOn: showClinched,
                onBG: TMDesign.accent,
                offFG: TMDesign.blueChipFG,
                accessibilityLabel: "Show traveled segments: \(showClinched ? "on" : "off"), \(clinchedCount) segments"
            ) { showClinchedBinding.wrappedValue.toggle() }

            filterPill(
                "Remaining \((totalCount - clinchedCount).formatted())",
                isOn: showUnclinched,
                onBG: TMDesign.frontier,
                offFG: TMDesign.amberChipFG,
                accessibilityLabel: "Show remaining segments: \(showUnclinched ? "on" : "off"), \(totalCount - clinchedCount) segments"
            ) { showUnclinchedBinding.wrappedValue.toggle() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private func filterPill(
        _ label: String,
        icon: String? = nil,
        isOn: Bool,
        onBG: Color,
        offFG: Color,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isOn ? Color.white : offFG)
                        .frame(width: 10, height: 10)
                }
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(isOn ? Color.white : offFG)
            // Tight enough that all four pills fit without scrolling on a 402pt screen
            .padding(.horizontal, label.isEmpty ? 0 : 9)
            .frame(minWidth: 44, minHeight: 44)
            .background(isOn ? onBG : TMDesign.cardBG, in: Capsule())
            .overlay(Capsule().stroke(isOn ? Color.clear : TMDesign.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isToggle)
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
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .semibold))
                Text(regionLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(TMDesign.blueChipFG)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(TMDesign.blueChipBG, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Region filter: \(regionLabel)")
        .accessibilityHint("Choose which regions to load on the map")
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
            // Not a failure: the view went away, and the next appearance starts over
            guard !Task.isCancelled else { return }
            errorMessage = "Could not load user profile"
            isLoading = false
            return
        }

        let regions = Array(profile.allRegions).sorted()
        availableRegions = regions

        didChooseInitialRegions = true

        // Favorite regions take priority if any exist.
        // Setting selectedRegions fires onChange → loadSegments; do NOT also call
        // loadSegments here or the data loads twice.
        let favoritesInThisProfile = Set(settings.favoriteRegions).intersection(regions)
        if !favoritesInThisProfile.isEmpty {
            selectedRegions = favoritesInThisProfile
            return
        }

        if regions.count <= 3 {
            // selectedRegions is already [] here, so assigning [] fires no onChange —
            // this explicit call is the only load for the "All Regions" case.
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

    /// Full region catalog for the "Other Regions" picker + country grouping
    private func loadRegionCatalog() async {
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

    private func loadSegments() async {
        // Bump the generation: any older load still in flight sees a mismatch at
        // its next checkpoint and bails without touching state.
        loadGeneration += 1
        let generation = loadGeneration

        isLoading = true
        loadingProgress = nil
        errorMessage = nil
        segments = []
        routeMetadata = []

        let regionsToLoad: [String]
        let clinchedOnly: Bool

        if selectedRegions.isEmpty {
            // "All Regions" — load everything but only keep clinched
            let profile = await dataService.loadUserProfile(username: username)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            guard let profile else {
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
            // Stop between batches if this task was cancelled or a newer load started
            guard !Task.isCancelled, generation == loadGeneration else { return }

            let batchEnd = min(batchStart + batchSize, regionsToLoad.count)
            let batch = Array(regionsToLoad[batchStart..<batchEnd])

            loadingProgress = "Loading \(completed)/\(total) regions..."

            await withTaskGroup(
                of: (segments: [TravelMappingAPI.MapSegment], routes: [TravelMappingAPI.RouteMetadata])?.self
            ) { group in
                for region in batch {
                    group.addTask {
                        // API layer captures htmlResponseInsteadOfJSON with the HTML body attached;
                        // re-capturing here would just duplicate the event.
                        return try? await TravelMappingAPI.shared.getRegionSegments(
                            region: region,
                            traveler: self.username
                        )
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

            // Update map after each batch — only if still the current load
            guard !Task.isCancelled, generation == loadGeneration else { return }
            // A batch of regions the traveler has no clinched segments in changes nothing
            if allSegments.count != segments.count {
                segments = allSegments
                routeMetadata = allRoutes
                rebuildPolylines()
            }
            loadingProgress = "Loading \(completed)/\(total) regions..."
        }

        guard !Task.isCancelled, generation == loadGeneration else { return }
        segments = allSegments
        routeMetadata = allRoutes

        // Load rail data in parallel
        loadingProgress = "Loading rail data..."
        railSegments = []
        railMetadata = []
        var allRailSegs: [TravelMappingAPI.MapSegment] = []
        var allRailRoutes: [TravelMappingAPI.RouteMetadata] = []

        for region in regionsToLoad {
            guard !Task.isCancelled, generation == loadGeneration else { return }
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

        guard !Task.isCancelled, generation == loadGeneration else { return }
        railSegments = allRailSegs
        railMetadata = allRailRoutes

        rebuildPolylines()
        zoomToLoadedSegments()
        Haptics.success()

        // Report loaded regions to parent for share
        loadedRegionsBinding = Set(regionsToLoad)

        loadingProgress = nil
        isLoading = false
        mapDataLoaded = true
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

        let centerLat = (minLat + maxLat) / 2
        let (centerLng, lngSpan) = Self.longitudeCenterAndSpan(for: lngs)
        let spanLat = max((maxLat - minLat) * 1.2, 0.5)
        let spanLng = min(max(lngSpan * 1.2, 0.5), 360)

        currentSpanLat = spanLat
        currentSpanLng = spanLng

        cameraRequest = TravelMapCanvas.CameraRequest(region: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLng)
        ))
    }

    // MARK: - Helpers
}

// MARK: - Map Canvas

/// Every drawable map line, grouped by how it's stroked. Each group becomes one
/// MKMultiPolyline overlay in TravelMapCanvas.
fileprivate struct MapLineGroups {
    static let fallbackColorHex = "#0000FF"

    var traveledRoadsByColorHex: [String: [MKPolyline]] = [:]
    var remainingRoads: [MKPolyline] = []
    var traveledRail: [MKPolyline] = []
    var remainingRail: [MKPolyline] = []
}

/// The map, as a thin MKMapView wrapper that draws all lines through a handful of
/// MKMultiPolyline overlays.
///
/// SwiftUI's Map can only draw one overlay per MapPolyline, and MapKit's cost grows with
/// the square of the overlay count (a linear find in md::OverlayContainer per insert, plus
/// SwiftUI copying every MultiPoint on each update). Measured on the largest profile
/// (All Regions, 17k polylines) each Map update froze the main thread for 58 s, even when
/// nothing had changed, and 935 polylines still cost 0.5 s (Sentry TRAVELMAPPING-H).
/// Here the overlay count is about 15 whatever the profile size, and overlays are only
/// touched when what they draw changes, so unrelated TravelMapView body passes do nothing.
fileprivate struct TravelMapCanvas: UIViewRepresentable {
    let groups: MapLineGroups
    /// What `groups` was built from plus the filters; compared instead of the arrays
    let contentKey: ContentKey
    let selectedSegmentIDs: Set<String>
    /// Only called when the selection changes: it scans every loaded segment
    let selectedLines: () -> [MKPolyline]
    let style: Style
    let cameraRequest: CameraRequest?
    let onCameraChange: (MKCoordinateRegion) -> Void
    let onTap: (CLLocationCoordinate2D) -> Void

    struct ContentKey: Equatable {
        let polylineGeneration: Int
        let showRoads: Bool
        let showRail: Bool
        let showClinched: Bool
        let showUnclinched: Bool
    }

    struct Style: Equatable {
        let mapStyle: TravelMapView.MapStyleOption
        let roadLineStyle: MapStyleService.LineStyle
        let roadLineWidth: Double
        let railLineWidth: Double
        let untraveledVisibility: Double
    }

    struct CameraRequest: Equatable {
        let id = UUID()
        let region: MKCoordinateRegion

        static func == (lhs: CameraRequest, rhs: CameraRequest) -> Bool { lhs.id == rhs.id }
    }

    struct Stroke: Equatable {
        let color: UIColor
        let width: CGFloat
        var dash: [CGFloat] = []

        /// A plain RGB color for one appearance: dynamic or bridged colors don't reliably
        /// compare equal (which decides overlay reuse), and a renderer never re-resolves them.
        static func fixedColor(_ color: Color, scheme: ColorScheme, alpha: CGFloat = 1) -> UIColor {
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            var (red, green, blue, ignored): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &ignored)
            return UIColor(red: red, green: green, blue: blue, alpha: alpha)
        }
    }

    /// One overlay's worth of lines. An overlay is reused while its key and stroke match.
    struct Layer {
        let key: String
        let polylines: [MKPolyline]
        let stroke: Stroke
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        // Only compass and scale; the screen has its own zoom and location buttons
        mapView.showsCompass = true
        mapView.showsScale = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)
        // Observers only, alongside the map's own gestures: they stop automatic framing
        let panObserver = UIPanGestureRecognizer()
        panObserver.allowedScrollTypesMask = .all
        let doubleTapObserver = UITapGestureRecognizer()
        doubleTapObserver.numberOfTapsRequired = 2
        let observers: [UIGestureRecognizer] = [panObserver, UIPinchGestureRecognizer(), UIRotationGestureRecognizer(), doubleTapObserver]
        for observer in observers {
            observer.addTarget(context.coordinator, action: #selector(Coordinator.userMovedCamera))
            observer.cancelsTouchesInView = false
            observer.delaysTouchesEnded = false
            observer.delegate = context.coordinator
            mapView.addGestureRecognizer(observer)
        }
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onCameraChange = onCameraChange
        coordinator.onTap = onTap

        if coordinator.appliedMapStyle != style.mapStyle {
            coordinator.appliedMapStyle = style.mapStyle
            mapView.preferredConfiguration = style.mapStyle.configuration
        }

        // Also on new lines: a selected segment may no longer be loaded
        let selectionChanged = coordinator.appliedSelection != selectedSegmentIDs
            || (!selectedSegmentIDs.isEmpty && coordinator.appliedContentKey?.polylineGeneration != contentKey.polylineGeneration)
        if selectionChanged {
            coordinator.appliedSelection = selectedSegmentIDs
            coordinator.selectionGeneration += 1
            coordinator.selection = selectedSegmentIDs.isEmpty ? [] : selectedLines()
        }
        let scheme = context.environment.colorScheme
        let contentChanged = coordinator.appliedContentKey != contentKey
            || coordinator.appliedStyle != style
            || coordinator.appliedColorScheme != scheme
        if contentChanged || selectionChanged {
            coordinator.appliedContentKey = contentKey
            coordinator.appliedStyle = style
            coordinator.appliedColorScheme = scheme
            coordinator.reconcile(mapView, with: baseLayers(scheme: scheme) + coordinator.selectionLayers())
        }

        if let cameraRequest, coordinator.appliedCameraRequest != cameraRequest {
            coordinator.appliedCameraRequest = cameraRequest
            mapView.setRegion(Self.validated(cameraRequest.region), animated: true)
        } else if contentChanged {
            coordinator.fitContentIfCameraUntouched(mapView)
        }
    }

    /// Stacking order is array order: remaining below traveled, roads below rail.
    private func baseLayers(scheme: ColorScheme) -> [Layer] {
        let generation = contentKey.polylineGeneration
        let remainingColor = Stroke.fixedColor(TMDesign.frontier, scheme: scheme, alpha: style.untraveledVisibility)
        var layers: [Layer] = []

        if contentKey.showRoads {
            if contentKey.showUnclinched {
                layers.append(Layer(
                    key: "road-remaining|\(generation)",
                    polylines: groups.remainingRoads,
                    stroke: roadStroke(
                        color: remainingColor,
                        baseWidth: max(1.5, style.roadLineWidth * 0.75)
                    )
                ))
            }
            if contentKey.showClinched {
                for (hex, polylines) in groups.traveledRoadsByColorHex.sorted(by: { $0.key < $1.key }) {
                    layers.append(Layer(
                        key: "road-traveled|\(hex)|\(generation)",
                        polylines: polylines,
                        stroke: roadStroke(color: Stroke.fixedColor(Color(hex: hex), scheme: scheme), baseWidth: style.roadLineWidth)
                    ))
                }
            }
        }

        // Rail draws as a double stroke because MapKit doesn't reliably render dash patterns
        if contentKey.showRail {
            if contentKey.showUnclinched {
                layers.append(Layer(
                    key: "rail-remaining|\(generation)",
                    polylines: groups.remainingRail,
                    stroke: Stroke(
                        color: remainingColor,
                        width: max(2.0, style.railLineWidth * 0.6)
                    )
                ))
            }
            if contentKey.showClinched {
                layers.append(Layer(
                    key: "rail-traveled|\(generation)",
                    polylines: groups.traveledRail,
                    stroke: Stroke(color: .red, width: style.railLineWidth)
                ))
                // Inner stroke (thinner, white) creates the "track" look
                if style.railLineWidth > 2 {
                    layers.append(Layer(
                        key: "rail-track|\(generation)",
                        polylines: groups.traveledRail,
                        stroke: Stroke(color: UIColor.white.withAlphaComponent(0.5), width: style.railLineWidth * 0.4)
                    ))
                }
            }
        }
        return layers
    }

    private func roadStroke(color: UIColor, baseWidth: Double) -> Stroke {
        Stroke(
            color: color,
            width: baseWidth * style.roadLineStyle.widthMultiplier,
            dash: style.roadLineStyle.dashPattern
        )
    }

    /// MKMapView throws on an out-of-range region, where SwiftUI's Map clamped it.
    private static func validated(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        let latitude = min(max(region.center.latitude, -85), 85)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: region.center.longitude),
            span: MKCoordinateSpan(
                latitudeDelta: min(region.span.latitudeDelta, 2 * (90 - abs(latitude))),
                longitudeDelta: min(region.span.longitudeDelta, 360)
            )
        )
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onCameraChange: ((MKCoordinateRegion) -> Void)?
        var onTap: ((CLLocationCoordinate2D) -> Void)?

        var appliedMapStyle: TravelMapView.MapStyleOption?
        var appliedContentKey: ContentKey?
        var appliedStyle: Style?
        var appliedColorScheme: ColorScheme?
        var appliedCameraRequest: CameraRequest?
        var appliedSelection: Set<String> = []
        var selection: [MKPolyline] = []
        var selectionGeneration = 0

        private struct Entry {
            let layer: Layer
            let overlay: MKMultiPolyline
        }
        private var entries: [Entry] = []
        private var cameraTouched = false

        /// White outline for contrast on any background, yellow highlight on top
        func selectionLayers() -> [Layer] {
            guard !selection.isEmpty else { return [] }
            return [
                Layer(key: "selected-outline|\(selectionGeneration)", polylines: selection, stroke: Stroke(color: .white, width: 9)),
                Layer(key: "selected|\(selectionGeneration)", polylines: selection, stroke: Stroke(color: .yellow, width: 7)),
            ]
        }

        /// Replaces only the overlays whose content or stroke changed, keeping the array's order.
        func reconcile(_ mapView: MKMapView, with layers: [Layer]) {
            let wanted = layers.filter { !$0.polylines.isEmpty }
            let next = wanted.map { layer in
                entries.first { $0.layer.key == layer.key && $0.layer.stroke == layer.stroke }
                    ?? Entry(layer: layer, overlay: MKMultiPolyline(layer.polylines))
            }
            let kept = Set(next.map { ObjectIdentifier($0.overlay) })
            let existing = Set(entries.map { ObjectIdentifier($0.overlay) })
            mapView.removeOverlays(entries.map(\.overlay).filter { !kept.contains(ObjectIdentifier($0)) })
            entries = next
            for (index, entry) in next.enumerated() where !existing.contains(ObjectIdentifier(entry.overlay)) {
                mapView.insertOverlay(entry.overlay, at: index)
            }
        }

        /// Matches SwiftUI's automatic camera: frame the lines until something else moves the map.
        func fitContentIfCameraUntouched(_ mapView: MKMapView) {
            guard !cameraTouched, appliedCameraRequest == nil, let first = entries.first else { return }
            let bounds = entries.dropFirst().reduce(first.overlay.boundingMapRect) { $0.union($1.overlay.boundingMapRect) }
            mapView.setVisibleMapRect(bounds, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: false)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let multi = overlay as? MKMultiPolyline,
                  let stroke = entries.first(where: { $0.overlay === multi })?.layer.stroke else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKMultiPolylineRenderer(multiPolyline: multi)
            renderer.strokeColor = stroke.color
            renderer.lineWidth = stroke.width
            renderer.lineCap = .round
            renderer.lineJoin = .round
            if !stroke.dash.isEmpty {
                renderer.lineDashPattern = stroke.dash.map { NSNumber(value: Double($0)) }
            }
            return renderer
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            onCameraChange?(mapView.region)
        }

        @objc func userMovedCamera() {
            cameraTouched = true
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            onTap?(mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

// MARK: - Location Manager

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var lastLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    /// A fix was asked for before permission was decided; fetch it once allowed
    private var wantsLocation = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    func requestLocation() {
        wantsLocation = true
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if wantsLocation, [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        wantsLocation = false
        lastLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Denied permission and a momentarily unknown fix are expected, not bugs
        if let code = (error as? CLError)?.code, code == .denied || code == .locationUnknown { return }
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
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Int(displayClinched.rounded()).formatted())
                        .font(.system(size: 19, weight: .heavy))
                        .monospacedDigit()
                    Text("\(unit) traveled")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TMDesign.tertiaryText)
                }
                if displayTotal > 0 {
                    Text("of \(Int(displayTotal.rounded()).formatted()) \(unit) · \(String(format: "%.1f", displayClinched / displayTotal * 100))%")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(TMDesign.tertiaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            VStack(alignment: .leading, spacing: 14) {
                // Header: icon tile + route title + Traveled badge (audit §6)
                HStack(spacing: 12) {
                    Image(systemName: detail.isRail ? "tram.fill" : "car.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(detail.isRail ? TMDesign.redChipFG : TMDesign.blueChipFG)
                        .frame(width: 44, height: 44)
                        .background(
                            detail.isRail ? TMDesign.redChipBG : TMDesign.blueChipBG,
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(detail.listName)
                            .font(.system(size: 20, weight: .heavy))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(detail.isRail ? "Rail & transit route" : "Road route")
                            .font(.system(size: 14))
                            .foregroundStyle(TMDesign.tertiaryText)
                    }

                    Spacer()

                    TMChip(
                        text: detail.isClinched ? "Traveled" : "Not yet",
                        icon: detail.isClinched ? "checkmark" : "circle.dashed",
                        bg: detail.isClinched ? TMDesign.greenChipBG : TMDesign.neutralChipBG,
                        fg: detail.isClinched ? TMDesign.greenChipFG : TMDesign.neutralChipFG,
                        fontSize: 13
                    )
                }
                .accessibilityElement(children: .combine)

                // Endpoints card: green dot → connector → red pin
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(TMDesign.clinched)
                            .frame(width: 10, height: 10)
                        Text(detail.startName)
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Rectangle()
                        .fill(TMDesign.hairline)
                        .frame(width: 2, height: 16)
                        .padding(.leading, 4)
                    HStack(spacing: 10) {
                        Image(systemName: "mappin")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TMDesign.rail)
                            .frame(width: 10)
                        Text(detail.endName)
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Segment from \(detail.startName) to \(detail.endName)")

                // Actions — primary Select whole route + square View-full-route
                if let onSelectAll {
                    HStack(spacing: 10) {
                        Button {
                            onSelectAll(detail.root)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Select whole route")
                                    .font(.system(size: 15, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(TMDesign.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Enters select mode with every segment on this route selected, ready to export")

                        NavigationLink {
                            RouteDetailView(
                                root: detail.root,
                                listName: detail.listName,
                                username: username,
                                isRail: detail.isRail
                            )
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(TMDesign.accent)
                                .frame(width: 50, height: 50)
                                .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View full route")
                    }
                } else {
                    NavigationLink {
                        RouteDetailView(
                            root: detail.root,
                            listName: detail.listName,
                            username: username,
                            isRail: detail.isRail
                        )
                    } label: {
                        Label("View full route", systemImage: "map")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(TMDesign.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if let onSelectClinched {
                    Button {
                        onSelectClinched(detail.root)
                    } label: {
                        Label("Select traveled segments only", systemImage: "checkmark.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TMDesign.greenChipFG)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(TMDesign.greenChipBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(TMDesign.secondarySurface)
            .navigationTitle("")
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
