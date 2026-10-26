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
    @State private var pendingSummary: (lines: Int, trips: Int)?
    @ObservedObject private var settings = SyncedSettingsService.shared

    private var locationPermissionDenied: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .denied || status == .restricted
    }

    /// Empty state replaces both the start section and the past-trips placeholder (audit §11).
    private var showEmptyState: Bool {
        !isLoading && trips.isEmpty && !recorder.isRecording
    }

    var body: some View {
        List {
            // Recording status / start button
            Section {
                if recorder.isRecording {
                    NavigationLink {
                        RoadTripRecordingView()
                    } label: {
                        HStack(spacing: 10) {
                            TMPulsingDot(color: TMDesign.rail, size: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recorder.currentTrip?.name ?? "Recording...")
                                    .font(.headline)
                                Text("\(recorder.elapsedFormatted) - \(recorder.pointCount.formatted()) points")
                                    .font(.subheadline)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityLabel("Recording in progress: \(recorder.currentTrip?.name ?? "trip"). Tap to view.")
                } else if !showEmptyState {
                    startTripButton
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }

            if let pending = pendingSummary, pending.lines > 0 {
                Section {
                    NavigationLink {
                        PendingListUpdatesView(trips: trips, username: settings.primaryUser) {
                            await loadTrips()
                        }
                    } label: {
                        pendingRow(pending)
                    }
                }
            }

            // Past trips
            Section {
                if isLoading {
                    ForEach(0..<3, id: \.self) { _ in
                        TMSkeletonRow()
                    }
                } else if trips.isEmpty {
                    emptyStateCard
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(trips) { trip in
                        NavigationLink {
                            RoadTripDetailView(trip: trip)
                        } label: {
                            TripRowView(trip: trip)
                        }
                    }
                    .onDelete(perform: confirmDelete)
                }
            } header: {
                if !showEmptyState {
                    TMDesign.sectionHeader("Past Trips")
                }
            }
        }
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
            Task { await loadTrips() }
        }
        .onChange(of: settings.primaryUser) {
            Task { await loadPendingSummary() }
        }
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
        trips = loaded.filter { $0.status != .recording }
        isLoading = false
        await loadPendingSummary()
    }

    /// Counts trip segments not yet in the user's list files (road and rail separately,
    /// since they live in different files).
    private func loadPendingSummary() async {
        let username = settings.primaryUser
        let candidates = trips.filter { $0.status == .completed && !$0.matchedSegments.isEmpty }
        guard !username.isEmpty, !candidates.isEmpty else {
            pendingSummary = nil
            return
        }
        var lines = 0
        var tripIDs = Set<UUID>()
        for type in [TripType.road, .rail] {
            let typed = candidates.filter { $0.tripType == type }
            guard !typed.isEmpty,
                  let analysis = try? await TripLogAnalyzer.analyze(trips: typed, username: username) else { continue }
            lines += analysis.newRanges.count
            tripIDs.formUnion(analysis.newRanges.flatMap(\.tripIDs))
        }
        pendingSummary = (lines, tripIDs.count)
    }

    private func pendingRow(_ pending: (lines: Int, trips: Int)) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TMDesign.amberChipFG)
                .frame(width: 34, height: 34)
                .background(TMDesign.amberChipBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(pending.lines.formatted()) segment\(pending.lines == 1 ? "" : "s") not in your list yet")
                    .font(.system(size: 17, weight: .bold))
                Text("From \(pending.trips.formatted()) trip\(pending.trips == 1 ? "" : "s") · tap to update your .list")
                    .font(.system(size: 15))
                    .foregroundStyle(TMDesign.secondaryText)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func confirmDelete(at offsets: IndexSet) {
        if let idx = offsets.first {
            tripToDelete = trips[idx]
        }
    }

    private func performDelete(trip: RoadTrip) {
        Task {
            try? await TripStorageService.shared.delete(id: trip.id)
            await MainActor.run {
                trips.removeAll { $0.id == trip.id }
            }
        }
    }
}

struct TripRowView: View {
    let trip: RoadTrip

    private var isRail: Bool { trip.tripType == .rail }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isRail ? "tram.fill" : "car.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isRail ? TMDesign.redChipFG : TMDesign.blueChipFG)
                .frame(width: 34, height: 34)
                .background(
                    isRail ? TMDesign.redChipBG : TMDesign.blueChipBG,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(trip.name)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                Text(metadataLine)
                    .font(.system(size: 15))
                    .monospacedDigit()
                    .foregroundStyle(TMDesign.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
    }

    private var metadataLine: String {
        var parts = [trip.startDate.formatted(date: .abbreviated, time: .shortened)]
        if let dur = trip.duration {
            parts.append(formatDuration(dur))
        }
        parts.append("\(trip.matchedSegments.count.formatted()) segments")
        return parts.joined(separator: " · ")
    }

    private func formatDuration(_ dur: TimeInterval) -> String {
        let hours = Int(dur) / 3600
        let minutes = (Int(dur) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
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

    /// PRs opened from any trip in the last 60 days, newest first
    private var recentPRs: [ListUpdatePR] {
        let cutoff = Date().addingTimeInterval(-60 * 86_400)
        let all = Set(localTrips.flatMap(\.listUpdatePRs)).filter { $0.createdAt > cutoff }
        return all.sorted { $0.createdAt > $1.createdAt }
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
                        Text("All caught up — every recorded segment is in your list files or already submitted.")
                            .foregroundStyle(TMDesign.secondaryText)
                    }
                }
            }
            if !recentPRs.isEmpty {
                Section("Pull requests") {
                    ForEach(recentPRs) { pr in
                        ListUpdatePRRow(pr: pr, state: prStates[pr.number])
                    }
                }
            }
        }
        .navigationTitle("Pending .list Updates")
        .navigationBarTitleDisplayMode(.inline)
        .sentryScreen("PendingListUpdates")
        .sheet(item: $sheetType) { type in
            ListUpdateSheet(
                lines: included(type == .rail ? rail : road).map(\.line),
                username: username,
                category: type == .rail ? .rail : .road,
                blockTitle: "\(Date().formatted(.iso8601.year().month().day())) recorded trips",
                tripNames: tripNames(in: included(type == .rail ? rail : road)),
                onSubmitted: { pr in markSubmitted(included(type == .rail ? rail : road), pr: pr) }
            )
        }
        .task {
            localTrips = trips
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
            if analysis.unresolvedCount > 0 {
                Text("\(analysis.unresolvedCount.formatted()) recorded segments couldn't be matched to current route data.")
            }
        }
        ForEach(grouped.keys.sorted(), id: \.self) { region in
            Section(region) {
                ForEach(grouped[region] ?? []) { range in
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
                }
            }
        }
    }

    private func included(_ analysis: TripLogAnalysis?) -> [TripLogRange] {
        (analysis?.newRanges ?? []).filter { !excludedRangeIDs.contains($0.id) }
    }

    private func tripNames(for range: TripLogRange) -> String {
        localTrips.filter { range.tripIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
    }

    private func refreshPRStates() async {
        for pr in recentPRs where prStates[pr.number] == nil {
            prStates[pr.number] = try? await GitHubService.shared.pullRequestState(pr.number)
        }
    }

    private func analyze() async {
        errorMessage = nil
        let candidates = localTrips.filter { $0.status == .completed && !$0.matchedSegments.isEmpty }
        do {
            let roadTrips = candidates.filter { $0.tripType == .road }
            let railTrips = candidates.filter { $0.tripType == .rail }
            road = roadTrips.isEmpty ? nil : try await TripLogAnalyzer.analyze(trips: roadTrips, username: username)
            rail = railTrips.isEmpty ? nil : try await TripLogAnalyzer.analyze(trips: railTrips, username: username)
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

    private func markSubmitted(_ ranges: [TripLogRange], pr: ListUpdatePR?) {
        var changed: [RoadTrip] = []
        for i in localTrips.indices {
            let keys = ranges.filter { $0.tripIDs.contains(localTrips[i].id) }.flatMap(\.hopKeys)
            guard !keys.isEmpty else { continue }
            localTrips[i].submittedHopKeys = Array(Set(localTrips[i].submittedHopKeys).union(keys))
            if let pr { localTrips[i].listUpdatePRs.append(pr) }
            changed.append(localTrips[i])
        }
        let crumb = Breadcrumb(level: .info, category: "list_update")
        crumb.message = "Marked \(ranges.count) ranges submitted across \(changed.count) trips"
        SentrySDK.addBreadcrumb(crumb)
        Task {
            for trip in changed {
                try? await TripStorageService.shared.save(trip)
            }
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
