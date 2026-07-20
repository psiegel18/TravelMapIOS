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
    @State private var hasReportedInitialDisplay = false
    @FocusState private var focusedField: PlannerField?
    @AppStorage("primaryUser") private var primaryUser = ""
    @ObservedObject private var settings = SyncedSettingsService.shared

    private enum PlannerField { case origin, destination }

    /// 1px border for unselected cards / secondary buttons (audit §5).
    private let cardBorder = Color(tmLight: 0xE6E6EC, dark: 0x3A3A3E)

    private var unit: String { settings.useMiles ? "mi" : "km" }

    /// Format a distance in meters using the user's unit preference.
    private func formatDistance(_ meters: Double, decimals: Int = 1) -> String {
        let value = settings.useMiles ? meters / 1609.34 : meters / 1000
        return String(format: "%.\(decimals)f %@", value, unit)
    }

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
            // Title + unified From/To card
            VStack(alignment: .leading, spacing: 12) {
                Text("Route Planner")
                    .font(.system(size: 28, weight: .heavy))
                    .kerning(-0.4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                fromToCard

                if isCalculating {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Finding routes…")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(TMDesign.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            // Route alternative cards (replaces the old chip selector + emoji summary row)
            if !routes.isEmpty {
                routeCards
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            // Map — inset rounded thumbnail; cards above carry the decision data
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
                            .stroke(seg.isClinched ? TMDesign.clinched : TMDesign.frontier, lineWidth: 4)
                    }

                    if let start = startCoordinate {
                        Marker("Start", coordinate: start).tint(TMDesign.clinched)
                    }
                    if let end = endCoordinate {
                        Marker("End", coordinate: end).tint(TMDesign.rail)
                    }
                }
                .onMapCameraChange { context in
                    visibleRegion = context.region
                }

                // Map controls
                VStack(spacing: 8) {
                    // Zoom buttons — 44pt minimum targets (audit §15)
                    Button {
                        adjustZoom(factor: 0.5)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zoom in")

                    Button {
                        adjustZoom(factor: 2.0)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zoom out")

                    // Legend — real labels, no 9pt type (audit §5)
                    VStack(alignment: .leading, spacing: 5) {
                        legendLine(color: TMDesign.frontier, label: "New")
                        legendLine(color: TMDesign.clinched, label: "Driven")
                        legendLine(color: .gray.opacity(0.5), label: "Route")
                    }
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Legend: amber is new, green is driven, gray is the route")
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(minHeight: 160)

            // Error + primary action row
            if selectedRoute != nil || errorMessage != nil {
                bottomActionBar
            }
        }
        .background(TMDesign.secondarySurface.ignoresSafeArea())
        .navigationTitle("Route Planner")
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showDirections) {
            directionsSheet
        }
        .task {
            // The traced view uses waitForFullDisplay, so every visit must eventually
            // report. In the default (no search pending) state the view is already
            // fully displayed on appear; route calculation reports its own completion.
            if !hasReportedInitialDisplay && !isCalculating {
                hasReportedInitialDisplay = true
                SentrySDK.reportFullyDisplayed()
            }
        }
    }

    // MARK: - From/To Card

    /// Unified From/To card: two rows split by a hairline, trailing swap control (audit §5).
    private var fromToCard: some View {
        HStack(spacing: 8) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(TMDesign.clinched)
                        .frame(width: 11, height: 11)
                        .accessibilityHidden(true)
                    TextField("Start location", text: $startQuery)
                        .font(.system(size: 16, weight: .semibold))
                        .focused($focusedField, equals: .origin)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .destination }
                        .accessibilityLabel("Start location")
                }
                .padding(.vertical, 13)

                Rectangle()
                    .fill(TMDesign.hairline)
                    .frame(height: 1)

                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TMDesign.rail)
                        .frame(width: 11)
                        .accessibilityHidden(true)
                    TextField("End location", text: $endQuery)
                        .font(.system(size: 16, weight: .semibold))
                        .focused($focusedField, equals: .destination)
                        .submitLabel(.search)
                        .onSubmit {
                            Task { await calculateRoute() }
                        }
                        .accessibilityLabel("End location")
                }
                .padding(.vertical, 13)
            }

            Button {
                swapEndpoints()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(TMDesign.tertiaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(startQuery.isEmpty && endQuery.isEmpty)
            .accessibilityLabel("Swap start and end")
            .accessibilityHint("Reverses the route direction")
        }
        .padding(.horizontal, 14)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    /// Swap origin/destination (text and resolved coordinates) and re-search if a
    /// route is already on screen.
    private func swapEndpoints() {
        Haptics.light()
        swap(&startQuery, &endQuery)
        let tmp = startCoordinate
        startCoordinate = endCoordinate
        endCoordinate = tmp
        if !routes.isEmpty && !startQuery.isEmpty && !endQuery.isEmpty {
            Task { await calculateRoute() }
        }
    }

    private func legendLine(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 18, height: 4)
            Text(label).font(.system(size: 14, weight: .semibold))
        }
    }

    // MARK: - Route Cards

    private var fastestRouteIndex: Int? {
        routes.indices.min(by: { routes[$0].expectedTravelTime < routes[$1].expectedTravelTime })
    }

    /// The alternative with the most new-to-clinch segments — worth flagging (audit §5).
    private var mostNewRouteIndex: Int? {
        guard routes.count > 1 else { return nil }
        let counts = routes.indices.map { idx in
            (routeSegments[idx] ?? []).filter { !$0.isClinched }.count
        }
        guard let maxCount = counts.max(), maxCount > 0 else { return nil }
        return counts.firstIndex(of: maxCount)
    }

    private var routeCards: some View {
        Group {
            if routes.count > 2 {
                ScrollView(showsIndicators: false) { routeCardsStack }
                    .frame(maxHeight: 208)
            } else {
                routeCardsStack
            }
        }
    }

    private var routeCardsStack: some View {
        VStack(spacing: 8) {
            ForEach(Array(routes.enumerated()), id: \.offset) { index, rt in
                routeCard(index: index, route: rt)
            }
        }
    }

    private func routeCard(index: Int, route rt: MKRoute) -> some View {
        let segs = routeSegments[index] ?? []
        let newSegs = segs.filter { !$0.isClinched }.count
        let drivenSegs = segs.count - newSegs
        let isSelected = index == selectedRouteIndex

        return Button {
            Haptics.selection()
            selectedRouteIndex = index
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text("Route \(index + 1)")
                        .font(.system(size: 17, weight: .heavy))
                    Text("· \(formatDistance(rt.distance, decimals: 0)) · \(formatTime(rt.expectedTravelTime))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TMDesign.tertiaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if index == fastestRouteIndex {
                        TMChip(text: "Fastest", bg: TMDesign.accent, fg: .white)
                    }
                    if index == mostNewRouteIndex {
                        TMChip(text: "+\(newSegs.formatted()) new", bg: TMDesign.amberChipBG, fg: TMDesign.amberChipFG)
                    }
                }

                if isLoadingSegments && segs.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Matching TM routes…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TMDesign.tertiaryText)
                    }
                } else if !segs.isEmpty {
                    HStack(spacing: 8) {
                        routeStatChip(
                            dot: TMDesign.frontier,
                            text: "\(newSegs.formatted()) new to clinch",
                            bg: TMDesign.amberChipBG,
                            fg: TMDesign.amberChipFG
                        )
                        routeStatChip(
                            dot: TMDesign.clinched,
                            text: "\(drivenSegs.formatted()) driven",
                            bg: TMDesign.greenChipBG,
                            fg: TMDesign.greenChipFG
                        )
                    }
                } else {
                    Text("No TM routes along this option")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TMDesign.tertiaryText)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? TMDesign.accent : cardBorder, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Dot + word chip — new/driven never rides on color alone (audit §5).
    private func routeStatChip(dot: Color, text: String, bg: Color, fg: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 9, height: 9)
            Text(text)
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .foregroundStyle(fg)
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        VStack(spacing: 8) {
            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TMDesign.redChipFG)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(TMDesign.redChipBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if selectedRoute != nil {
                HStack(spacing: 10) {
                    // Primary: Navigate (Apple/Google chooser, unchanged behavior)
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
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Navigate")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(TMDesign.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Navigate")
                        .accessibilityHint("Opens this route in Apple Maps or Google Maps")
                    }

                    // Secondary: turn-by-turn directions list
                    Button {
                        Haptics.light()
                        showDirections = true
                    } label: {
                        squareSecondaryIcon("list.number")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Turn-by-turn directions")

                    // Secondary: share
                    ShareLink(item: generateDirectionsText()) {
                        squareSecondaryIcon("square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share directions")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func squareSecondaryIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(TMDesign.accent)
            .frame(width: 50, height: 50)
            .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(cardBorder, lineWidth: 1)
            )
    }

    // MARK: - Directions Sheet

    private var directionsSheet: some View {
        NavigationStack {
            List {
                if let route = selectedRoute {
                    // Summary section
                    Section {
                        HStack {
                            Label(formatDistance(route.distance), systemImage: "road.lanes")
                            Spacer()
                            Label(formatTime(route.expectedTravelTime), systemImage: "clock")
                        }
                        .font(.subheadline)
                        .monospacedDigit()

                        if !tmSegments.isEmpty {
                            let clinched = tmSegments.filter(\.isClinched).count
                            let newCount = tmSegments.count - clinched
                            HStack {
                                Label("\(tmSegments.count.formatted()) TM segments", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                Spacer()
                                if !primaryUser.isEmpty {
                                    Text("\(newCount.formatted()) new")
                                        .foregroundStyle(TMDesign.amberChipFG)
                                }
                            }
                            .font(.subheadline)
                            .monospacedDigit()
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
                                            .font(.system(size: 15, weight: .bold))
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                            .frame(width: 26, alignment: .trailing)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(step.instructions)
                                                .font(.subheadline)
                                            if step.distance > 0 {
                                                Text(formatDistance(step.distance))
                                                    .font(.system(size: 15))
                                                    .monospacedDigit()
                                                    .foregroundStyle(.secondary)
                                            }
                                            if let notice = step.notice, !notice.isEmpty {
                                                Text(notice)
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(TMDesign.amberChipFG)
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
                                                Label("\(newSegs.formatted()) new", systemImage: "road.lanes")
                                                    .font(.system(size: 13, weight: .medium))
                                                    .monospacedDigit()
                                                    .foregroundStyle(TMDesign.amberChipFG)
                                            }
                                            if clinchedSegs > 0 {
                                                Label("\(clinchedSegs.formatted()) traveled", systemImage: "checkmark.circle")
                                                    .font(.system(size: 13, weight: .medium))
                                                    .monospacedDigit()
                                                    .foregroundStyle(TMDesign.greenChipFG)
                                            }
                                        }
                                        .padding(.leading, 30)
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
        lines.append("Distance: \(formatDistance(route.distance)) | Time: \(formatTime(route.expectedTravelTime))")

        let clinched = tmSegments.filter(\.isClinched).count
        let newCount = tmSegments.count - clinched
        if !tmSegments.isEmpty {
            lines.append("TM Segments: \(tmSegments.count) (\(newCount) new, \(clinched) already traveled)")
        }
        lines.append("")
        lines.append("DRIVING DIRECTIONS")
        lines.append("")

        for (index, step) in route.steps.enumerated() where !step.instructions.isEmpty {
            let dist = step.distance > 0 ? " — \(formatDistance(step.distance))" : ""
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
        // Submit-triggered (no Find Route button): ignore empty or re-entrant requests.
        // Early return touches no state, so the reportFullyDisplayed contract is unaffected.
        guard !isCalculating, !startQuery.isEmpty, !endQuery.isEmpty else { return }
        focusedField = nil
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
                SentrySDK.reportFullyDisplayed()
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
            // Every visit must eventually report full display (waitForFullDisplay: true),
            // including the failure path.
            SentrySDK.reportFullyDisplayed()
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
