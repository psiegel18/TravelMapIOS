import Sentry
import SwiftUI
import MapKit

struct RoadTripDetailView: View {
    @State var trip: RoadTrip
    @State private var shareContent: ShareContent?
    @State private var exportURL: URL?
    @State private var replayProgress: Double = 1.0  // 0.0 to 1.0
    @State private var isPlaying = false
    @State private var playTimer: Timer?
    @State private var notesText: String = ""
    @State private var lastSavedNotes: String = ""
    @FocusState private var notesFocused: Bool
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var distanceMeters: Double?
    @State private var showFullMap = false
    @State private var logAnalysis: TripLogAnalysis?
    @State private var logAnalysisError: String?
    @State private var excludedRangeIDs: Set<String> = []
    @State private var showListUpdate = false
    @State private var copiedLines = false
    @ObservedObject private var settings = SyncedSettingsService.shared

    private var useMiles: Bool {
        UserDefaults.standard.bool(forKey: "useMiles") || UserDefaults.standard.object(forKey: "useMiles") == nil
    }

    private var isRail: Bool { trip.tripType == .rail }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroMap
                VStack(spacing: 20) {
                    statTiles
                    if !trip.matchedSegments.isEmpty {
                        listUpdateCard
                    }
                    if trip.rawPoints.count > 1 {
                        replayCard
                    }
                    notesSection
                    segmentsList
                    gpsDetailRow
                }
                .padding(.horizontal)
            }
            .padding(.bottom)
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .sentryScreen("RoadTripDetail")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let url = exportURL {
                        ShareLink(item: url, preview: SharePreview("\(trip.name).list")) {
                            Label("Export .list File", systemImage: "doc.text")
                        }
                    }
                    Button {
                        Haptics.light()
                        shareImage()
                    } label: {
                        Label("Share Image", systemImage: "photo")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share options")
            }
        }
        .sheet(item: $shareContent) { content in
            SharePreviewSheet(content: content)
        }
        .sheet(isPresented: $showListUpdate) {
            ListUpdateSheet(
                lines: includedNewRanges.map(\.line),
                username: settings.primaryUser,
                category: isRail ? .rail : .road,
                blockTitle: "\(trip.startDate.formatted(.iso8601.year().month().day())) \(trip.name)",
                onMarkSubmitted: { markSubmitted(includedNewRanges) }
            )
        }
        .fullScreenCover(isPresented: $showFullMap) {
            TripFullScreenMap(
                trip: trip,
                ranges: logAnalysis?.ranges ?? [],
                replayProgress: $replayProgress,
                isPlaying: $isPlaying,
                onTogglePlay: togglePlay,
                onStopPlay: stopPlay
            )
        }
        .task {
            exportURL = try? await TripStorageService.shared.exportListFile(for: trip)
            await computeDistance()
        }
        .task(id: settings.primaryUser) {
            await analyzeLog()
        }
        .onChange(of: notesFocused) {
            if !notesFocused {
                saveNotes()
            }
        }
        .onDisappear {
            stopPlay()
            saveNotes()
        }
    }

    private func shareImage() {
        Task {
            if let image = await renderTripShareImage(trip: trip) {
                shareContent = .trip(image: image, tripID: trip.id)
            }
        }
    }

    /// Sums the GPS trail off the main thread — trips can carry thousands of points.
    private func computeDistance() async {
        guard distanceMeters == nil else { return }
        let coords = trip.rawPoints.map { ($0.latitude, $0.longitude) }
        distanceMeters = await Task.detached(priority: .utility) {
            var total = 0.0
            var last: CLLocation?
            for (lat, lon) in coords {
                let loc = CLLocation(latitude: lat, longitude: lon)
                if let l = last { total += loc.distance(from: l) }
                last = loc
            }
            return total
        }.value
    }

    // MARK: - Map hero (audit §8)

    private var replayCoordinates: [CLLocationCoordinate2D] {
        trip.replayCoordinates(progress: replayProgress)
    }

    private var heroDateLine: String {
        let day = trip.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let time = trip.startDate.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(time)"
    }

    private var heroMap: some View {
        ZStack(alignment: .bottomLeading) {
            Map(position: $mapPosition) {
                TripMapLayer(
                    trip: trip,
                    replayCoordinates: replayCoordinates,
                    replayProgress: replayProgress,
                    ranges: logAnalysis?.ranges ?? []
                )
            }
            .mapStyle(.standard)
            .onMapCameraChange { context in
                visibleRegion = context.region
            }

            // Gradient scrim carrying date + trip name (audit §8 — map becomes the hero)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                    Text(heroDateLine)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.white.opacity(0.8))
                Text(trip.name)
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 130)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
        .overlay(alignment: .topTrailing) {
            mapControls
        }
        .frame(height: 280)
    }

    private var mapControls: some View {
        VStack(spacing: 8) {
            Button {
                Haptics.light()
                stopPlay()
                showFullMap = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Full screen map")

            Button {
                adjustZoom(factor: 0.5)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom in")

            Button {
                adjustZoom(factor: 2.0)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom out")
        }
        .padding(10)
    }

    // MARK: - Stat tiles (audit §8 — distance is a headline)

    private var distanceParts: (value: String, label: String) {
        let label = useMiles ? "Miles" : "Km"
        guard let m = distanceMeters else { return ("—", label) }
        let value = useMiles ? m / 1609.34 : m / 1000
        return (String(format: "%.1f", value), label)
    }

    private var statTiles: some View {
        HStack(spacing: 12) {
            recapTile(value: trip.durationFormatted, label: "Duration")
            recapTile(value: distanceParts.value, label: distanceParts.label)
            recapTile(
                value: trip.matchedSegments.count.formatted(),
                label: "Segments",
                tint: TMDesign.greenChipFG
            )
        }
    }

    private func recapTile(value: String, label: String, tint: Color = .primary) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TMDesign.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(13)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    // MARK: - Replay (audit §8 — reads as a control)

    private var replayCard: some View {
        HStack(spacing: 14) {
            Button {
                Haptics.light()
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(TMDesign.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause replay" : "Replay drive")

            VStack(alignment: .leading, spacing: 4) {
                Text("Replay drive")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TMDesign.secondaryText)
                Slider(value: $replayProgress, in: 0...1) { editing in
                    if editing { stopPlay() }
                }
                .tint(TMDesign.accent)
            }

            Text("\(Int(replayProgress * 100))%")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(TMDesign.tertiaryText)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(14)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func togglePlay() {
        if isPlaying {
            stopPlay()
        } else {
            if replayProgress >= 1.0 { replayProgress = 0 }
            isPlaying = true
            playTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                Task { @MainActor in
                    replayProgress += 0.01
                    if replayProgress >= 1.0 {
                        replayProgress = 1.0
                        stopPlay()
                    }
                }
            }
        }
    }

    private func stopPlay() {
        isPlaying = false
        playTimer?.invalidate()
        playTimer = nil
    }

    // MARK: - .list update

    private var includedNewRanges: [TripLogRange] {
        (logAnalysis?.newRanges ?? []).filter { !excludedRangeIDs.contains($0.id) }
    }

    private func analyzeLog() async {
        let username = settings.primaryUser
        guard !username.isEmpty, !trip.matchedSegments.isEmpty else { return }
        do {
            logAnalysis = try await TripLogAnalyzer.analyze(trips: [trip], username: username)
            logAnalysisError = nil
        } catch {
            SentrySDK.capture(error: error)
            logAnalysisError = "Couldn't check your .list right now."
        }
    }

    private func markSubmitted(_ ranges: [TripLogRange]) {
        let keys = ranges.flatMap(\.hopKeys)
        trip.submittedHopKeys = Array(Set(trip.submittedHopKeys).union(keys))
        let updatedTrip = trip
        let crumb = Breadcrumb(level: .info, category: "list_update")
        crumb.message = "Marked \(ranges.count) ranges submitted from trip detail"
        SentrySDK.addBreadcrumb(crumb)
        Task {
            try? await TripStorageService.shared.save(updatedTrip)
            await analyzeLog()
        }
    }

    private var listUpdateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TMDesign.sectionHeader("Update your .\(isRail ? "rlist" : "list")")

            if settings.primaryUser.isEmpty {
                Text("Set your TravelMapping username in Settings to see which parts of this trip are already in your list file.")
                    .font(.system(size: 15))
                    .foregroundStyle(TMDesign.secondaryText)
            } else if let analysis = logAnalysis {
                HStack(spacing: 8) {
                    TMChip(text: "\(analysis.newRanges.count.formatted()) new", icon: "plus",
                           bg: TMDesign.amberChipBG, fg: TMDesign.amberChipFG)
                    if !analysis.submittedRanges.isEmpty {
                        TMChip(text: "\(analysis.submittedRanges.count.formatted()) submitted", icon: "paperplane")
                    }
                    TMChip(text: "\(analysis.loggedRanges.count.formatted()) already logged", icon: "checkmark",
                           bg: TMDesign.greenChipBG, fg: TMDesign.greenChipFG)
                }

                if analysis.newRanges.isEmpty {
                    Text(analysis.submittedRanges.isEmpty
                         ? "Everything on this trip is already in your list file."
                         : "Waiting for TravelMapping to pick up your submitted update — the database refreshes daily.")
                        .font(.system(size: 15))
                        .foregroundStyle(TMDesign.secondaryText)
                } else {
                    ForEach(analysis.newRanges) { range in
                        ListLineToggleRow(
                            range: range,
                            isIncluded: !excludedRangeIDs.contains(range.id),
                            onToggle: {
                                if excludedRangeIDs.contains(range.id) {
                                    excludedRangeIDs.remove(range.id)
                                } else {
                                    excludedRangeIDs.insert(range.id)
                                }
                            }
                        )
                    }

                    HStack(spacing: 10) {
                        Button {
                            Haptics.light()
                            showListUpdate = true
                        } label: {
                            Label("Update my .list", systemImage: "square.and.pencil")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(TMDesign.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(includedNewRanges.isEmpty)

                        Button {
                            UIPasteboard.general.string = includedNewRanges.map(\.line.text).joined(separator: "\n")
                            Haptics.success()
                            copiedLines = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copiedLines = false
                            }
                        } label: {
                            Label(copiedLines ? "Copied" : "Copy lines", systemImage: copiedLines ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(TMDesign.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(TMDesign.blueChipBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(includedNewRanges.isEmpty)
                    }
                }

                if analysis.unresolvedCount > 0 {
                    Text("\(analysis.unresolvedCount.formatted()) recorded segment\(analysis.unresolvedCount == 1 ? "" : "s") couldn't be matched to current route data and \(analysis.unresolvedCount == 1 ? "was" : "were") left out.")
                        .font(.system(size: 13))
                        .foregroundStyle(TMDesign.tertiaryText)
                }
            } else if let error = logAnalysisError {
                HStack {
                    Text(error)
                        .font(.system(size: 15))
                        .foregroundStyle(TMDesign.secondaryText)
                    Spacer()
                    Button("Retry") { Task { await analyzeLog() } }
                        .font(.system(size: 15, weight: .semibold))
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Comparing with your list file…")
                        .font(.system(size: 15))
                        .foregroundStyle(TMDesign.secondaryText)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes")
                    .font(.headline)
                Spacer()
                if notesFocused {
                    Button("Done") {
                        notesFocused = false
                        saveNotes()
                    }
                    .font(.subheadline)
                }
            }
            TextField("Add notes about this trip...", text: $notesText, axis: .vertical)
                .lineLimit(3...6)
                .focused($notesFocused)
                .onAppear {
                    notesText = trip.notes
                    lastSavedNotes = trip.notes
                }
        }
        .padding()
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

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

    private func saveNotes() {
        guard notesText != lastSavedNotes else { return }
        lastSavedNotes = notesText
        trip.notes = notesText
        let updatedTrip = trip
        Task {
            try? await TripStorageService.shared.save(updatedTrip)
        }
    }

    // MARK: - Matched segments (audit §8 — confidence as a badge)

    private var segmentsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            TMDesign.sectionHeader(
                trip.matchedSegments.isEmpty
                    ? "Matched Segments"
                    : "\(trip.matchedSegments.count.formatted()) segments clinched"
            )

            if trip.matchedSegments.isEmpty {
                Text("No TM route segments were matched for this trip.")
                    .font(.system(size: 15))
                    .foregroundStyle(TMDesign.secondaryText)
                    .padding(.vertical, 8)
            } else {
                ForEach(trip.matchedSegments) { seg in
                    HStack(spacing: 12) {
                        Image(systemName: isRail ? "tram.fill" : "road.lanes")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isRail ? TMDesign.redChipFG : TMDesign.blueChipFG)
                            .frame(width: 32, height: 32)
                            .background(
                                isRail ? TMDesign.redChipBG : TMDesign.blueChipBG,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(seg.region) \(seg.routeName)")
                                .font(.system(size: 16, weight: .bold))
                            Text("\(seg.startWaypoint) → \(seg.endWaypoint)")
                                .font(.system(size: 13))
                                .foregroundStyle(TMDesign.tertiaryText)
                        }
                        Spacer(minLength: 8)
                        TMChip(
                            text: String(format: "%.0f%%", seg.confidence * 100),
                            icon: "checkmark",
                            bg: TMDesign.greenChipBG,
                            fg: TMDesign.greenChipFG
                        )
                    }
                    .padding(.vertical, 5)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(seg.region) \(seg.routeName), \(seg.startWaypoint) to \(seg.endWaypoint), \(Int((seg.confidence * 100).rounded())) percent match confidence"
                    )
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// GPS-points count demoted to a secondary detail row (audit §8).
    private var gpsDetailRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "location")
                .font(.system(size: 12))
            Text("\(trip.rawPoints.count.formatted()) GPS points recorded")
                .font(.system(size: 13))
                .monospacedDigit()
        }
        .foregroundStyle(TMDesign.tertiaryText)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

}

// MARK: - Shared trip map pieces

extension RoadTrip {
    /// GPS trail up to `progress` (0…1) of the trip, for replay.
    func replayCoordinates(progress: Double) -> [CLLocationCoordinate2D] {
        guard rawPoints.count > 1 else { return [] }
        let count = Int(Double(rawPoints.count) * progress)
        return rawPoints.prefix(max(2, count)).map(\.coordinate)
    }
}

extension TripLogRange.Status {
    var color: Color {
        switch self {
        case .new: return TMDesign.frontier
        case .submitted: return TMDesign.purpleChipFG
        case .logged: return TMDesign.clinched
        }
    }

    var label: String {
        switch self {
        case .new: return "New"
        case .submitted: return "Submitted"
        case .logged: return "In your list"
        }
    }
}

/// Trip trace + start/end/replay markers, with traveled route ranges colored by
/// whether they're already in the user's list. Shared by the hero card and full screen.
struct TripMapLayer: MapContent {
    let trip: RoadTrip
    let replayCoordinates: [CLLocationCoordinate2D]
    let replayProgress: Double
    let ranges: [TripLogRange]

    var body: some MapContent {
        ForEach(ranges) { range in
            MapPolyline(coordinates: range.coordinates)
                .stroke(range.status.color.opacity(0.85), lineWidth: 7)
        }
        if replayCoordinates.count > 1 {
            MapPolyline(coordinates: replayCoordinates)
                .stroke(TMDesign.accent, lineWidth: ranges.isEmpty ? 3 : 2.5)
        }
        // Start pin
        if let first = trip.rawPoints.first {
            Annotation("", coordinate: first.coordinate) {
                Circle()
                    .fill(TMDesign.clinched)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
        // End pin
        if trip.rawPoints.count > 1, let end = trip.rawPoints.last {
            Annotation("", coordinate: end.coordinate) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white, TMDesign.rail)
            }
        }
        // Replay position marker
        if replayProgress < 1.0, let last = replayCoordinates.last {
            Annotation("", coordinate: last) {
                Image(systemName: trip.tripType == .rail ? "tram.fill" : "car.fill")
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(TMDesign.accent, in: Circle())
            }
        }
    }
}

/// Full-screen trip map with standard map controls, style toggle, legend and replay.
struct TripFullScreenMap: View {
    let trip: RoadTrip
    let ranges: [TripLogRange]
    @Binding var replayProgress: Double
    @Binding var isPlaying: Bool
    let onTogglePlay: () -> Void
    let onStopPlay: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .automatic
    @State private var hybrid = false

    private var presentStatuses: [TripLogRange.Status] {
        [.new, .submitted, .logged].filter { status in ranges.contains { $0.status == status } }
    }

    var body: some View {
        Map(position: $position) {
            TripMapLayer(
                trip: trip,
                replayCoordinates: trip.replayCoordinates(progress: replayProgress),
                replayProgress: replayProgress,
                ranges: ranges
            )
        }
        .mapStyle(hybrid ? .hybrid : .standard)
        .mapControls {
            MapCompass()
            MapScaleView()
            MapUserLocationButton()
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    Haptics.selection()
                    hybrid.toggle()
                } label: {
                    Image(systemName: hybrid ? "map" : "globe.americas.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hybrid ? "Standard map" : "Satellite map")
            }
            .padding(.horizontal)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if !presentStatuses.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(presentStatuses, id: \.self) { status in
                            HStack(spacing: 6) {
                                Capsule()
                                    .fill(status.color)
                                    .frame(width: 18, height: 6)
                                Text(status.label)
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if trip.rawPoints.count > 1 {
                    HStack(spacing: 12) {
                        Button {
                            Haptics.light()
                            onTogglePlay()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(TMDesign.accent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPlaying ? "Pause replay" : "Replay drive")

                        Slider(value: $replayProgress, in: 0...1) { editing in
                            if editing { onStopPlay() }
                        }
                        .tint(TMDesign.accent)
                    }
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .onDisappear(perform: onStopPlay)
        .sentryScreen("RoadTripFullMap")
    }
}

// MARK: - .list update pieces

struct ListLineToggleRow: View {
    let range: TripLogRange
    let isIncluded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isIncluded ? TMDesign.accent : TMDesign.chevron)
                Text(range.line.text)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(isIncluded ? .primary : TMDesign.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(range.region) \(range.route), \(range.startWaypoint) to \(range.endWaypoint)")
        .accessibilityValue(isIncluded ? "Included" : "Excluded")
    }
}

/// Merges new lines into the user's current list file the way they organize it,
/// previews where each line lands, and hands off to GitHub's web editor.
struct ListUpdateSheet: View {
    let lines: [ListLine]
    let username: String
    let category: RouteCategory
    let blockTitle: String
    let onMarkSubmitted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var result: ListFileMerger.Result?
    @State private var hasExistingFile = true
    @State private var errorMessage: String?
    @State private var copiedFile = false
    @State private var copiedLines = false

    private var fileName: String { "\(username).\(category.fileExtension)" }

    var body: some View {
        NavigationStack {
            List {
                if let result {
                    Section {
                        ForEach(result.placements) { placement in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(placement.line.text)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                Text(placementDetail(placement))
                                    .font(.system(size: 12))
                                    .foregroundStyle(TMDesign.tertiaryText)
                            }
                        }
                    } header: {
                        Text("Where your new lines go")
                    } footer: {
                        Text(hasExistingFile
                             ? "Placed next to similar routes, following how your \(fileName) is organized. Nothing already in your file is changed."
                             : "You don't have a \(fileName) yet — submit your first file from Get Started, then use this for updates.")
                    }

                    if !result.duplicates.isEmpty {
                        Section("Already in your file") {
                            ForEach(result.duplicates) { line in
                                Text(line.text)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundStyle(TMDesign.tertiaryText)
                            }
                        }
                    }

                    Section {
                        stepButton(number: 1, title: copiedFile ? "Copied updated file" : "Copy updated \(fileName)",
                                   icon: copiedFile ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = result.text
                            copiedFile = true
                            breadcrumb("Copied merged list file (\(result.placements.count) new lines)")
                            Haptics.success()
                        }
                        stepButton(number: 2, title: "Open \(fileName) on GitHub", icon: "arrow.up.forward.app") {
                            breadcrumb("Opened GitHub editor")
                            openURL(DataService.listFileEditURL(username: username, category: category))
                        }
                        stepButton(number: 3, title: "Mark as submitted", icon: "paperplane") {
                            onMarkSubmitted()
                            Haptics.success()
                            dismiss()
                        }
                    } header: {
                        Text("Send the update")
                    } footer: {
                        Text("In GitHub's editor, select all of the file's text and paste, then tap Commit/Propose changes and open the pull request. Submitted segments stay hidden here until TravelMapping's nightly update picks them up.")
                    }

                    Section {
                        Button {
                            UIPasteboard.general.string = result.placements.map(\.line.text).joined(separator: "\n")
                            copiedLines = true
                            breadcrumb("Copied new list lines only")
                            Haptics.success()
                        } label: {
                            Label(copiedLines ? "Copied" : "Copy only the new lines", systemImage: copiedLines ? "checkmark" : "text.badge.plus")
                        }
                    } footer: {
                        Text("If you'd rather place them yourself.")
                    }
                } else if let errorMessage {
                    Section {
                        Text(errorMessage)
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Fetching your current \(fileName)…")
                                .foregroundStyle(TMDesign.secondaryText)
                        }
                    }
                }
            }
            .navigationTitle("Update \(fileName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
        .sentryScreen("ListUpdate")
    }

    private func load() async {
        errorMessage = nil
        do {
            let existing = try await DataService.fetchCurrentListText(username: username, category: category)
            hasExistingFile = existing != nil
            let text = existing ?? ""
            let lines = lines
            let blockTitle = blockTitle
            result = await Task.detached(priority: .userInitiated) {
                ListFileMerger.merge(existing: text, newLines: lines, blockTitle: blockTitle)
            }.value
        } catch {
            SentrySDK.capture(error: error)
            errorMessage = "Couldn't download your current \(fileName) from GitHub. Check your connection and try again."
        }
    }

    private func placementDetail(_ placement: ListFileMerger.Placement) -> String {
        var detail = "Line \(placement.lineNumber.formatted())"
        if let section = placement.section, !section.isEmpty {
            detail += " · under “\(section)”"
        }
        return detail
    }

    private func stepButton(number: Int, title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(TMDesign.accent, in: Circle())
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: icon)
                    .foregroundStyle(TMDesign.accent)
            }
        }
    }

    private func breadcrumb(_ message: String) {
        let crumb = Breadcrumb(level: .info, category: "list_update")
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }
}
