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
    @State private var routeSegments: [Int: RouteMatchResult] = [:] // route index → matched TM segments
    @State private var searchTask: Task<Void, Never>?
    @State private var isCalculating = false
    @State private var isLoadingSegments = false
    @State private var errorMessage: String?
    @State private var showDirections = false
    @State private var showFullMap = false
    @State private var watchMessage: String?
    @State private var hasReportedInitialDisplay = false
    @FocusState private var focusedField: PlannerField?
    @StateObject private var locationManager = LocationManager()
    @StateObject private var completer = AddressCompleter()
    /// Suggestions the user picked, kept so the search resolves exactly that place.
    /// Cleared as soon as the field's text no longer matches the pick.
    @State private var startCompletion: MKLocalSearchCompletion?
    @State private var endCompletion: MKLocalSearchCompletion?
    @AppStorage("primaryUser") private var primaryUser = ""
    @ObservedObject private var settings = SyncedSettingsService.shared

    private enum PlannerField { case origin, destination }

    /// Typed into an endpoint field to mean the device's location instead of a search
    private static let currentLocationLabel = "Current Location"

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
        routeSegments[selectedRouteIndex]?.segments ?? []
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

                if let field = focusedField, showingSuggestions {
                    suggestionList(for: field)
                        .sentryReplayMask()
                }

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

            // Suggestions take this space while typing (the keyboard covers it anyway);
            // keeping both overflows the screen and pushes the title under the status bar
            if showingSuggestions {
                Spacer(minLength: 0)
            } else {
            // Route alternative cards (replaces the old chip selector + emoji summary row)
            if !routes.isEmpty {
                routeCards
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            // Map — inset rounded thumbnail; cards above carry the decision data
            ZStack(alignment: .topTrailing) {
                Map(position: $mapPosition) {
                    plannerMapContent
                }
                .onMapCameraChange { context in
                    visibleRegion = context.region
                }
                // Replays never show where the user is planning from or to
                .sentryReplayMask()

                // Map controls
                VStack(spacing: 8) {
                    Button {
                        Haptics.light()
                        showFullMap = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Full-screen map")

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
        }
        .background(TMDesign.secondarySurface.ignoresSafeArea())
        // Let the keyboard cover the map instead of pushing the title under the status bar
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle("Route Planner")
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showDirections) {
            directionsSheet
        }
        .fullScreenCover(isPresented: $showFullMap) {
            fullScreenMap
        }
        .onChange(of: startQuery) { updateSuggestions(for: .origin) }
        .onChange(of: endQuery) { updateSuggestions(for: .destination) }
        .onChange(of: focusedField) { _, field in
            if let field { updateSuggestions(for: field) } else { completer.clear() }
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

    // MARK: - Map

    /// Shared by the inline map and the full-screen map
    @MapContentBuilder
    private var plannerMapContent: some MapContent {
        // All routes (non-selected faded)
        ForEach(Array(routes.enumerated()), id: \.offset) { index, rt in
            MapPolyline(rt.polyline)
                .stroke(
                    index == selectedRouteIndex ? Color.gray.opacity(0.5) : Color.gray.opacity(0.2),
                    lineWidth: index == selectedRouteIndex ? 5 : 3
                )
        }

        // TM segments on the selected route, drawn along the route line itself and merged
        // into runs of the same status (hundreds of 2-point lines → a few dozen)
        ForEach(routeSegments[selectedRouteIndex]?.lines ?? []) { line in
            MapPolyline(coordinates: line.coords)
                .stroke(line.isClinched ? TMDesign.clinched : TMDesign.frontier, lineWidth: 4)
        }

        if let start = startCoordinate {
            Marker("Start", coordinate: start).tint(TMDesign.clinched)
        }
        if let end = endCoordinate {
            Marker("End", coordinate: end).tint(TMDesign.rail)
        }
    }

    private var fullScreenMap: some View {
        ZStack(alignment: .bottomLeading) {
            Map(initialPosition: selectedRoute.map { .rect($0.polyline.boundingMapRect.insetBy(dx: -$0.polyline.boundingMapRect.width * 0.08, dy: -$0.polyline.boundingMapRect.height * 0.08)) } ?? mapPosition) {
                plannerMapContent
                UserAnnotation()
            }
            .sentryReplayMask()
            .mapControls {
                MapCompass()
                MapScaleView()
                MapUserLocationButton()
                MapPitchToggle()
            }
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 5) {
                legendLine(color: TMDesign.frontier, label: "New")
                legendLine(color: TMDesign.clinched, label: "Driven")
                legendLine(color: .gray.opacity(0.5), label: "Route")
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(16)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Legend: amber is new, green is driven, gray is the route")
        }
        .overlay(alignment: .topLeading) {
            Button {
                showFullMap = false
            } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
        }
        .sentryScreen("RoutePlannerFullMap")
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
                        .sentryReplayMask()
                    // Only one end can be "here"
                    if startQuery != Self.currentLocationLabel && endQuery != Self.currentLocationLabel {
                        currentLocationButton(for: .origin)
                    }
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
                            startSearch()
                        }
                        .accessibilityLabel("End location")
                        .sentryReplayMask()
                    if endQuery != Self.currentLocationLabel && startQuery != Self.currentLocationLabel {
                        currentLocationButton(for: .destination)
                    }
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

    private func currentLocationButton(for field: PlannerField) -> some View {
        Button {
            useCurrentLocation(for: field)
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(field == .origin ? "Use current location as start" : "Use current location as end")
    }

    private func useCurrentLocation(for field: PlannerField) {
        Haptics.light()
        if field == .origin { startQuery = Self.currentLocationLabel } else { endQuery = Self.currentLocationLabel }
        locationManager.lastLocation = nil  // don't route from where the phone was earlier
        locationManager.requestLocation()   // asks for When In Use the first time
        let other = field == .origin ? endQuery : startQuery
        focusedField = other.isEmpty ? (field == .origin ? .destination : .origin) : nil
        if !other.isEmpty {
            startSearch()
        }
    }

    // MARK: - Suggestions

    private var showingSuggestions: Bool { focusedField != nil && !completer.results.isEmpty }

    private func updateSuggestions(for field: PlannerField) {
        let text = field == .origin ? startQuery : endQuery
        let picked = field == .origin ? startCompletion : endCompletion
        if let picked, Self.label(for: picked) != text {
            if field == .origin { startCompletion = nil } else { endCompletion = nil }
        }
        guard focusedField == field, text != Self.currentLocationLabel,
              (field == .origin ? startCompletion : endCompletion) == nil else {
            completer.clear()
            return
        }
        // Nearby places first: around the user if known, else what the map shows
        if let here = locationManager.lastLocation?.coordinate {
            completer.region = MKCoordinateRegion(center: here, latitudinalMeters: 200_000, longitudinalMeters: 200_000)
        } else if let visibleRegion {
            completer.region = visibleRegion
        }
        completer.update(query: text)
    }

    private static func label(for completion: MKLocalSearchCompletion) -> String {
        completion.subtitle.isEmpty ? completion.title : "\(completion.title), \(completion.subtitle)"
    }

    private func pick(_ completion: MKLocalSearchCompletion, for field: PlannerField) {
        Haptics.selection()
        let text = Self.label(for: completion)
        if field == .origin {
            startCompletion = completion
            startQuery = text
        } else {
            endCompletion = completion
            endQuery = text
        }
        completer.clear()
        // @FocusState applies on the next update, so decide from the text, not from focusedField
        let bothSet = !startQuery.isEmpty && !endQuery.isEmpty
        focusedField = bothSet ? nil : (field == .origin ? .destination : .origin)
        if bothSet {
            startSearch()
        }
    }

    private func suggestionList(for field: PlannerField) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(completer.results.prefix(5).enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Rectangle().fill(TMDesign.hairline).frame(height: 1)
                }
                Button {
                    pick(item, for: field)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(TMDesign.tertiaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle)
                                    .font(.system(size: 13))
                                    .foregroundStyle(TMDesign.secondaryText)
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    /// The device's location. Waits while the permission prompt is up (however long the
    /// user takes), then up to 5 s for the fix; never reuses one more than a minute old.
    private func currentCoordinate() async -> CLLocationCoordinate2D? {
        func fresh() -> CLLocationCoordinate2D? {
            guard let location = locationManager.lastLocation,
                  Date().timeIntervalSince(location.timestamp) < 60 else { return nil }
            return location.coordinate
        }
        if let here = fresh() { return here }
        locationManager.requestLocation()
        var ticksAfterDecision = 0
        for _ in 0..<480 {  // 2-minute ceiling in case the prompt is left open
            if Task.isCancelled { return nil }  // Task.sleep stops waiting once cancelled
            switch locationManager.authorizationStatus {
            case .denied, .restricted:
                return nil
            case .notDetermined:
                break
            default:
                ticksAfterDecision += 1
            }
            if let here = fresh() { return here }
            if ticksAfterDecision > 20 { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func coordinate(for query: String, picked: MKLocalSearchCompletion?) async throws -> CLLocationCoordinate2D? {
        if query == Self.currentLocationLabel { return await currentCoordinate() }
        let request = picked.map { MKLocalSearch.Request(completion: $0) } ?? searchRequest(for: query)
        return try await MKLocalSearch(request: request).start().mapItems.first?.placemark.coordinate
    }

    /// Swap origin/destination (text and resolved coordinates) and re-search if a
    /// route is already on screen.
    private func swapEndpoints() {
        Haptics.light()
        swap(&startQuery, &endQuery)
        swap(&startCompletion, &endCompletion)
        let tmp = startCoordinate
        startCoordinate = endCoordinate
        endCoordinate = tmp
        if !routes.isEmpty && !startQuery.isEmpty && !endQuery.isEmpty {
            startSearch()
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
            (routeSegments[idx]?.segments ?? []).filter { !$0.isClinched }.count
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
        let segs = routeSegments[index]?.segments ?? []
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
                                openInWaze(end: end)
                            } label: {
                                Label("Waze", systemImage: "car.fill")
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

                    // Secondary: share, optionally with a link that opens the route in a maps app
                    Menu {
                        shareMenuItems
                    } label: {
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

    /// Sharing the maps URL as the item makes Messages show a tappable map preview
    /// that opens the app; the directions go along as the message text.
    @ViewBuilder
    private var shareMenuItems: some View {
        ForEach([MapLink.apple, .google, .waze], id: \.self) { link in
            if let url = mapLinkURL(link) {
                ShareLink(item: url, subject: Text("Route: \(startQuery) → \(endQuery)"),
                          message: Text(generateDirectionsText())) {
                    Label("Share \(link.appName) Link", systemImage: link.icon)
                }
            }
        }
        ShareLink(item: generateDirectionsText()) {
            Label("Share Directions Only", systemImage: "text.alignleft")
        }
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
                        ForEach(Array(route.steps.filter { !$0.instructions.isEmpty }.enumerated()), id: \.offset) { index, step in
                            do {
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

                                    // TM segments this step drives
                                    let stepSegs = segmentsForStep(index)
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
            // Street-by-street steps reveal the trip's endpoints
            .sentryReplayMask()
            .navigationTitle("Directions")
            .alert("Apple Watch", isPresented: Binding(get: { watchMessage != nil }, set: { if !$0 { watchMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(watchMessage ?? "")
            }
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
                        shareMenuItems
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

    /// TM segments a step drives, by index into the steps that have instructions
    private func segmentsForStep(_ index: Int) -> [TravelMappingAPI.MapSegment] {
        routeSegments[selectedRouteIndex]?.stepSegments[index] ?? []
    }

    /// Generate formatted directions text for sharing
    private func sendDirectionsToWatch() {
        guard let route = selectedRoute else { return }
        let steps = route.steps.compactMap { step -> (instruction: String, distance: Double, notice: String?)? in
            guard !step.instructions.isEmpty else { return nil }
            return (instruction: step.instructions, distance: step.distance, notice: step.notice)
        }
        let result = WatchSyncService.shared.sendDirections(
            routeName: "\(startQuery) → \(endQuery)",
            totalDistance: route.distance,
            totalTime: route.expectedTravelTime,
            steps: steps
        )
        switch result {
        case .delivered:
            Haptics.success()
            watchMessage = "Directions are on your Apple Watch."
        case .queued:
            Haptics.success()
            watchMessage = "Sent. Open Travel Mapping on your Apple Watch to see the directions."
        case .noWatch:
            Haptics.error()
            watchMessage = "No Apple Watch is paired with this iPhone."
        case .appNotInstalled:
            Haptics.error()
            watchMessage = "Install Travel Mapping on your Apple Watch from the Watch app on this iPhone, then try again."
        case .disabled:
            Haptics.error()
            watchMessage = "Turn on Settings › Show on Apple Watch to send directions."
        }
    }

    enum MapLink {
        case apple, google, waze
        var appName: String {
            switch self { case .apple: "Apple Maps"; case .google: "Google Maps"; case .waze: "Waze" }
        }
        var icon: String {
            switch self { case .apple: "map"; case .google: "globe"; case .waze: "car" }
        }
    }

    /// Waze links take only a destination; Waze routes from wherever the recipient is.
    private static func wazeURL(to end: CLLocationCoordinate2D) -> URL? {
        URL(string: String(format: "https://waze.com/ul?ll=%.6f,%.6f&navigate=yes", end.latitude, end.longitude))
    }

    private func openInWaze(end: CLLocationCoordinate2D) {
        // Universal link: opens the Waze app if installed, otherwise the Waze website
        if let url = Self.wazeURL(to: end) { UIApplication.shared.open(url) }
    }

    /// Opens the route in a maps app for whoever receives it. Google keeps the chosen
    /// alternative via waypoints; Apple Maps links only carry start and end.
    private func mapLinkURL(_ link: MapLink) -> URL? {
        guard let start = startCoordinate, let end = endCoordinate else { return nil }
        func ll(_ c: CLLocationCoordinate2D) -> String { String(format: "%.6f,%.6f", c.latitude, c.longitude) }
        switch link {
        case .apple:
            return URL(string: "https://maps.apple.com/?saddr=\(ll(start))&daddr=\(ll(end))&dirflg=d")
        case .waze:
            return Self.wazeURL(to: end)
        case .google:
            var url = "https://www.google.com/maps/dir/?api=1&origin=\(ll(start))&destination=\(ll(end))&travelmode=driving"
            if let route = selectedRoute {
                let wps = extractWaypoints(from: route, maxCount: 8)
                if !wps.isEmpty { url += "&waypoints=" + wps.map(ll).joined(separator: "%7C") }
            }
            return URL(string: url)
        }
    }

    private func generateDirectionsText(mapLink: MapLink? = nil) -> String {
        guard let route = selectedRoute else { return "" }
        var lines: [String] = []

        lines.append("Route: \(startQuery) → \(endQuery)")
        if let mapLink, let url = mapLinkURL(mapLink) {
            lines.append("Open in \(mapLink.appName): \(url.absoluteString)")
        }
        lines.append("Distance: \(formatDistance(route.distance)) | Time: \(formatTime(route.expectedTravelTime))")

        let clinched = tmSegments.filter(\.isClinched).count
        let newCount = tmSegments.count - clinched
        if !tmSegments.isEmpty {
            lines.append("TM Segments: \(tmSegments.count) (\(newCount) new, \(clinched) already traveled)")
        }
        lines.append("")
        lines.append("DRIVING DIRECTIONS")
        lines.append("")

        // Number only the steps shown; MapKit's first step is often an empty "start" step
        for (index, step) in route.steps.filter({ !$0.instructions.isEmpty }).enumerated() {
            let dist = step.distance > 0 ? " — \(formatDistance(step.distance))" : ""
            lines.append("\(index + 1). \(step.instructions)\(dist)")

            let stepSegs = segmentsForStep(index)
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

    /// Starts a search, cancelling any still in flight so its results can't land on the new routes
    private func startSearch() {
        // Check before cancelling: a search that cancels the running one must take over
        // its loading flags, or the spinners stay up
        guard !startQuery.isEmpty, !endQuery.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task { await calculateRoute() }
    }

    private func calculateRoute() async {
        // Submit-triggered (no Find Route button): ignore empty requests. Early return
        // touches no state, so the reportFullyDisplayed contract is unaffected.
        guard !startQuery.isEmpty, !endQuery.isEmpty else { return }
        focusedField = nil
        isCalculating = true
        errorMessage = nil
        routes = []
        routeSegments = [:]
        selectedRouteIndex = 0
        isLoadingSegments = false

        do {
            let start = try await coordinate(for: startQuery, picked: startCompletion)
            let end = try await coordinate(for: endQuery, picked: endCompletion)
            guard !Task.isCancelled else { return }

            guard let start, let end else {
                let locationMissing = (start == nil && startQuery == Self.currentLocationLabel)
                    || (end == nil && endQuery == Self.currentLocationLabel)
                let denied = [.denied, .restricted].contains(locationManager.authorizationStatus)
                errorMessage = !locationMissing ? "Could not find one of the locations"
                    : denied ? "Allow location access for Travel Mapping in Settings to use your current location."
                    : "Couldn't get your current location. Try again in a moment."
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

            let response = try await MKDirections(request: request).calculate()
            guard !Task.isCancelled else { return }
            routes = response.routes
            isCalculating = false // Show routes + map immediately

            // Load TM segments in background — UI is interactive during this
            isLoadingSegments = true
            let segments = await fetchCorridorSegments(for: response.routes)
            guard !Task.isCancelled else { return }
            let inputs = response.routes.map(Self.matchInput)
            let results = await Task.detached(priority: .userInitiated) {
                inputs.map { RouteSegmentMatcher.result(for: segments, routeCoords: $0.coords, steps: $0.steps) }
            }.value
            guard !Task.isCancelled else { return }
            routeSegments = Dictionary(uniqueKeysWithValues: results.enumerated().map { ($0.offset, $0.element) })
            isLoadingSegments = false
            SentrySDK.reportFullyDisplayed()
        } catch {
            guard !Task.isCancelled else { return }
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

    /// One fetch for the corridor all alternatives share: the alternatives' bounding boxes
    /// nearly coincide, so per-route fetches repeated the same server query three times.
    private func fetchCorridorSegments(for routes: [MKRoute]) async -> [TravelMappingAPI.MapSegment] {
        guard var rect = routes.first?.polyline.boundingMapRect else { return [] }
        for rt in routes.dropFirst() { rect = rect.union(rt.polyline.boundingMapRect) }
        let topLeft = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
        let bottomRight = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
        let minLat = min(topLeft.latitude, bottomRight.latitude) - 0.1
        let maxLat = max(topLeft.latitude, bottomRight.latitude) + 0.1
        let minLng = min(topLeft.longitude, bottomRight.longitude) - 0.1
        let maxLng = max(topLeft.longitude, bottomRight.longitude) + 0.1

        let traveler = primaryUser
        let tileSize = 2.0
        var allSegments: [TravelMappingAPI.MapSegment] = []
        await withTaskGroup(of: [TravelMappingAPI.MapSegment].self) { group in
            var lat = minLat
            while lat < maxLat {
                var lng = minLng
                while lng < maxLng {
                    let tileLat = lat, tileLng = lng
                    let tileMaxLat = min(lat + tileSize, maxLat)
                    let tileMaxLng = min(lng + tileSize, maxLng)
                    group.addTask {
                        guard !Task.isCancelled,
                              let result = try? await TravelMappingAPI.shared.getVisibleSegments(
                                traveler: traveler, minLat: tileLat, maxLat: tileMaxLat,
                                minLng: tileLng, maxLng: tileMaxLng
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
        // The matcher drops duplicates from adjacent tiles (a segment touching a tile edge comes back twice)
        return allSegments
    }

    /// Snapshot of what matching needs from an MKRoute (MKRoute isn't Sendable)
    private static func matchInput(for route: MKRoute) -> (coords: [CLLocationCoordinate2D], steps: [(CLLocationCoordinate2D, CLLocationCoordinate2D)]) {
        func coords(_ polyline: MKPolyline) -> [CLLocationCoordinate2D] {
            let pts = polyline.points()
            return (0..<polyline.pointCount).map { pts[$0].coordinate }
        }
        let steps = route.steps.filter { !$0.instructions.isEmpty }.compactMap { step -> (CLLocationCoordinate2D, CLLocationCoordinate2D)? in
            let c = coords(step.polyline)
            guard let first = c.first, let last = c.last else { return nil }
            return (first, last)
        }
        return (coords(route.polyline), steps)
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

// MARK: - Address suggestions

/// Wraps MKLocalSearchCompleter so the planner can suggest places as the user types.
@MainActor
final class AddressCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()
    private var activeQuery: String?

    var region: MKCoordinateRegion {
        get { completer.region }
        set { completer.region = newValue }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 2 {
            clear()
        } else {
            activeQuery = trimmed
            completer.queryFragment = trimmed
        }
    }

    func clear() {
        activeQuery = nil
        completer.cancel()
        results = []
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let latest = completer.results
        let fragment = completer.queryFragment
        // Drop results that arrive after clear() or for text the user has since replaced
        Task { @MainActor in
            guard fragment == self.activeQuery else { return }
            self.results = latest
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Typing fast cancels in-flight lookups; nothing worth reporting
        Task { @MainActor in self.results = [] }
    }
}

// MARK: - Route ↔ TM segment matching

/// Matched TM segments for one route alternative, precomputed off the main thread so
/// `body` only reads results
struct RouteMatchResult: Sendable {
    struct Line: Identifiable, Sendable {
        let id: Int
        let coords: [CLLocationCoordinate2D]
        let isClinched: Bool
    }
    /// In route order, one per TM segment (concurrent routes each count — TM clinches each root)
    let segments: [TravelMappingAPI.MapSegment]
    /// Same-status runs traced along the route polyline
    let lines: [Line]
    /// Index into the route's steps that have instructions → segments that step drives
    let stepSegments: [Int: [TravelMappingAPI.MapSegment]]
}

/// A TM segment the route actually travels along, with where on the route it lies
struct RouteSegmentMatch: Sendable {
    let segment: TravelMappingAPI.MapSegment
    let from: RoutePolylineIndex.Projection
    let to: RoutePolylineIndex.Projection
    var alongStart: Double { from.along }
    var alongEnd: Double { to.along }
}

/// Spatial index over a route polyline for fast point-to-route projection
struct RoutePolylineIndex: Sendable {
    struct Projection: Sendable {
        let legIndex: Int
        let distance: Double   // metres from the query point to the route
        let along: Double      // metres along the route from its start
        let point: CLLocationCoordinate2D
    }

    static let metersPerDegree = 111_320.0
    let coords: [CLLocationCoordinate2D]
    private let xs: [Double], ys: [Double]   // local planar metres
    private let cumulative: [Double]
    private let cosLat: Double
    private let cellSize: Double
    private let grid: [Int64: [Int]]         // 1 km cell → legs crossing it

    init(coords: [CLLocationCoordinate2D], cellSize: Double = 1_000) {
        self.coords = coords
        self.cellSize = cellSize
        let lats = coords.map(\.latitude)
        let midLat = coords.isEmpty ? 0 : (lats.min()! + lats.max()!) / 2
        let cosLat = cos(midLat * .pi / 180)
        self.cosLat = cosLat
        xs = coords.map { $0.longitude * Self.metersPerDegree * cosLat }
        ys = coords.map { $0.latitude * Self.metersPerDegree }

        var cum = [0.0]
        var grid: [Int64: [Int]] = [:]
        if coords.count > 1 {
            for i in 0..<(coords.count - 1) {
                let dx = xs[i + 1] - xs[i], dy = ys[i + 1] - ys[i]
                cum.append(cum[i] + (dx * dx + dy * dy).squareRoot())
                let cx0 = Int(floor(min(xs[i], xs[i + 1]) / cellSize)), cx1 = Int(floor(max(xs[i], xs[i + 1]) / cellSize))
                let cy0 = Int(floor(min(ys[i], ys[i + 1]) / cellSize)), cy1 = Int(floor(max(ys[i], ys[i + 1]) / cellSize))
                for cx in cx0...cx1 { for cy in cy0...cy1 { grid[Self.key(cx, cy), default: []].append(i) } }
            }
        }
        cumulative = cum
        self.grid = grid
    }

    private static func key(_ cx: Int, _ cy: Int) -> Int64 { (Int64(cx) << 32) ^ (Int64(cy) & 0xFFFF_FFFF) }

    /// Closest point on the route within `maxDistance` metres of `p`
    func project(_ p: CLLocationCoordinate2D, maxDistance: Double) -> Projection? {
        guard coords.count > 1 else { return nil }
        let px = p.longitude * Self.metersPerDegree * cosLat
        let py = p.latitude * Self.metersPerDegree
        let reach = Int(ceil(maxDistance / cellSize))
        let cx = Int(floor(px / cellSize)), cy = Int(floor(py / cellSize))
        var best: Projection?
        var bestSq = maxDistance * maxDistance
        for dx in -reach...reach {
            for dy in -reach...reach {
                guard let legs = grid[Self.key(cx + dx, cy + dy)] else { continue }
                for i in legs {
                    let ax = xs[i], ay = ys[i]
                    let lx = xs[i + 1] - ax, ly = ys[i + 1] - ay
                    let lenSq = lx * lx + ly * ly
                    let t = lenSq > 0 ? max(0, min(1, ((px - ax) * lx + (py - ay) * ly) / lenSq)) : 0
                    let qx = ax + t * lx, qy = ay + t * ly
                    let dSq = (px - qx) * (px - qx) + (py - qy) * (py - qy)
                    if dSq < bestSq {
                        bestSq = dSq
                        best = Projection(
                            legIndex: i, distance: dSq.squareRoot(),
                            along: cumulative[i] + t * lenSq.squareRoot(),
                            point: CLLocationCoordinate2D(latitude: qy / Self.metersPerDegree,
                                                          longitude: qx / (Self.metersPerDegree * cosLat)))
                    }
                }
            }
        }
        return best
    }

    /// The route's own coordinates between two projections, so drawn lines follow the road
    func slice(from a: Projection, to b: Projection) -> [CLLocationCoordinate2D] {
        let (lo, hi) = a.along <= b.along ? (a, b) : (b, a)
        var out = [lo.point]
        if hi.legIndex > lo.legIndex { out.append(contentsOf: coords[(lo.legIndex + 1)...hi.legIndex]) }
        out.append(hi.point)
        return out
    }
}

/// Decides which TM segments a route drives. A segment counts only if both waypoints lie on
/// the route, the route runs between them for about the segment's length (a crossing road
/// projects both ends to one spot), and it runs the same way (±35°). Thresholds were
/// measured against real MapKit routes and TM data: on-route waypoints sit ≤ ~75 m from the
/// polyline; ramp-entry interchanges reach ~150 m, allowed for one end of long segments.
enum RouteSegmentMatcher {
    static let endpointThreshold: Double = 80
    static let rampEndpointThreshold: Double = 150
    static let rampMinLength: Double = 1_000
    static let bearingTolerance: Double = 35
    static let alongRatioRange: ClosedRange<Double> = 0.7...1.6

    static func match(_ segments: [TravelMappingAPI.MapSegment], against index: RoutePolylineIndex) -> [RouteSegmentMatch] {
        var seen = Set<String>()
        var matches: [RouteSegmentMatch] = []
        for seg in segments {
            guard seen.insert(seg.id).inserted else { continue }   // tile-edge duplicates
            guard let a = index.project(seg.start, maxDistance: rampEndpointThreshold),
                  let b = index.project(seg.end, maxDistance: rampEndpointThreshold) else { continue }
            let length = distance(seg.start, seg.end)
            guard length > 1 else { continue }
            let nearA = a.distance <= endpointThreshold, nearB = b.distance <= endpointThreshold
            guard (nearA && nearB) || ((nearA || nearB) && length >= rampMinLength) else { continue }
            guard alongRatioRange.contains(abs(b.along - a.along) / length) else { continue }
            guard parallel(bearing(seg.start, seg.end), bearing(a.point, b.point)) else { continue }
            let (from, to) = a.along <= b.along ? (a, b) : (b, a)
            matches.append(RouteSegmentMatch(segment: seg, from: from, to: to))
        }
        return matches.sorted { $0.alongStart < $1.alongStart }
    }

    /// Everything the planner shows for one route; pure, so it runs in Task.detached
    static func result(for segments: [TravelMappingAPI.MapSegment],
                       routeCoords: [CLLocationCoordinate2D],
                       steps: [(CLLocationCoordinate2D, CLLocationCoordinate2D)]) -> RouteMatchResult {
        let index = RoutePolylineIndex(coords: routeCoords)
        let matches = match(segments, against: index)

        // Lines: concurrent routes overlap, so draw each stretch once; merge same-status runs
        var lines: [RouteMatchResult.Line] = []
        var current: (coords: [CLLocationCoordinate2D], clinched: Bool, end: Double)?
        var coveredUntil = -Double.infinity
        func flush() {
            if let c = current, c.coords.count > 1 {
                lines.append(.init(id: lines.count, coords: c.coords, isClinched: c.clinched))
            }
            current = nil
        }
        for m in matches where m.alongEnd > coveredUntil + 1 {
            let piece = index.slice(from: m.from, to: m.to)
            coveredUntil = max(coveredUntil, m.alongEnd)
            if var c = current, c.clinched == m.segment.isClinched,
               abs(m.alongStart - c.end) < 50, c.coords.count < 200 {
                c.coords.append(contentsOf: piece.dropFirst())
                c.end = m.alongEnd
                current = c
            } else {
                flush()
                current = (piece, m.segment.isClinched, m.alongEnd)
            }
        }
        flush()

        // Steps: each match goes to the step it overlaps most
        let stepRanges: [ClosedRange<Double>?] = steps.map { first, last in
            guard let a = index.project(first, maxDistance: 300),
                  let b = index.project(last, maxDistance: 300) else { return nil }
            return min(a.along, b.along)...max(a.along, b.along)
        }
        var stepSegments: [Int: [TravelMappingAPI.MapSegment]] = [:]
        for m in matches {
            var best: (step: Int, overlap: Double)?
            for (i, range) in stepRanges.enumerated() {
                guard let range else { continue }
                let overlap = min(range.upperBound, m.alongEnd) - max(range.lowerBound, m.alongStart)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (i, overlap) }
            }
            if let best { stepSegments[best.step, default: []].append(m.segment) }
        }

        return RouteMatchResult(segments: matches.map(\.segment), lines: lines, stepSegments: stepSegments)
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = (a.latitude - b.latitude) * RoutePolylineIndex.metersPerDegree
        let dLng = (a.longitude - b.longitude) * RoutePolylineIndex.metersPerDegree * cos(a.latitude * .pi / 180)
        return (dLat * dLat + dLng * dLng).squareRoot()
    }

    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLng) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Same line either direction, within the tolerance
    static func parallel(_ a: Double, _ b: Double) -> Bool {
        var d = abs(a - b).truncatingRemainder(dividingBy: 360)
        d = min(d, 360 - d)
        return min(d, 180 - d) <= bearingTolerance
    }
}
