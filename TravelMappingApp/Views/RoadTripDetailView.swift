import Sentry
import SwiftUI
import MapKit

struct RoadTripDetailView: View {
    @State var trip: RoadTrip
    @State private var shareContent: ShareContent?
    @State private var replayProgress: Double = 1.0  // 0.0 to 1.0
    @State private var isPlaying = false
    @State private var playTimer: Timer?
    @State private var notesText: String = ""
    @FocusState private var notesFocused: Bool
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?

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
                    if let url = try? TripStorageService.shared.exportListFile(for: trip) {
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
    }

    private func shareImage() {
        Task {
            if let image = await renderTripShareImage(trip: trip) {
                shareContent = .trip(image: image)
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
            ZStack(alignment: .topTrailing) {
                Map(position: $mapPosition) {
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
                .onMapCameraChange { context in
                    visibleRegion = context.region
                }

                // Map controls
                VStack(spacing: 6) {
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
                            RoundedRectangle(cornerRadius: 1).fill(.blue).frame(width: 14, height: 3)
                            Text("GPS").font(.system(size: 9))
                        }
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1).fill(.green).frame(width: 14, height: 3)
                            Text("Matched").font(.system(size: 9))
                        }
                    }
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(8)
            }
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

}
