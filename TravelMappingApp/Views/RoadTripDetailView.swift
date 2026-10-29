import Sentry
import SwiftUI
import MapKit

struct RoadTripDetailView: View {
    @State var trip: RoadTrip
    @State private var shareContent: ShareContent?
    @State private var exportURL: URL?
    @State private var expandedRuns: Set<UUID> = []
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
    /// PRs that include segments from this trip
    @State private var tripPRs: [ListUpdatePR] = []
    @State private var confirmDelete = false
    /// Set once deleted so the onDisappear notes save can't write the trip back
    @State private var isDeleted = false
    @Environment(\.dismiss) private var dismiss
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
                    Divider()
                    // The list's long-press menu has Delete too; this is the discoverable one
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete Trip", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Trip options")
            }
        }
        .alert("Delete Trip?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                isDeleted = true
                Task {
                    try? await TripStorageService.shared.delete(id: trip.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \"\(trip.name)\"? This will also delete \(trip.rawPoints.count.formatted()) GPS points and the exported .list file. This cannot be undone.")
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
                tripNames: [trip.name],
                onSubmitted: { pr in markSubmitted(includedNewRanges, pr: pr) }
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
            await computeDistance()
        }
        .task(id: settings.dismissedHopKeys) {
            exportURL = try? await TripStorageService.shared.exportListFile(
                for: trip, excluding: Set(settings.dismissedHopKeys))
        }
        // Re-checks when segments are dismissed here or on another device (iCloud)
        .task(id: "\(settings.primaryUser)|\(settings.dismissedHopKeys.joined(separator: ","))") {
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
            let storage = TripStorageService.shared
            let fileExtension = isRail ? "rlist" : "list"
            let analysis = try await TripLogAnalyzer.analyze(
                trips: [trip], username: username,
                submittedKeys: await storage.submittedHopKeys(fileExtension: fileExtension),
                dismissedKeys: Set(settings.dismissedHopKeys)
            )
            let tripKeys = Set(analysis.ranges.flatMap(\.hopKeys))
            tripPRs = await storage.listSubmissions()
                .filter { $0.fileExtension == fileExtension && !tripKeys.isDisjoint(with: $0.hopKeys) }
                .compactMap(\.pr)
            logAnalysis = analysis
            logAnalysisError = nil
        } catch {
            SentrySDK.capture(error: error)
            logAnalysisError = "Couldn't check your .list right now."
        }
    }

    private func setDismissed(_ ranges: [TripLogRange], _ dismissed: Bool) {
        let keys = ranges.flatMap(\.hopKeys)
        if dismissed {
            settings.dismissHops(keys)
            excludedRangeIDs.subtract(ranges.map(\.id))
        } else {
            settings.restoreHops(keys)
        }
        Haptics.light()
        let crumb = Breadcrumb(level: .info, category: "list_update")
        crumb.message = "\(dismissed ? "Dismissed" : "Restored") \(ranges.count) ranges from trip detail"
        SentrySDK.addBreadcrumb(crumb)
        // Re-analysis runs from the .task keyed on dismissedHopKeys
    }

    private func markSubmitted(_ ranges: [TripLogRange], pr: ListUpdatePR?) {
        let crumb = Breadcrumb(level: .info, category: "list_update")
        crumb.message = "Marked \(ranges.count) ranges submitted from trip detail"
        SentrySDK.addBreadcrumb(crumb)
        let fileExtension = isRail ? "rlist" : "list"
        Task {
            await TripStorageService.shared.recordSubmission(
                fileExtension: fileExtension,
                hopKeys: ranges.flatMap(\.hopKeys),
                lines: ranges.map(\.line.text),
                pr: pr
            )
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

                if !analysis.dismissedRanges.isEmpty {
                    HStack {
                        Text("\(analysis.dismissedRanges.count.formatted()) marked not traveled")
                            .font(.system(size: 13))
                            .foregroundStyle(TMDesign.tertiaryText)
                        Spacer()
                        Button("Restore") { setDismissed(analysis.dismissedRanges, false) }
                            .font(.system(size: 13, weight: .semibold))
                    }
                }

                if analysis.newRanges.isEmpty {
                    Text(!analysis.submittedRanges.isEmpty
                         ? "Waiting for TravelMapping to pick up your submitted update — the database refreshes daily."
                         : analysis.dismissedRanges.isEmpty
                         ? "Everything on this trip is already in your list file."
                         : "Nothing new on this trip — the rest is in your list file or marked not traveled.")
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
                        .contextMenu {
                            Button {
                                setDismissed([range], true)
                            } label: {
                                Label("Didn't Travel This", systemImage: "eye.slash")
                            }
                        }
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

                ForEach(tripPRs) { pr in
                    Link(destination: pr.url) {
                        Label("Pull request #\(pr.number) · \(pr.lineCount.formatted()) line\(pr.lineCount == 1 ? "" : "s")",
                              systemImage: "arrow.triangle.pull")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }

                if analysis.unresolvedCount > 0 {
                    Text("\(analysis.unresolvedCount.formatted()) recorded segment\(analysis.unresolvedCount == 1 ? "" : "s") couldn't be matched to current route data and \(analysis.unresolvedCount == 1 ? "was" : "were") left out.")
                        .font(.system(size: 13))
                        .foregroundStyle(TMDesign.tertiaryText)
                }
                if analysis.unverifiedCount > 0 {
                    Text("\(analysis.unverifiedCount.formatted()) segment\(analysis.unverifiedCount == 1 ? " wasn't" : "s weren't") followed end to end by your GPS track — like a side road next to the route — so \(analysis.unverifiedCount == 1 ? "it was" : "they were") left out.")
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
        guard !isDeleted, notesText != lastSavedNotes else { return }
        lastSavedNotes = notesText
        trip.notes = notesText
        let updatedTrip = trip
        Task {
            try? await TripStorageService.shared.save(updatedTrip)
        }
    }

    // MARK: - Matched segments

    /// Consecutive, touching segments on one route, in the order driven — one row per road
    /// instead of one per waypoint hop, which ran to hundreds of rows on long trips
    struct RouteRun: Identifiable {
        var segments: [MatchedSegment]
        /// Waypoint labels in driving order. Segments carry TM's route order, so a road
        /// driven against it arrives as (12,13), (11,12) — the chain is built from which
        /// ends touch, not from start/end.
        var labels: [String]
        var id: UUID { segments[0].id }
        var listName: String { segments[0].listName }
        /// First and last labels, skipping hidden "+" shaping points where the run has others
        var from: String { labels.first { !$0.hasPrefix("+") } ?? labels[0] }
        var to: String { labels.last { !$0.hasPrefix("+") } ?? labels[labels.count - 1] }
        /// One segment says nothing about which way it was driven
        var arrow: String { segments.count == 1 ? "–" : "→" }

        init(_ seg: MatchedSegment) {
            segments = [seg]
            labels = [seg.startWaypoint, seg.endWaypoint]
        }

        /// Adds the next segment when it continues this run; false when it doesn't touch
        /// (a gap with nothing matched between stays a separate row, like the .list merger)
        mutating func extend(with seg: MatchedSegment) -> Bool {
            guard seg.root == segments[0].root, let last = labels.last else { return false }
            if seg.startWaypoint == last {
                labels.append(seg.endWaypoint)
            } else if seg.endWaypoint == last {
                labels.append(seg.startWaypoint)
            } else if segments.count == 1, seg.startWaypoint == labels[0] || seg.endWaypoint == labels[0] {
                // The first segment was driven the other way
                labels.reverse()
                labels.append(seg.startWaypoint == labels[labels.count - 1] ? seg.endWaypoint : seg.startWaypoint)
            } else {
                return false
            }
            segments.append(seg)
            return true
        }
    }

    private var routeRuns: [RouteRun] {
        var runs: [RouteRun] = []
        for seg in trip.matchedSegments.sorted(by: { $0.entryTime < $1.entryTime }) {
            if runs.isEmpty || !runs[runs.count - 1].extend(with: seg) {
                runs.append(RouteRun(seg))
            }
        }
        return runs
    }

    private var segmentsList: some View {
        let runs = routeRuns
        return VStack(alignment: .leading, spacing: 10) {
            TMDesign.sectionHeader(
                trip.matchedSegments.isEmpty
                    ? "Matched Segments"
                    : "\(trip.matchedSegments.count.formatted()) segments on \(runs.count.formatted()) \(runs.count == 1 ? "road" : "roads")"
            )

            if trip.matchedSegments.isEmpty {
                Text("No TM route segments were matched for this trip.")
                    .font(.system(size: 15))
                    .foregroundStyle(TMDesign.secondaryText)
                    .padding(.vertical, 8)
            } else {
                ForEach(runs) { run in
                    routeRunRow(run)
                    if expandedRuns.contains(run.id) {
                        ForEach(run.segments) { seg in
                            HStack {
                                Text("\(seg.startWaypoint) → \(seg.endWaypoint)")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(TMDesign.secondaryText)
                                Spacer()
                                Text(String(format: "%.0f%%", seg.confidence * 100))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(TMDesign.greenChipFG)
                            }
                            .padding(.leading, 44)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(seg.startWaypoint) to \(seg.endWaypoint), \(Int((seg.confidence * 100).rounded())) percent match confidence")
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func routeRunRow(_ run: RouteRun) -> some View {
        let expanded = expandedRuns.contains(run.id)
        return Button {
            withAnimation(.snappy) {
                if expanded { expandedRuns.remove(run.id) } else { expandedRuns.insert(run.id) }
            }
        } label: {
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
                    Text(run.listName)
                        .font(.system(size: 16, weight: .bold))
                    Text("\(run.from) \(run.arrow) \(run.to)")
                        .font(.system(size: 13))
                        .foregroundStyle(TMDesign.tertiaryText)
                }
                Spacer(minLength: 8)
                if run.segments.count > 1 {
                    Text(run.segments.count.formatted())
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TMDesign.secondaryText)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TMDesign.tertiaryText)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(run.listName), \(run.from) to \(run.to), \(run.segments.count) \(run.segments.count == 1 ? "segment" : "segments")")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(expanded ? "Hides the segments" : "Shows each segment")
        .accessibilityAddTraits(.isButton)
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
        case .dismissed: return TMDesign.tertiaryText
        }
    }

    var label: String {
        switch self {
        case .new: return "New"
        case .submitted: return "Submitted"
        case .logged: return "In your list"
        case .dismissed: return "Not traveled"
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
        // GPS trace underneath, so route status colors read clearly where the drive
        // matched a route and the trace still shows wherever it didn't
        if replayCoordinates.count > 1 {
            MapPolyline(coordinates: replayCoordinates)
                .stroke(TMDesign.accent, lineWidth: 3)
        }
        ForEach(ranges.filter { $0.status != .dismissed }) { range in
            MapPolyline(coordinates: range.coordinates)
                .stroke(range.status.color, lineWidth: 6)
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
    /// Opens zoomed to these coordinates (one segment) instead of the whole trip
    var focus: [CLLocationCoordinate2D] = []
    var showsReplay = true

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
                if showsReplay && trip.rawPoints.count > 1 {
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
        .onAppear {
            guard !focus.isEmpty else { return }
            let rect = focus.reduce(MKMapRect.null) {
                $0.union(MKMapRect(origin: MKMapPoint($1), size: MKMapSize(width: 0, height: 0)))
            }
            // Room around the segment to see which road the drive actually took
            let pad = max(rect.width, rect.height) * 0.6 + 800
            position = .rect(rect.insetBy(dx: -pad, dy: -pad))
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
/// previews where each line lands, then opens a pull request (signed in to GitHub)
/// or hands off to GitHub's web editor.
struct ListUpdateSheet: View {
    let lines: [ListLine]
    let username: String
    let category: RouteCategory
    let blockTitle: String
    let tripNames: [String]
    /// Existing lines to rewrite (list checkup fixes): logged line → corrected line
    var replacements: [String: String] = [:]
    /// Called on send with the replacement keys that actually matched a line in the file
    var onFixesSent: (([String]) -> Void)? = nil
    /// Called once the update is on its way — with the PR when the app opened one
    let onSubmitted: (ListUpdatePR?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var github = GitHubService.shared
    @AppStorage("listAppendOnly") private var appendOnly = false
    @State private var result: ListFileMerger.Result?
    @State private var hasExistingFile = true
    @State private var errorMessage: String?
    @State private var copiedFile = false
    @State private var copiedLines = false
    @State private var isOpeningPR = false
    /// Remembered between sheets; a draft lets the user check the PR on GitHub before the TM team sees it
    @AppStorage("listPROpenAsDraft") private var openAsDraft = true
    @State private var openedAsDraft = false
    @State private var prError: String?
    @State private var openedPR: ListUpdatePR?
    /// Normalized original lines the replacements matched in the current file
    @State private var appliedFixes: [String] = []
    /// Lines this send added (an appended PR's lineCount is its running total)
    @State private var sentLineCount = 0
    @State private var showSignIn = false
    @State private var showManualSteps = false
    /// The user's still-open app PR for this list, if any — new lines go into it
    @State private var openPR: ListUpdatePR?

    private var fileName: String { "\(username).\(category.fileExtension)" }

    var body: some View {
        NavigationStack {
            List {
                if let openedPR {
                    prOpenedSection(openedPR)
                } else if let result {
                    placementSections(result)
                    if github.isConfigured {
                        pullRequestSection
                        Section {
                            DisclosureGroup("Do it yourself in GitHub's editor", isExpanded: $showManualSteps) {
                                manualSteps(result)
                            }
                        }
                    } else {
                        Section {
                            manualSteps(result)
                        } header: {
                            Text("Send the update")
                        } footer: {
                            manualFooter
                        }
                    }
                    if !result.placements.isEmpty {
                        copyLinesSection(result)
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
                        .disabled(isOpeningPR)
                }
            }
            .sheet(isPresented: $showSignIn) {
                GitHubSignInSheet()
            }
            .task { await load() }
            .interactiveDismissDisabled(isOpeningPR)
        }
        .sentryScreen("ListUpdate")
    }

    // MARK: Sections

    @ViewBuilder
    private func placementSections(_ result: ListFileMerger.Result) -> some View {
        if !replacements.isEmpty {
            Section {
                ForEach(replacements.sorted(by: { $0.key < $1.key }), id: \.key) { old, new in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(old)
                            .strikethrough()
                            .foregroundStyle(TMDesign.tertiaryText)
                        Text(new)
                            .foregroundStyle(appliedFixes.contains(ListFileMerger.normalizedLine(old)) ? .primary : TMDesign.tertiaryText)
                    }
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                }
            } header: {
                Text("Lines being fixed")
            } footer: {
                let missing = replacements.count - appliedFixes.count
                if missing > 0 {
                    Text("\(missing) of these line\(missing == 1 ? " isn't" : "s aren't") in your current \(fileName) anymore — probably already fixed — and will be skipped.")
                } else {
                    Text("Only these lines change; any comment at the end of a line is kept.")
                }
            }
        }

        if !result.placements.isEmpty {
        Section {
            ForEach(result.placements) { placement in
                VStack(alignment: .leading, spacing: 3) {
                    if let ext = placement.extended {
                        // By position: a file can hold the same line twice
                        ForEach(Array(([ext.from] + placement.absorbed).enumerated()), id: \.offset) { _, old in
                            Text(old)
                                .strikethrough()
                                .foregroundStyle(TMDesign.tertiaryText)
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                        }
                        Text(ext.to)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                    } else {
                        Text(placement.line.text)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                    }
                    Text(placementDetail(placement))
                        .font(.system(size: 12))
                        .foregroundStyle(TMDesign.tertiaryText)
                }
            }
        } header: {
            Text("Where your new lines go")
        } footer: {
            if !hasExistingFile {
                Text("You don't have a \(fileName) yet — submit your first file from Get Started, then use this for updates.")
            } else if appendOnly {
                Text("Added as one block at the end of your \(fileName) (change in Settings › GitHub). Nothing already in your file is changed.")
            } else if result.placements.contains(where: { $0.extended != nil }) {
                Text("Where you already have a line on the same route that this trip continues, that line's start or end is moved instead of adding a second line; if the trip joins two of your lines in the same block, they become one (crossed out above). Other lines are placed next to similar routes, following how your \(fileName) is organized.")
            } else {
                Text("Placed next to similar routes, following how your \(fileName) is organized. Nothing already in your file is changed.")
            }
        }
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
    }

    @ViewBuilder
    private var pullRequestSection: some View {
        Section {
            if github.isSignedIn {
                Button {
                    isOpeningPR = true  // before the Task starts, so a double tap can't send twice
                    Task { await openPullRequest() }
                } label: {
                    HStack(spacing: 10) {
                        if isOpeningPR {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.triangle.pull")
                        }
                        Text(isOpeningPR ? "Sending…" : openPR.map { "Add to pull request #\($0.number)" } ?? "Open pull request")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .disabled(isOpeningPR || ((result?.placements.isEmpty ?? true) && appliedFixes.isEmpty) || !hasExistingFile)
                if openPR == nil {
                    Toggle("Open as a draft", isOn: $openAsDraft)
                        .disabled(isOpeningPR)
                }
            } else {
                Button {
                    showSignIn = true
                } label: {
                    Label { Text("Sign in with GitHub") } icon: { GitHubMark() }
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            if let prError {
                Text(prError)
                    .font(.system(size: 13))
                    .foregroundStyle(TMDesign.rail)
            }
        } header: {
            Text("Send the update")
        } footer: {
            if let openPR {
                Text("Your pull request #\(openPR.number) hasn't been merged yet, so these lines are added to it instead of opening a second one that would conflict.")
            } else if let login = github.login, github.isSignedIn {
                Text(openAsDraft
                     ? "As @\(login): forks TravelMapping/UserData to your account (first time only), commits the updated file to a new branch, and opens a draft pull request. Look it over on GitHub, then tap “Ready for review” there to send it to the TM team."
                     : "As @\(login): forks TravelMapping/UserData to your account (first time only), commits the updated file to a new branch, and opens a pull request for the TM team to review.")
            } else {
                Text("Sign in once and the app opens the pull request for you — no copying and pasting.")
            }
        }
    }

    @ViewBuilder
    private func manualSteps(_ result: ListFileMerger.Result) -> some View {
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
            onFixesSent?(sentFixKeys)
            onSubmitted(nil)
            Haptics.success()
            dismiss()
        }
        if github.isConfigured {
            manualFooter
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var manualFooter: Text {
        Text("In GitHub's editor, select all of the file's text and paste, then tap Commit/Propose changes and open the pull request. Submitted segments stay hidden here until TravelMapping's nightly update picks them up.")
    }

    private func copyLinesSection(_ result: ListFileMerger.Result) -> some View {
        Section {
            Button {
                // A widened line is copied in its new form, marked with what it replaces
                UIPasteboard.general.string = result.placements.map { placement in
                    placement.extended.map { "\($0.to)  # replaces: " + ([$0.from] + placement.absorbed).joined(separator: " and ") } ?? placement.line.text
                }.joined(separator: "\n")
                copiedLines = true
                breadcrumb("Copied new list lines only")
                Haptics.success()
            } label: {
                Label(copiedLines ? "Copied" : "Copy only the new lines", systemImage: copiedLines ? "checkmark" : "text.badge.plus")
            }
        } footer: {
            Text("If you'd rather place them yourself.")
        }
    }

    /// Replacement keys (as passed in) whose line was found and changed
    private var sentFixKeys: [String] {
        replacements.keys.filter { appliedFixes.contains(ListFileMerger.normalizedLine($0)) }
    }

    private var sentSummary: String {
        var parts: [String] = []
        if sentLineCount > 0 { parts.append("\(sentLineCount.formatted()) added segment\(sentLineCount == 1 ? "" : "s")") }
        if !appliedFixes.isEmpty { parts.append("\(appliedFixes.count) fixed line\(appliedFixes.count == 1 ? "" : "s")") }
        return parts.joined(separator: " and ") + (sentLineCount + appliedFixes.count == 1 ? " is" : " are")
    }

    private func prOpenedSection(_ pr: ListUpdatePR) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(openPR != nil ? "Added to pull request #\(pr.number)" : "Pull request #\(pr.number) opened",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(TMDesign.greenChipFG)
                Text(openedAsDraft
                     ? sentSummary + " in a draft pull request. Check it on GitHub, then tap “Ready for review” there so the TravelMapping team can merge it."
                     : sentSummary + " waiting for the TravelMapping team to merge. Once they do, the next nightly update adds them to your stats.")
                    .font(.system(size: 15))
                    .foregroundStyle(TMDesign.secondaryText)
            }
            .padding(.vertical, 4)
            Link(destination: pr.url) {
                Label("View on GitHub", systemImage: "arrow.up.forward.app")
            }
        }
    }

    // MARK: Actions

    private func load() async {
        errorMessage = nil
        if github.isSignedIn {
            let fileExtension = category.fileExtension
            let candidates = await TripStorageService.shared.listSubmissions()
                .filter { $0.fileExtension == fileExtension }
                .compactMap(\.pr)
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(3)
            for pr in candidates where pr.branch != nil {
                if (try? await github.pullRequestState(pr.number))?.isOpen == true {
                    openPR = pr
                    break
                }
            }
        }
        do {
            let existing = try await DataService.fetchCurrentListText(username: username, category: category)
            hasExistingFile = existing != nil
            let (text, applied) = ListFileMerger.applyReplacements(existing ?? "", replacements)
            appliedFixes = applied
            let lines = lines
            let blockTitle = blockTitle
            let appendOnly = appendOnly
            result = await Task.detached(priority: .userInitiated) {
                ListFileMerger.merge(existing: text, newLines: lines, blockTitle: blockTitle, appendOnly: appendOnly)
            }.value
        } catch {
            SentrySDK.capture(error: error)
            errorMessage = "Couldn't download your current \(fileName) from GitHub. Check your connection and try again."
        }
    }

    private func openPullRequest() async {
        prError = nil
        defer { isOpeningPR = false }
        do {
            let (pr, merge) = try await github.submitListUpdate(
                username: username,
                category: category,
                lines: lines,
                blockTitle: blockTitle,
                appendOnly: appendOnly,
                tripNames: tripNames,
                replacements: replacements,
                appendingTo: openPR,
                asDraft: openAsDraft
            )
            sentLineCount = merge.placements.count
            // A fresh PR follows the toggle; lines added to an open PR keep that PR's state
            openedAsDraft = pr.number != openPR?.number && openAsDraft
            if pr.number != openPR?.number { openPR = nil }  // a new PR was opened after all
            openedPR = pr
            onFixesSent?(sentFixKeys)
            onSubmitted(pr)
            Haptics.success()
        } catch {
            prError = error.localizedDescription
        }
    }

    // MARK: Helpers

    private func placementDetail(_ placement: ListFileMerger.Placement) -> String {
        var detail = placement.extended != nil
            ? "Extends your line \(placement.lineNumber.formatted())"
            : "Line \(placement.lineNumber.formatted())"
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
