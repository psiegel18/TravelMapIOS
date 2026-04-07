import SwiftUI
import MapKit

struct RoadTripRecordingView: View {
    @ObservedObject private var recorder = TripRecordingService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mapPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showStopConfirmation = false
    @State private var showNameEditor = false
    @State private var editedName = ""
    @State private var showMidTripSegments = false
    @State private var visibleRegion: MKCoordinateRegion?

    private var distanceInPreferredUnit: String {
        let miles = recorder.totalDistance / 1609.34
        let useMiles = UserDefaults.standard.bool(forKey: "useMiles") || UserDefaults.standard.object(forKey: "useMiles") == nil
        if useMiles {
            return String(format: "%.2f mi", miles)
        } else {
            return String(format: "%.2f km", recorder.totalDistance / 1000)
        }
    }

    private var speedInPreferredUnit: String {
        let mph = recorder.currentSpeed * 2.23694
        let useMiles = UserDefaults.standard.bool(forKey: "useMiles") || UserDefaults.standard.object(forKey: "useMiles") == nil
        if useMiles {
            return String(format: "%.0f mph", mph)
        } else {
            return String(format: "%.0f km/h", recorder.currentSpeed * 3.6)
        }
    }

    private var accuracyText: String {
        guard recorder.currentAccuracy > 0 else { return "—" }
        return String(format: "±%.0fm", recorder.currentAccuracy)
    }

    private var accuracyColor: Color {
        guard recorder.currentAccuracy > 0 else { return .secondary }
        if recorder.currentAccuracy < 20 { return .green }
        if recorder.currentAccuracy < 50 { return .yellow }
        return .orange
    }

    var body: some View {
        VStack(spacing: 0) {
            // Live map with GPS trail and matched segments
            ZStack(alignment: .topTrailing) {
                Map(position: $mapPosition) {
                    // Draw matched TM segments in green underneath
                    ForEach(Array(recorder.matchedCoordinates.enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: [seg.start, seg.end])
                            .stroke(.green, lineWidth: 5)
                    }
                    // Draw the GPS trail as the user drives
                    if let points = recorder.currentTrip?.rawPoints, points.count > 1 {
                        MapPolyline(coordinates: points.map(\.coordinate))
                            .stroke(.blue.opacity(0.7), lineWidth: 3)
                    }
                    UserAnnotation()
                }
                .mapStyle(.standard)
                .mapControls { MapCompass() }
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
                            RoundedRectangle(cornerRadius: 1).fill(.blue.opacity(0.7)).frame(width: 14, height: 3)
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
            .frame(maxHeight: .infinity)

            // Recording dashboard
            VStack(spacing: 16) {
                // Trip name (tappable to edit)
                if recorder.isRecording {
                    Button {
                        editedName = recorder.currentTrip?.name ?? ""
                        showNameEditor = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(recorder.currentTrip?.name ?? "Recording")
                                .font(.subheadline.bold())
                            Image(systemName: "pencil")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Timer
                Text(recorder.elapsedFormatted)
                    .font(.system(.largeTitle, design: .monospaced).bold())
                    .accessibilityLabel("Elapsed time: \(recorder.elapsedFormatted)")

                // Current segment
                if let segName = recorder.currentSegmentName {
                    HStack {
                        Image(systemName: recorder.isPaused ? "pause.circle" : "road.lanes")
                            .foregroundStyle(recorder.isPaused ? .orange : .blue)
                        Text(segName)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    .padding(.horizontal)
                }

                // Live stats grid
                HStack(spacing: 16) {
                    statTile(value: distanceInPreferredUnit, label: "Distance")
                    statTile(value: speedInPreferredUnit, label: "Speed")
                    statTile(value: "\(recorder.matchedCount)", label: "Segments")
                    statTile(value: accuracyText, label: "GPS", color: accuracyColor)
                }
                .padding(.horizontal)

                // Point count
                Text("\(recorder.pointCount) GPS points recorded")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                // Control buttons
                if recorder.isRecording {
                    recordingButtons
                } else {
                    completedButtons
                }
            }
            .padding(.vertical)
            .background(.ultraThinMaterial)
        }
        .navigationTitle(recorder.currentTrip?.name ?? "Recording")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if recorder.isRecording {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showMidTripSegments = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("View matched segments")
                    .disabled(recorder.matchedCount == 0)
                }
            }
        }
        .interactiveDismissDisabled(recorder.isRecording)
        .alert("Stop Recording?", isPresented: $showStopConfirmation) {
            Button("Keep Recording", role: .cancel) {}
            Button("Stop", role: .destructive) {
                recorder.stopTrip()
            }
        } message: {
            let distance = distanceInPreferredUnit
            Text("You've recorded \(recorder.elapsedFormatted) over \(distance) with \(recorder.matchedCount) route segments matched.")
        }
        .alert("Trip Name", isPresented: $showNameEditor) {
            TextField("Trip name", text: $editedName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                recorder.currentTrip?.name = editedName
            }
        }
        .sheet(isPresented: $showMidTripSegments) {
            midTripSegmentsSheet
        }
    }

    private var recordingButtons: some View {
        HStack(spacing: 12) {
            // Pause/Resume
            Button {
                if recorder.isPaused {
                    recorder.resumeTrip()
                } else {
                    recorder.pauseTrip()
                }
            } label: {
                Label(
                    recorder.isPaused ? "Resume" : "Pause",
                    systemImage: recorder.isPaused ? "play.fill" : "pause.fill"
                )
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.orange, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            // Stop
            Button {
                if recorder.elapsedTime < 30 {
                    // Very short trip — warn
                    showStopConfirmation = true
                } else {
                    showStopConfirmation = true
                }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.red, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }

    private var completedButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Trip saved")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
            }
            Button {
                dismiss()
            } label: {
                Label("View Trip", systemImage: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
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

    private func statTile(value: String, label: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold())
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var midTripSegmentsSheet: some View {
        NavigationStack {
            List {
                if let segments = recorder.currentTrip?.matchedSegments, !segments.isEmpty {
                    ForEach(segments) { seg in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(seg.region) \(seg.routeName)")
                                .font(.headline)
                            Text("\(seg.startWaypoint) → \(seg.endWaypoint)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Segments Yet",
                        systemImage: "road.lanes",
                        description: Text("Keep driving! TM routes will be matched as you travel.")
                    )
                }
            }
            .navigationTitle("Matched Segments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showMidTripSegments = false }
                }
            }
        }
    }
}
