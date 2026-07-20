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
        .task {
            exportURL = try? await TripStorageService.shared.exportListFile(for: trip)
            await computeDistance()
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
        guard trip.rawPoints.count > 1 else { return [] }
        let count = Int(Double(trip.rawPoints.count) * replayProgress)
        return trip.rawPoints.prefix(max(2, count)).map(\.coordinate)
    }

    private var heroDateLine: String {
        let day = trip.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let time = trip.startDate.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(time)"
    }

    private var heroMap: some View {
        ZStack(alignment: .bottomLeading) {
            Map(position: $mapPosition) {
                if replayCoordinates.count > 1 {
                    MapPolyline(coordinates: replayCoordinates)
                        .stroke(TMDesign.accent, lineWidth: 3)
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
                        Image(systemName: isRail ? "tram.fill" : "car.fill")
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(TMDesign.accent, in: Circle())
                    }
                }
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
