import SwiftUI
import CoreLocation
import Sentry

struct RoadTripListView: View {
    @ObservedObject private var recorder = TripRecordingService.shared
    @State private var trips: [RoadTrip] = []
    @State private var isLoading = true
    @State private var tripToDelete: RoadTrip?
    @State private var showOrphanedDialog = false
    @State private var showLocationDeniedAlert = false
    @State private var showTripTypeChooser = false
    @State private var pendingSummary: (lines: Int, trips: Int, waiting: Int)?
    /// The last pending check couldn't reach TravelMapping — the tile must not claim "up to date"
    @State private var pendingCheckFailed = false
    /// Bumped on reappear; `.task(id:)` cancels a still-running refresh when it changes
    @State private var refreshToken = 0
    /// Inputs of the last summary — re-analysis is skipped when nothing changed
    @State private var summarySignature = ""
    @ObservedObject private var settings = SyncedSettingsService.shared
    @State private var searchText = ""
    /// Distance and route shape per trip, computed off the main thread from GPS points
    @State private var summaries: [UUID: TripSummary] = [:]
    /// Segments not in the user's list yet, per trip — shown as a chip on the trip card
    @State private var newLinesByTrip: [UUID: Int] = [:]

    private var locationPermissionDenied: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .denied || status == .restricted
    }

    /// Empty state replaces both the start section and the past-trips placeholder (audit §11).
    private var showEmptyState: Bool {
        !isLoading && trips.isEmpty && !recorder.isRecording
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if recorder.isRecording {
                    recordingCard
                }
                if showEmptyState {
                    emptyStateCard
                } else {
                    if searchText.isEmpty && !isLoading {
                        heroCard
                        if !settings.primaryUser.isEmpty {
                            actionTiles
                        }
                    }
                    tripSections
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .searchable(text: $searchText, prompt: "Trips, routes or notes")
        .navigationTitle("Road Trips")
        .alert("Delete Trip?", isPresented: Binding(
            get: { tripToDelete != nil },
            set: { if !$0 { tripToDelete = nil } }
        ), presenting: tripToDelete) { trip in
            Button("Cancel", role: .cancel) {
                tripToDelete = nil
            }
            Button("Delete", role: .destructive) {
                performDelete(trip: trip)
                tripToDelete = nil
            }
        } message: { trip in
            Text("Delete \"\(trip.name)\"? This will also delete \(trip.rawPoints.count.formatted()) GPS points and the exported .list file. This cannot be undone.")
        }
        .alert("Unfinished Trip Found", isPresented: $showOrphanedDialog, presenting: recorder.orphanedTrip) { trip in
            Button("Keep") {
                Task {
                    await recorder.finalizeOrphanedTrip()
                    await loadTrips()
                }
            }
            Button("Discard", role: .destructive) {
                Task {
                    await recorder.discardOrphanedTrip()
                    await loadTrips()
                }
            }
        } message: { trip in
            Text("\"\(trip.name)\" was interrupted with \(trip.rawPoints.count.formatted()) GPS points. Save it as completed, or discard?")
        }
        .alert("Location Access Needed", isPresented: $showLocationDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Trip recording needs location access to detect which routes you travel. Enable location for Travel Mapping in Settings.")
        }
        .onChange(of: recorder.orphanedTrip?.id) {
            showOrphanedDialog = recorder.orphanedTrip != nil
        }
        .task {
            // The orphaned trip is detected at app launch — before this view exists — so
            // onChange alone never fires for it. Check the current value on first load too.
            if recorder.orphanedTrip != nil {
                showOrphanedDialog = true
            }
            await loadTrips()
        }
        .refreshable {
            await loadTrips()
        }
        .onAppear {
            // Returning from a trip detail where lines may have been marked submitted
            guard !isLoading else { return }
            refreshToken += 1
        }
        .task(id: refreshToken) {
            guard refreshToken > 0 else { return }
            await loadTrips()
        }
        .onChange(of: settings.primaryUser) {
            refreshToken += 1
        }
        // Segments dismissed here or on another device (iCloud)
        .onChange(of: settings.dismissedHopKeys) {
            refreshToken += 1
        }
    }

    // MARK: Sections

    private var recordingCard: some View {
        NavigationLink {
            RoadTripRecordingView()
        } label: {
            HStack(spacing: 12) {
                TMPulsingDot(color: TMDesign.rail, size: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recorder.currentTrip?.name ?? "Recording...")
                        .font(.system(size: 17, weight: .bold))
                    Text("\(recorder.elapsedFormatted) · \(recorder.pointCount.formatted()) points")
                        .font(.system(size: 15))
                        .monospacedDigit()
                        .foregroundStyle(TMDesign.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TMDesign.chevron)
            }
            .padding(16)
            .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recording in progress: \(recorder.currentTrip?.name ?? "trip"). Tap to view.")
    }

    /// Lifetime totals over every recorded trip, with the one primary action under them
    private var heroCard: some View {
        let completed = trips.filter { $0.status == .completed }
        let meters = completed.reduce(0) { $0 + (summaries[$1.id]?.distanceMeters ?? 0) }
        // By root base name so il.i090 / in.i090 count as one route (I-90)
        let routes = Set(completed.flatMap { $0.matchedSegments.map { $0.root.split(separator: ".").last.map(String.init) ?? $0.root } }).count
        return VStack(spacing: 16) {
            HStack(spacing: 0) {
                heroStat(completed.count.formatted(), completed.count == 1 ? "Trip" : "Trips")
                Divider().frame(height: 34)
                heroStat(Int((meters / (settings.useMiles ? 1609.344 : 1000)).rounded()).formatted(),
                         settings.useMiles ? "Miles" : "Kilometers")
                Divider().frame(height: 34)
                heroStat(routes.formatted(), routes == 1 ? "Route" : "Routes")
            }
            if !recorder.isRecording {
                startTripButton
            }
        }
        .padding(16)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func heroStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .heavy))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TMDesign.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// The two .list tools side by side instead of stacked rows
    private var actionTiles: some View {
        HStack(alignment: .top, spacing: 12) {
            NavigationLink {
                PendingListUpdatesView(trips: trips, username: settings.primaryUser) {
                    await loadTrips()
                }
            } label: {
                if let pending = pendingSummary, pending.lines > 0 {
                    actionTile(icon: "text.badge.plus", fg: TMDesign.amberChipFG, bg: TMDesign.amberChipBG,
                               title: "\(pending.lines.formatted()) new segment\(pending.lines == 1 ? "" : "s")",
                               subtitle: "Not in your list yet · from \(pending.trips.formatted()) trip\(pending.trips == 1 ? "" : "s")")
                } else if let pending = pendingSummary, pending.waiting > 0 {
                    actionTile(icon: "paperplane.fill", fg: TMDesign.purpleChipFG, bg: TMDesign.purpleChipBG,
                               title: "\(pending.waiting.formatted()) line\(pending.waiting == 1 ? "" : "s") sent",
                               subtitle: "Waiting on TravelMapping")
                } else if pendingCheckFailed {
                    actionTile(icon: "exclamationmark.icloud", fg: TMDesign.neutralChipFG, bg: TMDesign.neutralChipBG,
                               title: "Your .list", subtitle: "Couldn't check your trips")
                } else if pendingSummary == nil {
                    actionTile(icon: "text.magnifyingglass", fg: TMDesign.neutralChipFG, bg: TMDesign.neutralChipBG,
                               title: "Your .list", subtitle: "Checking your trips…")
                } else {
                    actionTile(icon: "checkmark.seal.fill", fg: TMDesign.greenChipFG, bg: TMDesign.greenChipBG,
                               title: "List up to date", subtitle: "Nothing new from your trips")
                }
            }
            .buttonStyle(.plain)

            NavigationLink {
                ListCheckupView(username: settings.primaryUser)
            } label: {
                actionTile(icon: "stethoscope", fg: TMDesign.blueChipFG, bg: TMDesign.blueChipBG,
                           title: "List checkup", subtitle: "Lines that didn't count last night")
            }
            .buttonStyle(.plain)
        }
    }

    private func actionTile(icon: String, fg: Color, bg: Color, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(fg)
                .frame(width: 34, height: 34)
                .background(bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(TMDesign.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .padding(14)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Trips matching the search: name, notes, or any route driven ("I-94", "NL")
    private var filteredTrips: [RoadTrip] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return trips }
        return trips.filter { trip in
            trip.name.localizedCaseInsensitiveContains(query)
                || trip.notes.localizedCaseInsensitiveContains(query)
                || trip.matchedSegments.contains { $0.listName.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Trips grouped by month, newest first — long histories scan by date instead of one long list
    private var monthGroups: [(month: Date, trips: [RoadTrip])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredTrips) {
            calendar.date(from: calendar.dateComponents([.year, .month], from: $0.startDate)) ?? $0.startDate
        }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    @ViewBuilder
    private var tripSections: some View {
        if isLoading {
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    TMSkeletonRow()
                        .padding(.horizontal, 14)
                        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        } else if filteredTrips.isEmpty {
            if searchText.isEmpty {
                // Only reachable while recording the first trip
                Text("Your first trip will show up here when you stop recording.")
                    .font(.system(size: 15))
                    .foregroundStyle(TMDesign.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        } else {
            ForEach(monthGroups, id: \.month) { group in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.month.formatted(.dateTime.month(.wide).year()))
                            .font(.system(size: 20, weight: .bold))
                        Spacer()
                        Text(monthDetail(group.trips))
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(TMDesign.secondaryText)
                    }
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)

                    ForEach(group.trips) { trip in
                        NavigationLink {
                            RoadTripDetailView(trip: trip)
                        } label: {
                            TripCard(trip: trip, summary: summaries[trip.id],
                                     newLines: newLinesByTrip[trip.id] ?? 0, useMiles: settings.useMiles)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                tripToDelete = trip
                            } label: {
                                Label("Delete Trip", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func monthDetail(_ trips: [RoadTrip]) -> String {
        let meters = trips.reduce(0) { $0 + (summaries[$1.id]?.distanceMeters ?? 0) }
        let distance = Int((meters / (settings.useMiles ? 1609.344 : 1000)).rounded())
        return "\(trips.count.formatted()) trip\(trips.count == 1 ? "" : "s") · \(distance.formatted()) \(settings.useMiles ? "mi" : "km")"
    }

    /// Single entry point (audit §4): one Start Trip button opening a Road/Rail choice.
    /// The location-permission check gates both choices.
    private var startTripButton: some View {
        Button {
            requestStartTrip()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("Start Trip")
                    .font(.system(size: 17, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .background(TMDesign.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Choose road or rail, then GPS tracking records which routes you travel")
        .tripTypeChooser(isPresented: $showTripTypeChooser, startTrip: startTrip)
    }

    /// Empty state per audit §11 — "Record your first drive".
    private var emptyStateCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(TMDesign.blueChipBG)
                    .frame(width: 76, height: 76)
                Image(systemName: "car.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TMDesign.blueChipFG)
            }
            .accessibilityHidden(true)

            Text("Record your first drive")
                .font(.system(size: 18, weight: .heavy))

            Text("Start a trip and your GPS quietly matches the TM routes you travel — no tapping required.")
                .font(.system(size: 15))
                .foregroundStyle(TMDesign.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                requestStartTrip()
            } label: {
                Label("Start a trip", systemImage: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 13)
                    .background(TMDesign.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .tripTypeChooser(isPresented: $showTripTypeChooser, startTrip: startTrip)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 18)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // The chooser is attached to the trigger buttons (only one exists in the tree
    // at a time), NOT chained on the List with the three alerts — four presentation
    // modifiers chained on one node silently drop the confirmationDialog, the same
    // failure class as the documented Section-chained-alerts bug.
    private func requestStartTrip() {
        if locationPermissionDenied {
            showLocationDeniedAlert = true
        } else {
            showTripTypeChooser = true
        }
    }

    private func startTrip(_ type: TripType) {
        // Re-check here too so both dialog choices are gated even if permission
        // changed while the chooser was up.
        if locationPermissionDenied {
            showLocationDeniedAlert = true
        } else {
            Haptics.success()
            recorder.startTrip(tripType: type)
        }
    }

    private func loadTrips() async {
        let loaded = (try? await TripStorageService.shared.listTrips()) ?? []
        // Newest trip first by when it happened — file modification order changes
        // whenever a trip is re-saved (notes edits, iCloud sync)
        trips = loaded.filter { $0.status != .recording }.sorted { $0.startDate > $1.startDate }
        let missing = trips.filter { summaries[$0.id]?.pointCount != $0.rawPoints.count }
        if !missing.isEmpty {
            let inputs = missing.map { ($0.id, $0.rawPoints) }
            let computed = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: inputs.map { ($0.0, TripSummary(points: $0.1)) })
            }.value
            summaries.merge(computed) { _, new in new }
        }
        isLoading = false
        await loadPendingSummary()
    }

    /// Counts trip segments not yet in the user's list files (road and rail separately,
    /// since they live in different files).
    private func loadPendingSummary() async {
        let username = settings.primaryUser
        let candidates = trips.filter { $0.status == .completed && !$0.matchedSegments.isEmpty }
        let storage = TripStorageService.shared
        guard !username.isEmpty, !candidates.isEmpty else {
            // Nothing to check — a settled state, not "Checking…"
            pendingCheckFailed = false
            pendingSummary = (0, 0, await storage.listSubmissions().reduce(0) { $0 + $1.lines.count })
            newLinesByTrip = [:]
            summarySignature = ""
            return
        }
        let roadKeys = await storage.submittedHopKeys(fileExtension: "list")
        let railKeys = await storage.submittedHopKeys(fileExtension: "rlist")
        let dismissed = Set(settings.dismissedHopKeys)
        let waiting = await storage.listSubmissions().reduce(0) { $0 + $1.lines.count }
        let signature = "\(waiting)|\(username)|\(candidates.map { "\($0.id)\($0.matchedSegments.count)" }.sorted().joined())|\(roadKeys.count)|\(railKeys.count)|\(dismissed.sorted().joined(separator: ","))"
        guard signature != summarySignature || pendingSummary == nil || pendingCheckFailed else { return }

        var lines = 0
        var tripIDs = Set<UUID>()
        var byTrip: [UUID: Int] = [:]
        var loggedKeys = Set<String>()
        var failed = false
        for type in [TripType.road, .rail] {
            let typed = candidates.filter { $0.tripType == type }
            guard !typed.isEmpty else { continue }
            guard let analysis = try? await TripLogAnalyzer.analyze(
                    trips: typed, username: username,
                    submittedKeys: type == .rail ? railKeys : roadKeys, dismissedKeys: dismissed) else {
                failed = true
                continue
            }
            lines += analysis.newRanges.count
            tripIDs.formUnion(analysis.newRanges.flatMap(\.tripIDs))
            for id in analysis.newRanges.flatMap(\.tripIDs) { byTrip[id, default: 0] += 1 }
            loggedKeys.formUnion(analysis.loggedRanges.flatMap(\.hopKeys))
        }
        guard !Task.isCancelled else { return }
        pendingCheckFailed = failed && lines == 0
        // Clear submissions the nightly update has picked up, so "waiting" goes away on its own
        let logged = loggedKeys
        await storage.removeSubmissions { !$0.hopKeys.isEmpty && $0.hopKeys.allSatisfy(logged.contains) }
        // A dismissed segment now in the list file needs no dismissal — keeps the iCloud list small
        let nowLogged = dismissed.intersection(logged)
        if !nowLogged.isEmpty { settings.restoreHops(Array(nowLogged)) }
        let stillWaiting = await storage.listSubmissions().reduce(0) { $0 + $1.lines.count }
        pendingSummary = (lines, tripIDs.count, stillWaiting)
        newLinesByTrip = byTrip
        // A failed check leaves the signature unset so the next load retries it
        summarySignature = failed ? "" : signature
    }

    private func performDelete(trip: RoadTrip) {
        Task {
            try? await TripStorageService.shared.delete(id: trip.id)
            await MainActor.run {
                trips.removeAll { $0.id == trip.id }
                summaries[trip.id] = nil
                refreshToken += 1
            }
        }
    }
}

/// Distance and a normalized outline of a trip's GPS track, for the list cards
struct TripSummary: Sendable {
    let distanceMeters: Double
    /// Track shape in a unit square (aspect kept, y down), at most ~80 points
    let shape: [CGPoint]
    let pointCount: Int

    init(points: [GPSPoint]) {
        pointCount = points.count
        let coords = points.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < 200 }.map(\.coordinate)
        var total = 0.0
        for (a, b) in zip(coords, coords.dropFirst()) {
            total += CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
        distanceMeters = total

        guard coords.count > 1 else { shape = []; return }
        let stride = max(1, coords.count / 80)
        let sampled = Swift.stride(from: 0, to: coords.count, by: stride).map { coords[$0] } + [coords[coords.count - 1]]
        let lats = sampled.map(\.latitude), lngs = sampled.map(\.longitude)
        let cosLat = cos(((lats.min()! + lats.max()!) / 2) * .pi / 180)
        let width = (lngs.max()! - lngs.min()!) * cosLat
        let height = lats.max()! - lats.min()!
        let span = max(width, height, 1e-6)
        // Center the shorter axis so the outline sits in the middle of the square
        let xOffset = (span - width) / 2, yOffset = (span - height) / 2
        shape = sampled.map {
            CGPoint(x: (($0.longitude - lngs.min()!) * cosLat + xOffset) / span,
                    y: (lats.max()! - $0.latitude + yOffset) / span)
        }
    }
}

/// The drive's outline drawn on a tile — recognizable at a glance without a map snapshot
struct RouteShapeThumbnail: View {
    let shape: [CGPoint]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard shape.count > 1 else { return }
            let inset: CGFloat = 10
            let side = min(size.width, size.height) - inset * 2
            var path = Path()
            path.addLines(shape.map { CGPoint(x: inset + $0.x * side, y: inset + $0.y * side) })
            context.stroke(path, with: .color(color.opacity(0.25)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            // Start as a solid dot, finish as a ringed one
            if let first = shape.first, let end = path.currentPoint {
                let start = CGPoint(x: inset + first.x * side, y: inset + first.y * side)
                let finish = Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7))
                context.fill(Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)), with: .color(color))
                context.fill(finish, with: .color(.white))
                context.stroke(finish, with: .color(color), lineWidth: 2)
            }
        }
        .background(TMDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct TripCard: View {
    let trip: RoadTrip
    let summary: TripSummary?
    let newLines: Int
    let useMiles: Bool

    private var isRail: Bool { trip.tripType == .rail }

    var body: some View {
        HStack(spacing: 14) {
            RouteShapeThumbnail(shape: summary?.shape ?? [], color: isRail ? TMDesign.rail : TMDesign.accent)
                .frame(width: 64, height: 64)
                .overlay(alignment: .topLeading) {
                    if summary?.shape.isEmpty ?? true {
                        Image(systemName: isRail ? "tram.fill" : "car.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isRail ? TMDesign.redChipFG : TMDesign.blueChipFG)
                            .frame(width: 64, height: 64)
                    }
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(trip.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(metadataLine)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(TMDesign.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 6) {
                    if !trip.matchedSegments.isEmpty {
                        TMChip(text: "\(trip.matchedSegments.count.formatted()) segment\(trip.matchedSegments.count == 1 ? "" : "s")",
                               icon: isRail ? "tram.fill" : "point.topleft.down.to.point.bottomright.curvepath",
                               bg: TMDesign.neutralChipBG, fg: TMDesign.neutralChipFG, fontSize: 11)
                    }
                    if newLines > 0 {
                        TMChip(text: "\(newLines.formatted()) new", icon: "plus",
                               bg: TMDesign.amberChipBG, fg: TMDesign.amberChipFG, fontSize: 11)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TMDesign.chevron)
        }
        .padding(12)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var metadataLine: String {
        var parts = [trip.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())]
        if let dur = trip.duration {
            let hours = Int(dur) / 3600, minutes = (Int(dur) % 3600) / 60
            parts.append(hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m")
        }
        if let meters = summary?.distanceMeters, meters > 0 {
            let value = meters / (useMiles ? 1609.344 : 1000)
            parts.append("\(value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)))) \(useMiles ? "mi" : "km")")
        }
        return parts.joined(separator: " · ")
    }
}

/// Road/Rail trip-type chooser, attached at the trigger button so it never shares a
/// presentation chain with the List's alerts (chained presentations silently fail).
private extension View {
    func tripTypeChooser(isPresented: Binding<Bool>, startTrip: @escaping (TripType) -> Void) -> some View {
        confirmationDialog("Start a trip", isPresented: isPresented, titleVisibility: .visible) {
            Button {
                startTrip(.road)
            } label: {
                Label("Road Trip", systemImage: "car.fill")
            }
            Button {
                startTrip(.rail)
            } label: {
                Label("Train Trip", systemImage: "tram.fill")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("GPS tracking detects which TM routes you travel — no tapping required.")
        }
    }
}

// MARK: - Pending .list updates

/// Every traveled-but-not-logged segment across all recorded trips, deduplicated,
/// grouped by region, ready to merge into the user's list files.
struct PendingListUpdatesView: View {
    let trips: [RoadTrip]
    let username: String
    let onTripsChanged: () async -> Void

    @State private var road: TripLogAnalysis?
    @State private var rail: TripLogAnalysis?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var excludedRangeIDs: Set<String> = []
    @State private var sheetType: TripType?
    @State private var localTrips: [RoadTrip] = []
    @State private var prStates: [Int: GitHubService.PRState] = [:]
    @State private var submissions: [ListSubmission] = []
    @State private var preview: RangePreview?
    @ObservedObject private var settings = SyncedSettingsService.shared

    /// A pending line shown on the map of a trip that drove it, to check it's real
    struct RangePreview: Identifiable {
        let trip: RoadTrip
        let range: TripLogRange
        var id: String { "\(trip.id)|\(range.id)" }
    }

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Comparing your trips with your list files…")
                            .foregroundStyle(TMDesign.secondaryText)
                    }
                }
            } else if let errorMessage {
                Section {
                    Text(errorMessage)
                    Button("Try Again") { Task { await analyze() } }
                }
            } else {
                if let road, !road.newRanges.isEmpty {
                    typeSections(road, type: .road)
                }
                if let rail, !rail.newRanges.isEmpty {
                    typeSections(rail, type: .rail)
                }
                if (road?.newRanges.isEmpty ?? true) && (rail?.newRanges.isEmpty ?? true) {
                    Section {
                        Text("All caught up — every recorded segment is in your list files, already submitted, or marked not traveled.")
                            .foregroundStyle(TMDesign.secondaryText)
                    }
                }
            }
            let dismissed = (road?.dismissedRanges ?? []) + (rail?.dismissedRanges ?? [])
            if !isLoading, !dismissed.isEmpty {
                Section {
                    ForEach(dismissed) { range in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(range.line.text)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(TMDesign.secondaryText)
                            Text(tripNames(for: range))
                                .font(.system(size: 12))
                                .foregroundStyle(TMDesign.tertiaryText)
                        }
                        .swipeActions {
                            Button("Restore") { setDismissed([range], false) }
                                .tint(TMDesign.accent)
                        }
                        .contextMenu {
                            Button {
                                setDismissed([range], false)
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
                } header: {
                    Text("Didn't Travel")
                } footer: {
                    Text("Segments you said you didn't travel stay out of your updates. Swipe or touch and hold one to restore it.")
                }
            }
            if !submissions.isEmpty {
                Section {
                    ForEach(submissions.sorted { $0.date > $1.date }) { submission in
                        Group {
                            if let pr = submission.pr {
                                ListUpdatePRRow(pr: pr, state: prStates[pr.number])
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Marked submitted · \(submission.lines.count.formatted()) line\(submission.lines.count == 1 ? "" : "s")")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(submission.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.system(size: 13))
                                        .foregroundStyle(TMDesign.tertiaryText)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Not Sent") {
                                Task { await unmark(submission.id) }
                            }
                            .tint(TMDesign.frontier)
                        }
                        .contextMenu {
                            Button {
                                Task { await unmark(submission.id) }
                            } label: {
                                Label("Not Sent — Put Back in Queue", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
                } header: {
                    Text("Waiting on TravelMapping")
                } footer: {
                    Text("These clear on their own once TravelMapping's nightly update includes them. Swipe or touch and hold one to put its segments back in the queue — a closed pull request does that automatically.")
                }
            }
        }
        .navigationTitle("Pending .list Updates")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $preview) { item in
            TripFullScreenMap(
                trip: item.trip,
                ranges: [item.range],
                replayProgress: .constant(1),
                isPlaying: .constant(false),
                onTogglePlay: {},
                onStopPlay: {},
                focus: item.range.coordinates,
                showsReplay: false
            )
        }
        .sentryScreen("PendingListUpdates")
        .sheet(item: $sheetType) { type in
            ListUpdateSheet(
                lines: included(type == .rail ? rail : road).map(\.line),
                username: username,
                category: type == .rail ? .rail : .road,
                blockTitle: "\(Date().formatted(.iso8601.year().month().day())) recorded trips",
                tripNames: tripNames(in: included(type == .rail ? rail : road)),
                onSubmitted: { pr in markSubmitted(included(type == .rail ? rail : road), pr: pr, type: type) }
            )
        }
        .task {
            localTrips = trips
            await analyze()
            await refreshPRStates()
        }
        .onChange(of: settings.dismissedHopKeys) {
            Task { await analyze() }
        }
        .refreshable {
            prStates = [:]
            await analyze()
            await refreshPRStates()
        }
    }

    @ViewBuilder
    private func typeSections(_ analysis: TripLogAnalysis, type: TripType) -> some View {
        let grouped = Dictionary(grouping: analysis.newRanges, by: \.region)
        Section {
            Button {
                Haptics.light()
                sheetType = type
            } label: {
                Label("Update my .\(type == .rail ? "rlist" : "list") (\(included(analysis).count.formatted()) lines)",
                      systemImage: "square.and.pencil")
                    .font(.system(size: 16, weight: .semibold))
            }
            .disabled(included(analysis).isEmpty)
        } header: {
            Text(type == .rail ? "Rail & Transit" : "Roads")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if analysis.unresolvedCount > 0 {
                    Text("\(analysis.unresolvedCount.formatted()) recorded segments couldn't be matched to current route data.")
                }
                if analysis.unverifiedCount > 0 {
                    Text("\(analysis.unverifiedCount.formatted()) more segment\(analysis.unverifiedCount == 1 ? " wasn't" : "s weren't") followed end to end by your GPS track, so \(analysis.unverifiedCount == 1 ? "it was" : "they were") left out.")
                }
            }
        }
        ForEach(grouped.keys.sorted(), id: \.self) { region in
            Section(region) {
                ForEach(grouped[region] ?? []) { range in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
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
                            Text(tripNames(for: range))
                                .font(.system(size: 12))
                                .foregroundStyle(TMDesign.tertiaryText)
                                .padding(.leading, 28)
                        }
                        previewButton(for: range)
                    }
                    .swipeActions {
                        Button("Didn't Travel") { setDismissed([range], true) }
                            .tint(TMDesign.frontier)
                    }
                    .contextMenu {
                        Button {
                            setDismissed([range], true)
                        } label: {
                            Label("Didn't Travel This", systemImage: "eye.slash")
                        }
                    }
                }
            }
        }
    }

    /// Map button: the segment on the trip that recorded it (a menu when several did)
    @ViewBuilder
    private func previewButton(for range: TripLogRange) -> some View {
        let drove = localTrips.filter { range.tripIDs.contains($0.id) }.sorted { $0.startDate > $1.startDate }
        let icon = Image(systemName: "map")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(TMDesign.accent)
            .frame(width: 40, height: 40)
            .background(TMDesign.blueChipBG, in: Circle())
        if drove.count > 1 {
            Menu {
                ForEach(drove) { trip in
                    Button(trip.name) { preview = RangePreview(trip: trip, range: range) }
                }
            } label: { icon }
            .accessibilityLabel("Show on a trip map")
        } else if let trip = drove.first {
            Button {
                Haptics.light()
                preview = RangePreview(trip: trip, range: range)
            } label: { icon }
            .buttonStyle(.plain)
            .accessibilityLabel("Show on the map of \(trip.name)")
        }
    }

    private func included(_ analysis: TripLogAnalysis?) -> [TripLogRange] {
        (analysis?.newRanges ?? []).filter { !excludedRangeIDs.contains($0.id) }
    }

    private func tripNames(for range: TripLogRange) -> String {
        localTrips.filter { range.tripIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
    }

    private func refreshPRStates() async {
        var closed: [Int] = []
        for pr in submissions.compactMap(\.pr) where prStates[pr.number] == nil {
            let state = try? await GitHubService.shared.pullRequestState(pr.number)
            prStates[pr.number] = state
            if state == .closed { closed.append(pr.number) }
        }
        // A closed (unmerged) PR will never land — put its segments back in the queue
        guard !closed.isEmpty else { return }
        let closedNumbers = closed
        await TripStorageService.shared.removeSubmissions { closedNumbers.contains($0.pr?.number ?? -1) }
        await analyze()
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
        crumb.message = "\(dismissed ? "Dismissed" : "Restored") \(ranges.count) ranges in pending queue"
        SentrySDK.addBreadcrumb(crumb)
        // Re-analysis runs from onChange(of: dismissedHopKeys); this refreshes the trip list
        Task { await onTripsChanged() }
    }

    private func unmark(_ id: UUID) async {
        await TripStorageService.shared.removeSubmissions { $0.id == id }
        await analyze()
        await onTripsChanged()
    }

    private func analyze() async {
        errorMessage = nil
        let storage = TripStorageService.shared
        let candidates = localTrips.filter { $0.status == .completed && !$0.matchedSegments.isEmpty }
        do {
            let roadTrips = candidates.filter { $0.tripType == .road }
            let railTrips = candidates.filter { $0.tripType == .rail }
            road = roadTrips.isEmpty ? nil : try await TripLogAnalyzer.analyze(
                trips: roadTrips, username: username,
                submittedKeys: await storage.submittedHopKeys(fileExtension: "list"),
                dismissedKeys: Set(settings.dismissedHopKeys))
            rail = railTrips.isEmpty ? nil : try await TripLogAnalyzer.analyze(
                trips: railTrips, username: username,
                submittedKeys: await storage.submittedHopKeys(fileExtension: "rlist"),
                dismissedKeys: Set(settings.dismissedHopKeys))

            // Submissions whose every segment the database now reports as logged are done
            let logged = Set(((road?.loggedRanges ?? []) + (rail?.loggedRanges ?? [])).flatMap(\.hopKeys))
            await storage.removeSubmissions { !$0.hopKeys.isEmpty && $0.hopKeys.allSatisfy(logged.contains) }
            let nowLogged = Set(settings.dismissedHopKeys).intersection(logged)
            if !nowLogged.isEmpty { settings.restoreHops(Array(nowLogged)) }
            submissions = await storage.listSubmissions()
        } catch {
            SentrySDK.capture(error: error)
            errorMessage = "Couldn't check your list files right now."
        }
        isLoading = false
    }

    private func tripNames(in ranges: [TripLogRange]) -> [String] {
        let ids = Set(ranges.flatMap(\.tripIDs))
        return localTrips.filter { ids.contains($0.id) }.sorted { $0.startDate < $1.startDate }.map(\.name)
    }

    private func markSubmitted(_ ranges: [TripLogRange], pr: ListUpdatePR?, type: TripType) {
        let crumb = Breadcrumb(level: .info, category: "list_update")
        crumb.message = "Marked \(ranges.count) ranges submitted from pending queue"
        SentrySDK.addBreadcrumb(crumb)
        Task {
            await TripStorageService.shared.recordSubmission(
                fileExtension: type == .rail ? "rlist" : "list",
                hopKeys: ranges.flatMap(\.hopKeys),
                lines: ranges.map(\.line.text),
                pr: pr
            )
            excludedRangeIDs = []
            await analyze()
            await onTripsChanged()
        }
    }
}

struct ListUpdatePRRow: View {
    let pr: ListUpdatePR
    let state: GitHubService.PRState?

    var body: some View {
        Link(destination: pr.url) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.pull")
                    .foregroundStyle(TMDesign.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(pr.number) · \(pr.lineCount.formatted()) line\(pr.lineCount == 1 ? "" : "s")")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(pr.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 13))
                        .foregroundStyle(TMDesign.tertiaryText)
                }
                Spacer()
                if let state {
                    switch state {
                    case .open:
                        TMChip(text: "Open", bg: TMDesign.blueChipBG, fg: TMDesign.blueChipFG)
                    case .draft:
                        // Not up for review until the user marks it ready on GitHub
                        TMChip(text: "Draft · mark ready", bg: TMDesign.amberChipBG, fg: TMDesign.amberChipFG)
                    case .merged:
                        TMChip(text: "Merged", icon: "checkmark", bg: TMDesign.purpleChipBG, fg: TMDesign.purpleChipFG)
                    case .closed:
                        TMChip(text: "Closed", bg: TMDesign.redChipBG, fg: TMDesign.redChipFG)
                    }
                }
            }
        }
        .accessibilityLabel("Pull request \(pr.number), \(pr.lineCount) lines, \(state?.rawValue ?? "")")
    }
}

extension TripType: Identifiable {
    public var id: String { rawValue }
}

// MARK: - List checkup

/// Lines of the user's list file that TravelMapping's last nightly update couldn't use,
/// with fixes checked against current route data. AI suggestions are optional and only
/// run with the user's own key and permission.
struct ListCheckupView: View {
    let username: String

    @ObservedObject private var ai = AIService.shared
    @State private var category: RouteCategory = .road
    @State private var result: ListCheckup.Result?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var excluded: Set<String> = []
    @State private var aiTask: Task<Void, Never>?
    @State private var aiMessage: String?
    @State private var showConsent = false
    @State private var showUpdate = false
    @State private var pickerFix: CheckupFix?
    /// Lines whose fix was sent, so they don't show as open until the next nightly update
    @AppStorage("checkupSentLines") private var sentLinesData = Data()
    /// Flagged lines an open GitHub PR already changes (any device, or made on github.com)
    @State private var prLines: [String: ListUpdatePR] = [:]
    @State private var prCheckFailed = false

    private var fixes: [CheckupFix] { result?.fixes ?? [] }

    private var sentLines: [String: Date] {
        (try? JSONDecoder().decode([String: Date].self, from: sentLinesData)) ?? [:]
    }

    private func openPR(for fix: CheckupFix) -> ListUpdatePR? {
        prLines[ListFileMerger.normalizedLine(fix.issue.line)]
    }

    /// Already sent from this device, or changed by an open PR — leave it alone until TM updates
    private func isPending(_ fix: CheckupFix) -> Bool {
        sentLines[fix.issue.line] != nil || openPR(for: fix) != nil
    }

    private var selectedFixes: [CheckupFix] {
        fixes.filter { $0.replacement != nil && !excluded.contains($0.id) && !isPending($0) }
    }

    /// Fixes AI could help with: no fix yet, but the route's waypoints are known
    private var needsSuggestion: [CheckupFix] {
        fixes.filter { $0.replacement == nil && $0.canPickWaypoints && !isPending($0) }
    }

    var body: some View {
        List {
            Section {
                Picker("List", selection: $category) {
                    Text("Roads").tag(RouteCategory.road)
                    Text("Rail & Transit").tag(RouteCategory.rail)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                if prCheckFailed && !isLoading {
                    Label("Couldn't check your open pull requests on GitHub — lines already fixed there may show again.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
            }

            if isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading TravelMapping's report for \(username)…")
                            .sentryReplayMask()
                            .foregroundStyle(TMDesign.secondaryText)
                    }
                }
            } else if let errorMessage {
                Section {
                    Text(errorMessage)
                    Button("Try Again") { Task { await load() } }
                }
            } else if fixes.isEmpty {
                Section {
                    Label("Every line counted in the last update.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(TMDesign.greenChipFG)
                } footer: {
                    if let updated = result?.fileUpdated { Text(updated) }
                }
            } else {
                Section {
                    ForEach(fixes) { fix in
                        CheckupFixRow(
                            fix: fix,
                            isIncluded: !excluded.contains(fix.id),
                            sentDate: sentLines[fix.issue.line],
                            openPR: openPR(for: fix),
                            onToggle: {
                                if excluded.contains(fix.id) { excluded.remove(fix.id) } else { excluded.insert(fix.id) }
                            },
                            onPick: { pickerFix = fix },
                            onCommentOut: { setReplacement(fix.id, "#" + fix.issue.line, .manual, "Commented out — kept in your file for reference.") }
                        )
                    }
                } header: {
                    Text("\(fixes.count) line\(fixes.count == 1 ? "" : "s") didn't count")
                } footer: {
                    Text("TravelMapping checks your list every night. These lines were skipped in the last update\(result?.fileUpdated.map { " (\($0))" } ?? ""), so those miles aren't in your stats.")
                }

                if !needsSuggestion.isEmpty {
                    aiSection
                }

                Section {
                    Button {
                        Haptics.light()
                        showUpdate = true
                    } label: {
                        Label("Update my .\(category.fileExtension) (\(selectedFixes.count) fix\(selectedFixes.count == 1 ? "" : "es"))",
                              systemImage: "square.and.pencil")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .disabled(selectedFixes.isEmpty)
                } footer: {
                    Text("You'll see every change before anything is sent.")
                }
            }
        }
        .navigationTitle("List Checkup")
        .navigationBarTitleDisplayMode(.inline)
        .sentryScreen("ListCheckup")
        .task(id: category) { await load() }
        .refreshable { await load() }
        .onDisappear { aiTask?.cancel() }
        .sheet(item: $pickerFix) { fix in
            WaypointPickerSheet(fix: fix) { line in
                setReplacement(fix.id, line, .manual, nil)
            }
        }
        .sheet(isPresented: $showConsent) {
            AIConsentSheet()
        }
        .sheet(isPresented: $showUpdate) {
            ListUpdateSheet(
                lines: [],
                username: username,
                category: category,
                blockTitle: "",
                tripNames: [],
                replacements: Dictionary(selectedFixes.compactMap { fix in fix.replacement.map { (fix.issue.line, $0) } },
                                         uniquingKeysWith: { a, _ in a }),
                onFixesSent: { applied in markSent(selectedFixes.filter { applied.contains($0.issue.line) }) },
                onSubmitted: { _ in }
            )
        }
    }

    @ViewBuilder
    private var aiSection: some View {
        Section {
            if ai.isReady {
                if aiTask != nil {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Asking \(ai.providerLabel)…")
                        Spacer()
                        Button("Cancel") {
                            aiTask?.cancel()
                            aiTask = nil
                        }
                    }
                } else {
                    Button {
                        if ai.consentDate == nil { showConsent = true } else { suggest() }
                    } label: {
                        Label("Suggest fixes with \(ai.providerLabel)", systemImage: "sparkles")
                    }
                }
            } else if ai.hasKey && ai.consentDate == nil && ai.isEnabled {
                Button {
                    showConsent = true
                } label: {
                    Label("Allow \(ai.providerLabel) to suggest fixes…", systemImage: "sparkles")
                }
            } else {
                NavigationLink {
                    AISettingsView()
                } label: {
                    Label(!ai.hasKey ? "Get suggested fixes with your own AI key"
                          : (ai.model.isEmpty ? "Choose an AI model to get suggestions" : "AI Assistant is off"),
                          systemImage: "sparkles")
                }
            }
            if let aiMessage {
                Text(aiMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .sentryReplayMask()
            }
        } header: {
            Text("Need help?")
        } footer: {
            if ai.isReady {
                Text("Sends the \(needsSuggestion.count) line\(needsSuggestion.count == 1 ? "" : "s") above that need waypoints, TravelMapping's notes, and public route data to \(ai.host). Suggestions use only real waypoints and change nothing until you send them. You can also pick waypoints yourself.")
            } else {
                Text("Pick new waypoints yourself with “Choose waypoints”, or connect your own AI key in Settings for suggestions.")
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        aiMessage = nil
        do {
            async let changed = GitHubService.shared.openPRChangedLines(username: username, category: category)
            result = try await ListCheckup.run(username: username, category: category)
            // On a failed check keep what we knew, and say so — the user may be about to
            // resend a fix that's already in an open PR
            if let changed = await changed {
                prLines = changed
                prCheckFailed = false
            } else {
                prCheckFailed = true
            }
            pruneSentLines()
        } catch {
            errorMessage = category == .rail
                ? "Couldn't read TravelMapping's rail report. If you don't have a .rlist file, there's nothing to check."
                : "Couldn't read TravelMapping's report for \(username). Check your connection and try again."
        }
        isLoading = false
    }

    private func suggest() {
        let pending = needsSuggestion
        let updates = result?.updates ?? []
        aiMessage = nil
        aiTask = Task {
            defer { aiTask = nil }
            do {
                let suggestions = try await ListCheckup.suggestFixes(pending, updates: updates)
                guard !Task.isCancelled else { return }
                for (id, suggestion) in suggestions {
                    setReplacement(id, suggestion.line, .ai, suggestion.reason)
                }
                let missed = pending.count - suggestions.count
                aiMessage = suggestions.isEmpty
                    ? "\(ai.providerLabel) didn't suggest any fix that uses real waypoints. Choose waypoints yourself instead."
                    : (missed > 0 ? "\(missed) line\(missed == 1 ? "" : "s") still need you to choose waypoints." : nil)
            } catch is CancellationError {
                aiMessage = "Cancelled — nothing else was sent."
            } catch let error as URLError where error.code == .cancelled {
                aiMessage = "Cancelled — nothing else was sent."
            } catch {
                aiMessage = error.localizedDescription
            }
        }
    }

    private func setReplacement(_ id: String, _ line: String, _ source: CheckupFix.Source, _ note: String?) {
        guard var current = result, let i = current.fixes.firstIndex(where: { $0.id == id }) else { return }
        current.fixes[i].replacement = line
        current.fixes[i].source = source
        current.fixes[i].note = note
        result = current
        excluded.remove(id)
    }

    private func markSent(_ sent: [CheckupFix]) {
        var lines = sentLines
        for fix in sent { lines[fix.issue.line] = Date() }
        sentLinesData = (try? JSONEncoder().encode(lines)) ?? Data()
    }

    /// Forget sent lines once the log no longer reports them (or after three weeks)
    private func pruneSentLines() {
        let current = Set(fixes.map(\.issue.line))
        let cutoff = Date().addingTimeInterval(-21 * 86_400)
        let kept = sentLines.filter { current.contains($0.key) && $0.value > cutoff }
        sentLinesData = (try? JSONEncoder().encode(kept)) ?? Data()
    }
}

struct CheckupFixRow: View {
    let fix: CheckupFix
    let isIncluded: Bool
    let sentDate: Date?
    let openPR: ListUpdatePR?
    let onToggle: () -> Void
    let onPick: () -> Void
    let onCommentOut: () -> Void

    private var title: String {
        switch fix.issue.kind {
        case .missingWaypoints(let labels):
            let route = fix.target.map { fix.routes[$0.routeKey1]?.listName ?? "\($0.region1) \($0.route1)" } ?? "the route"
            return labels.count == 1
                ? "Waypoint \(labels[0]) isn't on \(route) anymore"
                : "Waypoints \(labels.joined(separator: " and ")) aren't on \(route) anymore"
        case .deprecatedRoute(let old, let canonical):
            return "\(old) was renamed \(canonical)"
        case .unknownRoute:
            return "TravelMapping doesn't recognize this route"
        case .zeroDistance:
            return "Both waypoints are the same point"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(fix.issue.line)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(fix.replacement == nil ? .primary : TMDesign.tertiaryText)
                .strikethrough(fix.replacement != nil)
            ForEach(fix.issue.routeNotes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let openPR {
                Link(destination: openPR.url) {
                    TMChip(text: "Fixed in pull request #\(openPR.number) · waiting for merge",
                           icon: "arrow.triangle.pull", bg: TMDesign.purpleChipBG, fg: TMDesign.purpleChipFG)
                }
            } else if let sentDate {
                TMChip(text: "Fix sent \(sentDate.formatted(date: .abbreviated, time: .omitted)) · waiting for nightly update",
                       icon: "paperplane", bg: TMDesign.purpleChipBG, fg: TMDesign.purpleChipFG)
            } else if let replacement = fix.replacement {
                Button(action: onToggle) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(isIncluded ? TMDesign.accent : TMDesign.chevron)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(replacement)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                TMChip(text: fix.source?.rawValue ?? "Fix",
                                       icon: fix.source == .ai ? "sparkles" : "checkmark",
                                       bg: fix.source == .ai ? TMDesign.purpleChipBG : TMDesign.greenChipBG,
                                       fg: fix.source == .ai ? TMDesign.purpleChipFG : TMDesign.greenChipFG,
                                       fontSize: 11)
                            }
                            if let note = fix.note {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityValue(isIncluded ? "Included" : "Excluded")
            }

            if sentDate == nil && openPR == nil {
                HStack(spacing: 16) {
                    if fix.canPickWaypoints {
                        Button(fix.replacement == nil ? "Choose waypoints…" : "Change…", action: onPick)
                    }
                    if fix.replacement == nil, case .unknownRoute = fix.issue.kind {
                        Button("Comment it out", action: onCommentOut)
                    } else if fix.replacement == nil, case .zeroDistance = fix.issue.kind {
                        Button("Comment it out", action: onCommentOut)
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Pick replacement waypoints from the route's current list, in route order.
struct WaypointPickerSheet: View {
    let fix: CheckupFix
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var start = ""
    @State private var end = ""

    private var route1: RouteWaypoints? { fix.target.flatMap { fix.routes[$0.routeKey1] } }
    private var route2: RouteWaypoints? { fix.target.flatMap { fix.routes[$0.routeKey2] } }

    private var newLine: String? {
        guard var entry = fix.target, !start.isEmpty, !end.isEmpty, start != end || entry.multiRegion else { return nil }
        entry.waypoint1 = start
        entry.waypoint2 = end
        return entry.text
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(fix.issue.line)
                        .font(.system(size: 14, design: .monospaced))
                        .strikethrough()
                        .foregroundStyle(.secondary)
                    if let newLine {
                        Text(newLine)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                }
                if let route1 {
                    Section("From (\(route1.listName))") {
                        Picker("From", selection: $start) {
                            Text("Choose…").tag("")
                            ForEach(route1.labels, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.wheel)
                    }
                }
                if let route2 {
                    Section("To (\(route2.listName))") {
                        Picker("To", selection: $end) {
                            Text("Choose…").tag("")
                            ForEach(route2.labels, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.wheel)
                    }
                }
            }
            .navigationTitle("Choose Waypoints")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        if let newLine { onSave(newLine) }
                        dismiss()
                    }
                    .disabled(newLine == nil)
                }
            }
            .onAppear {
                // Keep labels that still exist; anything gone starts blank — defaulting to
                // the route's ends would silently claim the whole route as traveled
                let target = fix.target
                start = route1?.labels.first { $0 == target?.waypoint1 } ?? ""
                end = route2?.labels.first { $0 == target?.waypoint2 } ?? ""
            }
        }
        .sentryScreen("WaypointPicker")
    }
}
