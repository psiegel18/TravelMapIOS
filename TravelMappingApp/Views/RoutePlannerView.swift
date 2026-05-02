import SwiftUI
import MapKit
import LinkPresentation
import Sentry
import SentrySwiftUI

struct RoutePlannerView: View {
    @State private var startQuery = ""
    @State private var endQuery = ""
    @State private var startCoordinate: CLLocationCoordinate2D?
    @State private var endCoordinate: CLLocationCoordinate2D?
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var routes: [MKRoute] = []
    @State private var selectedRouteIndex = 0
    @State private var routeSegments: [Int: [TravelMappingAPI.MapSegment]] = [:] // route index → segments
    @State private var isCalculating = false
    @State private var isLoadingSegments = false
    @State private var errorMessage: String?
    @State private var showDirections = false
    @AppStorage("primaryUser") private var primaryUser = ""

    private var selectedRoute: MKRoute? {
        guard selectedRouteIndex < routes.count else { return nil }
        return routes[selectedRouteIndex]
    }

    private var tmSegments: [TravelMappingAPI.MapSegment] {
        routeSegments[selectedRouteIndex] ?? []
    }

    var body: some View {
        SentryTracedView("RoutePlannerView", waitForFullDisplay: true) {
            bodyContent
        }
    }

    private var bodyContent: some View {
        VStack(spacing: 0) {
            // Input fields
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "circle.fill").foregroundStyle(.green).font(.caption)
                    TextField("Start location", text: $startQuery)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.next)
                }
                HStack {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(.red).font(.caption)
                    TextField("End location", text: $endQuery)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit {
                            Task { await calculateRoute() }
                        }
                }

                Button {
                    Haptics.light()
                    Task { await calculateRoute() }
                } label: {
                    if isCalculating {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Find Route", systemImage: "arrow.triangle.turn.up.right.diamond")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(startQuery.isEmpty || endQuery.isEmpty || isCalculating)
            }
            .padding()

            // Route selector pills (when multiple routes available)
            if routes.count > 1 {
                routeSelector
            }

            // Map
            ZStack(alignment: .topTrailing) {
                Map(position: $mapPosition) {
                    // All routes (non-selected faded)
                    ForEach(Array(routes.enumerated()), id: \.offset) { index, rt in
                        MapPolyline(rt.polyline)
                            .stroke(
                                index == selectedRouteIndex ? Color.gray.opacity(0.5) : Color.gray.opacity(0.2),
                                lineWidth: index == selectedRouteIndex ? 5 : 3
                            )
                    }

                    // TM segments for selected route
                    ForEach(tmSegments) { seg in
                        MapPolyline(coordinates: [seg.start, seg.end])
                            .stroke(seg.isClinched ? .green : .orange, lineWidth: 4)
                    }

                    if let start = startCoordinate {
                        Marker("Start", coordinate: start).tint(.green)
                    }
                    if let end = endCoordinate {
                        Marker("End", coordinate: end).tint(.red)
                    }
                }
                .onMapCameraChange { context in
                    visibleRegion = context.region
                }

                // Map controls
                VStack(spacing: 6) {
                    // Zoom buttons
                    Button {
                        adjustZoom(factor: 0.5)
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption.bold())
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        adjustZoom(factor: 2.0)
                    } label: {
                        Image(systemName: "minus")
                            .font(.caption.bold())
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    // Legend
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1).fill(.orange).frame(width: 14, height: 3)
                            Text("New").font(.system(size: 9))
                        }
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1).fill(.green).frame(width: 14, height: 3)
                            Text("Driven").font(.system(size: 9))
                        }
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1).fill(.gray.opacity(0.5)).frame(width: 14, height: 3)
                            Text("Route").font(.system(size: 9))
                        }
                    }
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(8)
            }

            // Results summary
            if selectedRoute != nil || errorMessage != nil {
                resultsView
            }
        }
        .navigationTitle("Route Planner")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDirections) {
            directionsSheet
        }
    }

    // MARK: - Route Selector

    private var routeSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(routes.enumerated()), id: \.offset) { index, rt in
                    let segs = routeSegments[index] ?? []
                    let newSegs = segs.filter { !$0.isClinched }.count
                    let drivenSegs = segs.filter(\.isClinched).count
                    let isSelected = index == selectedRouteIndex
                    Button {
                        Haptics.selection()
                        selectedRouteIndex = index
                    } label: {
                        VStack(spacing: 3) {
                            Text("Route \(index + 1)")
                                .font(.caption2.bold())
                            Text(String(format: "%.0f mi · %@", rt.distance / 1609.34, formatTime(rt.expectedTravelTime)))
                                .font(.caption2)
                            if isLoadingSegments && segs.isEmpty {
                                ProgressView()
                                    .controlSize(.mini)
                            } else if !segs.isEmpty {
                                HStack(spacing: 6) {
                                    if newSegs > 0 {
                                        HStack(spacing: 2) {
                                            Circle().fill(.orange).frame(width: 6, height: 6)
                                            Text("\(newSegs) new")
                                                .font(.caption2.bold())
                                                .foregroundStyle(isSelected ? .white : .orange)
                                        }
                                    }
                                    if drivenSegs > 0 {
                                        HStack(spacing: 2) {
                                            Circle().fill(.green).frame(width: 6, height: 6)
                                            Text("\(drivenSegs) driven")
                                                .font(.caption2)
                                                .foregroundStyle(isSelected ? .white.opacity(0.8) : .green)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            isSelected ? Color.blue : Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Results View

    private var resultsView: some View {
        VStack(spacing: 6) {
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let route = selectedRoute {
                // Route stats
                HStack {
                    Label(String(format: "%.1f mi", route.distance / 1609.34), systemImage: "road.lanes")
                    Spacer()
                    Label(formatTime(route.expectedTravelTime), systemImage: "clock")
                    Spacer()
                    if isLoadingSegments && tmSegments.isEmpty {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Loading TM segs...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label("\(tmSegments.count.formatted()) TM segs", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                }
                .font(.caption)

                if !tmSegments.isEmpty && !primaryUser.isEmpty {
                    let clinched = tmSegments.filter(\.isClinched).count
                    let newCount = tmSegments.count - clinched
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Circle().fill(.orange).frame(width: 8, height: 8)
                            Text("\(newCount.formatted()) new to clinch")
                        }
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("\(clinched.formatted()) already driven")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                // Action buttons
                HStack(spacing: 8) {
                    // Directions
                    Button {
                        Haptics.light()
                        showDirections = true
                    } label: {
                        Label("Directions", systemImage: "list.number")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)

                    // Open in Maps
                    if let start = startCoordinate, let end = endCoordinate {
                        Menu {
                            Button {
                                openInAppleMaps(start: start, end: end)
                            } label: {
                                Label("Apple Maps", systemImage: "map.fill")
                            }
                            Button {
                                openInGoogleMaps(start: start, end: end)
                            } label: {
                                Label("Google Maps", systemImage: "arrow.up.forward.app")
                            }
                        } label: {
                            Label("Navigate", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                    }

                    // Share
                    ShareLink(item: generateDirectionsText()) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption.bold())
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 2)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - Directions Sheet

    private var directionsSheet: some View {
        NavigationStack {
            List {
                if let route = selectedRoute {
                    // Summary section
                    Section {
                        HStack {
                            Label(String(format: "%.1f mi", route.distance / 1609.34), systemImage: "road.lanes")
                            Spacer()
                            Label(formatTime(route.expectedTravelTime), systemImage: "clock")
                        }
                        .font(.subheadline)

                        if !tmSegments.isEmpty {
                            let clinched = tmSegments.filter(\.isClinched).count
                            let newCount = tmSegments.count - clinched
                            HStack {
                                Label("\(tmSegments.count) TM segments", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                Spacer()
                                if !primaryUser.isEmpty {
                                    Text("\(newCount) new")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.subheadline)
                        }
                    } header: {
                        Text("\(startQuery) → \(endQuery)")
                    }

                    // Turn-by-turn directions
                    Section {
                        ForEach(Array(route.steps.enumerated()), id: \.offset) { index, step in
                            if !step.instructions.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .top) {
                                        Text("\(index + 1).")
                                            .font(.caption.bold())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24, alignment: .trailing)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(step.instructions)
                                                .font(.subheadline)
                                            if step.distance > 0 {
                                                Text(String(format: "%.1f mi", step.distance / 1609.34))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if let notice = step.notice, !notice.isEmpty {
                                                Text(notice)
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                    }

                                    // Show TM segments near this step
                                    let stepSegs = segmentsForStep(step)
                                    if !stepSegs.isEmpty {
                                        let newSegs = stepSegs.filter { !$0.isClinched }.count
                                        let clinchedSegs = stepSegs.filter(\.isClinched).count
                                        HStack(spacing: 8) {
                                            if newSegs > 0 {
                                                Label("\(newSegs) new", systemImage: "road.lanes")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                            }
                                            if clinchedSegs > 0 {
                                                Label("\(clinchedSegs) traveled", systemImage: "checkmark.circle")
                                                    .font(.caption2)
                                                    .foregroundStyle(.green)
                                            }
                                        }
                                        .padding(.leading, 28)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } header: {
                        Text("Driving Directions")
                    }
                }
            }
            .navigationTitle("Directions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showDirections = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Haptics.success()
                            UIPasteboard.general.string = generateDirectionsText()
                        } label: {
                            Label("Copy Directions", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: generateDirectionsText()) {
                            Label("Share Directions", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            sendDirectionsToWatch()
                        } label: {
                            Label("Send to Watch", systemImage: "applewatch")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func adjustZoom(factor: Double) {
        guard let currentRegion = visibleRegion else { return }
        let center = currentRegion.center
        let newLatDelta = min(max(currentRegion.span.latitudeDelta * factor, 0.001), 180)
        let newLngDelta = min(max(currentRegion.span.longitudeDelta * factor, 0.001), 360)
        withAnimation {
            mapPosition = .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: newLatDelta, longitudeDelta: newLngDelta)
            ))
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// Find which TM segments are near a specific route step. Synchronous because each
    /// step's polyline is short (~1km, dozens of points), so the filter is cheap here.
    private func segmentsForStep(_ step: MKRoute.Step) -> [TravelMappingAPI.MapSegment] {
        let polyline = step.polyline
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        let pts = polyline.points()
        let coords = (0..<count).map { pts[$0].coordinate }
        return Self.filterSegmentsNearRoute(
            segments: tmSegments,
            routeCoords: coords,
            routeRect: polyline.boundingMapRect
        )
    }

    /// Generate formatted directions text for sharing
    private func sendDirectionsToWatch() {
        guard let route = selectedRoute else { return }
        let steps = route.steps.compactMap { step -> (instruction: String, distance: Double, notice: String?)? in
            guard !step.instructions.isEmpty else { return nil }
            return (instruction: step.instructions, distance: step.distance, notice: step.notice)
        }
        WatchSyncService.shared.sendDirections(
            routeName: "\(startQuery) → \(endQuery)",
            totalDistance: route.distance,
            totalTime: route.expectedTravelTime,
            steps: steps
        )
        Haptics.success()
    }

    private func generateDirectionsText() -> String {
        guard let route = selectedRoute else { return "" }
        var lines: [String] = []

        lines.append("Route: \(startQuery) → \(endQuery)")
        lines.append(String(format: "Distance: %.1f mi | Time: %@", route.distance / 1609.34, formatTime(route.expectedTravelTime)))

        let clinched = tmSegments.filter(\.isClinched).count
        let newCount = tmSegments.count - clinched
        if !tmSegments.isEmpty {
            lines.append("TM Segments: \(tmSegments.count) (\(newCount) new, \(clinched) already traveled)")
        }
        lines.append("")
        lines.append("DRIVING DIRECTIONS")
        lines.append("")

        for (index, step) in route.steps.enumerated() where !step.instructions.isEmpty {
            let dist = step.distance > 0 ? String(format: " — %.1f mi", step.distance / 1609.34) : ""
            lines.append("\(index + 1). \(step.instructions)\(dist)")

            let stepSegs = segmentsForStep(step)
            if !stepSegs.isEmpty {
                let roots = Set(stepSegs.map(\.root))
                let rootNames = roots.prefix(3).joined(separator: ", ")
                let suffix = roots.count > 3 ? " +\(roots.count - 3) more" : ""
                lines.append("   → TM: \(rootNames)\(suffix) (\(stepSegs.count) segments)")
            }
        }

        lines.append("")
        lines.append("Generated by Travel Mapping iOS App")
        lines.append("travelmapping.net")
        return lines.joined(separator: "\n")
    }

    // MARK: - Route Calculation

    private func calculateRoute() async {
        isCalculating = true
        errorMessage = nil
        routes = []
        routeSegments = [:]
        selectedRouteIndex = 0
        isLoadingSegments = false

        do {
            let startItems = try await MKLocalSearch(request: searchRequest(for: startQuery)).start()
            let endItems = try await MKLocalSearch(request: searchRequest(for: endQuery)).start()

            guard let start = startItems.mapItems.first?.placemark.coordinate,
                  let end = endItems.mapItems.first?.placemark.coordinate else {
                errorMessage = "Could not find one of the locations"
                isCalculating = false
                return
            }

            startCoordinate = start
            endCoordinate = end

            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
            request.transportType = .automobile
            request.requestsAlternateRoutes = true

            let directions = MKDirections(request: request)
            let response = try await directions.calculate()
            routes = response.routes
            isCalculating = false // Show routes + map immediately

            // Load TM segments in background — UI is interactive during this
            isLoadingSegments = true
            await withTaskGroup(of: (Int, [TravelMappingAPI.MapSegment]).self) { group in
                for (index, rt) in routes.enumerated() {
                    group.addTask {
                        let segs = await self.findOverlappingSegments(for: rt)
                        return (index, segs)
                    }
                }
                for await (index, segs) in group {
                    routeSegments[index] = segs
                }
            }
            isLoadingSegments = false
            SentrySDK.reportFullyDisplayed()
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
            isCalculating = false
        }
    }

    private func searchRequest(for query: String) -> MKLocalSearch.Request {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        return request
    }

    // MARK: - TM Segment Loading

    private func findOverlappingSegments(for route: MKRoute) async -> [TravelMappingAPI.MapSegment] {
        let polyline = route.polyline
        let rect = polyline.boundingMapRect
        let topLeft = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
        let bottomRight = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate

        let minLat = min(topLeft.latitude, bottomRight.latitude) - 0.1
        let maxLat = max(topLeft.latitude, bottomRight.latitude) + 0.1
        let minLng = min(topLeft.longitude, bottomRight.longitude) - 0.1
        let maxLng = max(topLeft.longitude, bottomRight.longitude) + 0.1

        // Snapshot the polyline's coordinates on the main actor so the heavy filter can
        // run on a background task. MKPolyline isn't Sendable; coordinate arrays are.
        let polylineCoords: [CLLocationCoordinate2D] = {
            let pts = polyline.points()
            let count = polyline.pointCount
            return (0..<count).map { pts[$0].coordinate }
        }()
        let polylineRect = polyline.boundingMapRect

        let traveler = primaryUser.isEmpty ? "" : primaryUser
        let tileSize = 2.0
        var allSegments: [TravelMappingAPI.MapSegment] = []

        await withTaskGroup(of: [TravelMappingAPI.MapSegment].self) { group in
            var lat = minLat
            while lat < maxLat {
                var lng = minLng
                while lng < maxLng {
                    let tileLat = lat
                    let tileLng = lng
                    let tileMaxLat = min(lat + tileSize, maxLat)
                    let tileMaxLng = min(lng + tileSize, maxLng)

                    group.addTask {
                        guard let result = try? await TravelMappingAPI.shared.getVisibleSegments(
                            traveler: traveler,
                            minLat: tileLat,
                            maxLat: tileMaxLat,
                            minLng: tileLng,
                            maxLng: tileMaxLng
                        ) else { return [] }
                        return result.segments
                    }
                    lng += tileSize
                }
                lat += tileSize
            }
            for await segments in group {
                allSegments.append(contentsOf: segments)
            }
        }

        // Run the geometry filter off the main thread — for long routes this is the
        // operation that used to hang the app for 10+ seconds.
        return await Task.detached(priority: .userInitiated) {
            Self.filterSegmentsNearRoute(
                segments: allSegments,
                routeCoords: polylineCoords,
                routeRect: polylineRect
            )
        }.value
    }

    /// Returns segments whose midpoint is within ~500m of any (sampled) point along the route.
    /// Uses a bounding-box pre-filter and equirectangular distance to avoid CLLocation
    /// allocations and Haversine calls. `nonisolated` so the Task.detached caller in
    /// findOverlappingSegments can run it off the main thread (Swift 6 concurrency).
    private nonisolated static func filterSegmentsNearRoute(
        segments: [TravelMappingAPI.MapSegment],
        routeCoords: [CLLocationCoordinate2D],
        routeRect: MKMapRect
    ) -> [TravelMappingAPI.MapSegment] {
        let pointCount = routeCoords.count
        guard pointCount > 0 else { return [] }

        // Sample down to ~200 points — a 500m threshold doesn't need every point on a
        // route polyline that may have thousands.
        let stride = max(1, pointCount / 200)
        let thresholdMeters: Double = 500
        let thresholdSq = thresholdMeters * thresholdMeters

        return segments.filter { seg in
            let midLat = (seg.start.latitude + seg.end.latitude) / 2
            let midLng = (seg.start.longitude + seg.end.longitude) / 2

            // Cheap bounding-box reject before the per-point loop.
            let mppm = MKMapPointsPerMeterAtLatitude(midLat)
            let inflated = routeRect.insetBy(
                dx: -thresholdMeters * mppm,
                dy: -thresholdMeters * mppm
            )
            let midMapPoint = MKMapPoint(CLLocationCoordinate2D(latitude: midLat, longitude: midLng))
            guard inflated.contains(midMapPoint) else { return false }

            let cosLat = cos(midLat * .pi / 180)
            var i = 0
            while i < pointCount {
                let c = routeCoords[i]
                let dLat = (c.latitude - midLat) * 111_320
                let dLng = (c.longitude - midLng) * 111_320 * cosLat
                if dLat * dLat + dLng * dLng < thresholdSq {
                    return true
                }
                i += stride
            }
            return false
        }
    }

    // MARK: - Navigation App Export

    /// Extract waypoints every ~50 miles along the route polyline
    private func extractWaypoints(from route: MKRoute, maxCount: Int = 10) -> [CLLocationCoordinate2D] {
        let polyline = route.polyline
        let points = polyline.points()
        let count = polyline.pointCount
        guard count > 2 else { return [] }

        let totalDistance = route.distance // meters
        let interval = totalDistance / Double(maxCount + 1)
        var waypoints: [CLLocationCoordinate2D] = []
        var accumulated: Double = 0

        for i in 1..<count {
            let prev = CLLocation(latitude: points[i-1].coordinate.latitude, longitude: points[i-1].coordinate.longitude)
            let curr = CLLocation(latitude: points[i].coordinate.latitude, longitude: points[i].coordinate.longitude)
            accumulated += curr.distance(from: prev)

            if accumulated >= interval {
                waypoints.append(points[i].coordinate)
                accumulated = 0
                if waypoints.count >= maxCount { break }
            }
        }
        return waypoints
    }

    private func openInAppleMaps(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D) {
        var items: [MKMapItem] = []

        let source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        source.name = startQuery
        items.append(source)

        // Add waypoints to guide the route
        if let route = selectedRoute {
            for wp in extractWaypoints(from: route) {
                items.append(MKMapItem(placemark: MKPlacemark(coordinate: wp)))
            }
        }

        let destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        destination.name = endQuery
        items.append(destination)

        MKMapItem.openMaps(with: items, launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    private func openInGoogleMaps(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D) {
        var urlString = "comgooglemaps://?saddr=\(start.latitude),\(start.longitude)&daddr=\(end.latitude),\(end.longitude)&directionsmode=driving"

        // Add waypoints
        if let route = selectedRoute {
            let wps = extractWaypoints(from: route, maxCount: 8) // Google Maps limit
            if !wps.isEmpty {
                let wpString = wps.map { "\($0.latitude),\($0.longitude)" }.joined(separator: "|")
                urlString += "&waypoints=\(wpString)"
            }
        }

        if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            var webURL = "https://www.google.com/maps/dir/?api=1&origin=\(start.latitude),\(start.longitude)&destination=\(end.latitude),\(end.longitude)&travelmode=driving"
            if let route = selectedRoute {
                let wps = extractWaypoints(from: route, maxCount: 8)
                if !wps.isEmpty {
                    let wpString = wps.map { "\($0.latitude),\($0.longitude)" }.joined(separator: "%7C")
                    webURL += "&waypoints=\(wpString)"
                }
            }
            if let url = URL(string: webURL) {
                UIApplication.shared.open(url)
            }
        }
    }
}
