import SwiftUI

struct RoadTripListView: View {
    @ObservedObject private var recorder = TripRecordingService.shared
    @State private var trips: [RoadTrip] = []
    @State private var isLoading = true
    @State private var tripToDelete: RoadTrip?
    @State private var showOrphanedDialog = false

    var body: some View {
        List {
            // Recording status / start button
            Section {
                if recorder.isRecording {
                    NavigationLink {
                        RoadTripRecordingView()
                    } label: {
                        HStack {
                            Circle()
                                .fill(.red)
                                .frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(recorder.currentTrip?.name ?? "Recording...")
                                    .font(.headline)
                                Text("\(recorder.elapsedFormatted) - \(recorder.pointCount) points")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityLabel("Recording in progress: \(recorder.currentTrip?.name ?? "trip"). Tap to view.")
                } else {
                    Button {
                        Haptics.success()
                        recorder.startTrip()
                    } label: {
                        Label("Start Road Trip", systemImage: "location.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Begins GPS tracking to record which roads you drive on")
                }
            }

            // Past trips
            Section("Past Trips") {
                if isLoading {
                    ProgressView()
                } else if trips.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "car")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No trips recorded yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Tap \"Start Road Trip\" above to begin tracking. Your GPS will detect which TM routes you drive on.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
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
            }
        }
        .navigationTitle("Road Trips")
        .alert("Delete Trip?", isPresented: .constant(tripToDelete != nil), presenting: tripToDelete) { trip in
            Button("Cancel", role: .cancel) {
                tripToDelete = nil
            }
            Button("Delete", role: .destructive) {
                performDelete(trip: trip)
                tripToDelete = nil
            }
        } message: { trip in
            Text("Delete \"\(trip.name)\"? This will also delete \(trip.rawPoints.count) GPS points and the exported .list file. This cannot be undone.")
        }
        .alert("Unfinished Trip Found", isPresented: $showOrphanedDialog, presenting: recorder.orphanedTrip) { trip in
            Button("Keep") {
                Task { await recorder.finalizeOrphanedTrip() }
                Task { await loadTrips() }
            }
            Button("Discard", role: .destructive) {
                Task { await recorder.discardOrphanedTrip() }
                Task { await loadTrips() }
            }
        } message: { trip in
            Text("\"\(trip.name)\" was interrupted with \(trip.rawPoints.count) GPS points. Save it as completed, or discard?")
        }
        .onChange(of: recorder.orphanedTrip?.id) {
            showOrphanedDialog = recorder.orphanedTrip != nil
        }
        .task {
            await loadTrips()
        }
        .refreshable {
            await loadTrips()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trip.name)
                .font(.headline)
            HStack(spacing: 12) {
                Label(trip.startDate.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                if let dur = trip.duration {
                    Label(formatDuration(dur), systemImage: "clock")
                }
                Label("\(trip.matchedSegments.count) segments", systemImage: "road.lanes")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func formatDuration(_ dur: TimeInterval) -> String {
        let hours = Int(dur) / 3600
        let minutes = (Int(dur) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
