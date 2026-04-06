import SwiftUI
import MapKit

struct RoadTripDetailView: View {
    @State var trip: RoadTrip
    @State private var showShareSheet = false
    @State private var shareURL: URL?
    @State private var replayProgress: Double = 1.0  // 0.0 to 1.0
    @State private var isPlaying = false
    @State private var playTimer: Timer?
    @State private var notesText: String = ""
    @FocusState private var notesFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                tripHeader
                tripMap
                notesSection
                segmentsList
            }
            .padding()
        }
        .navigationTitle(trip.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Haptics.light()
                        exportTrip()
                    } label: {
                        Label("Export .list File", systemImage: "doc.text")
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
        .sheet(isPresented: $showShareSheet) {
            if let image = shareItemImage {
                ShareSheet(items: [image])
            } else if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
    }

    @State private var shareItemImage: UIImage?

    private func shareImage() {
        Task {
            let image = await renderTripShareImage(trip: trip)
            await MainActor.run {
                shareItemImage = image
                shareURL = nil
                showShareSheet = image != nil
            }
        }
    }

    private var tripHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                VStack {
                    Text(trip.durationFormatted)
                        .font(.title2.bold())
                    Text("Duration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text(trip.rawPoints.count.formatted())
                        .font(.title2.bold())
                    Text("GPS Points")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text(trip.matchedSegments.count.formatted())
                        .font(.title2.bold())
                    Text("Segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(trip.startDate.formatted(date: .long, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var replayCoordinates: [CLLocationCoordinate2D] {
        guard trip.rawPoints.count > 1 else { return [] }
        let count = Int(Double(trip.rawPoints.count) * replayProgress)
        return trip.rawPoints.prefix(max(2, count)).map(\.coordinate)
    }

    private var tripMap: some View {
        VStack(spacing: 8) {
            Map {
                if replayCoordinates.count > 1 {
                    MapPolyline(coordinates: replayCoordinates)
                        .stroke(.blue, lineWidth: 3)
                }
                // Current position marker
                if let last = replayCoordinates.last {
                    Annotation("", coordinate: last) {
                        Image(systemName: "car.fill")
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.blue, in: Circle())
                    }
                }
            }
            .mapStyle(.standard)
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            // Replay controls
            if trip.rawPoints.count > 1 {
                HStack(spacing: 8) {
                    Button {
                        Haptics.light()
                        togglePlay()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 24)
                    }

                    Slider(value: $replayProgress, in: 0...1) { editing in
                        if editing { stopPlay() }
                    }

                    Text("\(Int(replayProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40)
                }
                .padding(.horizontal)
            }
        }
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
                    .font(.caption)
                }
            }
            TextField("Add notes about this trip...", text: $notesText, axis: .vertical)
                .lineLimit(3...6)
                .focused($notesFocused)
                .onAppear {
                    notesText = trip.notes
                }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func saveNotes() {
        trip.notes = notesText
        let updatedTrip = trip
        Task {
            try? await TripStorageService.shared.save(updatedTrip)
        }
    }

    private var segmentsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Matched Segments")
                .font(.title3.bold())

            if trip.matchedSegments.isEmpty {
                Text("No TM route segments were matched for this trip.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(trip.matchedSegments) { seg in
                    HStack {
                        Image(systemName: "road.lanes")
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(seg.region) \(seg.routeName)")
                                .font(.headline)
                            Text("\(seg.startWaypoint) → \(seg.endWaypoint)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.0f%%", seg.confidence * 100))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func exportTrip() {
        Task {
            do {
                let url = try await TripStorageService.shared.exportListFile(for: trip)
                shareItemImage = nil
                shareURL = url
                showShareSheet = true
            } catch {
                print("Export failed: \(error)")
            }
        }
    }
}
