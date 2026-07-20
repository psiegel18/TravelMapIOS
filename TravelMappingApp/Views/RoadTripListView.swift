import SwiftUI
import CoreLocation

struct RoadTripListView: View {
    @ObservedObject private var recorder = TripRecordingService.shared
    @State private var trips: [RoadTrip] = []
    @State private var isLoading = true
    @State private var tripToDelete: RoadTrip?
    @State private var showOrphanedDialog = false
    @State private var showLocationDeniedAlert = false
    @State private var showTripTypeChooser = false

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
