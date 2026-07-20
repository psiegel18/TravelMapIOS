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

    // Driving-mode surface (audit §4): intentionally FIXED dark hexes, not theme-adaptive.
    // The dashboard stays dark regardless of system theme to cut glare in the car.
    private let pageBG = Color(tmHex: 0x0B0B0C)
    private let panelBG = Color(tmHex: 0x161618)
    private let tileBG = Color(tmHex: 0x202023)
    private let grabberColor = Color(tmHex: 0x3A3A3E)
    private let dimText = Color(tmHex: 0x8A8A90)
    private let nameText = Color(tmHex: 0xC8C8D0)
    private let matchGreen = Color(tmHex: 0x4FD69C)
    private let pauseAmber = Color(tmHex: 0xE8912D)
    private let recordRed = Color(tmHex: 0xD6453E)
    private let pauseButtonBG = Color(tmHex: 0x2C2C30)

    private var useMiles: Bool {
        UserDefaults.standard.bool(forKey: "useMiles") || UserDefaults.standard.object(forKey: "useMiles") == nil
    }

    private var distanceInPreferredUnit: String {
        if useMiles {
            return String(format: "%.2f mi", recorder.totalDistance / 1609.34)
        } else {
            return String(format: "%.2f km", recorder.totalDistance / 1000)
        }
    }

    private var distanceParts: (value: String, unit: String) {
        if useMiles {
            return (String(format: "%.1f", recorder.totalDistance / 1609.34), "mi")
        } else {
            return (String(format: "%.1f", recorder.totalDistance / 1000), "km")
        }
    }

    private var speedParts: (value: String, unit: String) {
        if useMiles {
            return (String(format: "%.0f", recorder.currentSpeed * 2.23694), "mph")
        } else {
            return (String(format: "%.0f", recorder.currentSpeed * 3.6), "km/h")
        }
    }

    private var accuracyParts: (value: String, unit: String) {
        guard recorder.currentAccuracy > 0 else { return ("—", "") }
        return (String(format: "±%.0f", recorder.currentAccuracy), "m")
    }

    private var accuracyColor: Color {
        guard recorder.currentAccuracy > 0 else { return dimText }
        if recorder.currentAccuracy < 20 { return matchGreen }
        if recorder.currentAccuracy < 50 { return .yellow }
        return .orange
    }

    var body: some View {
        // Panel overlaps the map by -24pt (audit §4 sheet treatment).
        VStack(spacing: -24) {
            // Live map with GPS trail and matched segments
            ZStack(alignment: .topLeading) {
                Map(position: $mapPosition) {
                    // Draw matched TM segments in green underneath
                    ForEach(Array(recorder.matchedCoordinates.enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: [seg.start, seg.end])
                            .stroke(matchGreen, lineWidth: 5)
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

                // Pulsing recording badge (audit §4) — state carried by text, not just color
                if recorder.isRecording {
                    HStack(spacing: 6) {
                        if recorder.isPaused {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            TMPulsingDot(color: .white, size: 9)
                        }
                        Text(recorder.isPaused ? "PAUSED" : "RECORDING")
                            .font(.system(size: 13, weight: .bold))
                            .kerning(0.5)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        (recorder.isPaused ? pauseAmber : recordRed).opacity(0.92),
                        in: Capsule()
                    )
                    .padding(10)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(recorder.isPaused ? "Recording paused" : "Recording in progress")
                }

                // Map controls
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

                    // Legend
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 1).fill(.blue.opacity(0.7)).frame(width: 14, height: 3)
                            Text("GPS").font(.system(size: 12, weight: .medium))
                        }
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 1).fill(matchGreen).frame(width: 14, height: 3)
                            Text("Matched").font(.system(size: 12, weight: .medium))
                        }
                    }
                    .padding(7)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxHeight: .infinity)

            // Recording dashboard — dark driving-mode sheet
            dashboard
        }
        .background(pageBG)
        .preferredColorScheme(.dark)
        .navigationTitle(recorder.currentTrip?.name ?? "Recording")
        .navigationBarTitleDisplayMode(.inline)
        .sentryScreen("RoadTripRecording")
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
        .alert("End Trip?", isPresented: $showStopConfirmation) {
            Button("Keep Recording", role: .cancel) {}
            Button("End Trip", role: .destructive) {
                recorder.stopTrip()
            }
        } message: {
            let distance = distanceInPreferredUnit
            Text("You've recorded \(recorder.elapsedFormatted) over \(distance) with \(recorder.matchedCount.formatted()) route segments matched.")
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

    private var dashboard: some View {
        VStack(spacing: 14) {
            // Grabber
            Capsule()
                .fill(grabberColor)
                .frame(width: 38, height: 5)
                .accessibilityHidden(true)

            // Trip name (tappable to edit)
            if recorder.isRecording {
                Button {
                    editedName = recorder.currentTrip?.name ?? ""
                    showNameEditor = true
                } label: {
                    HStack(spacing: 5) {
                        Text(recorder.currentTrip?.name ?? "Recording")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(nameText)
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(dimText)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Trip name: \(recorder.currentTrip?.name ?? "Recording"). Tap to edit.")
            }

            // Timer — 52pt monospaced; elapsedFormatted already drops the leading zero hour
            Text(recorder.elapsedFormatted)
                .font(.system(size: 52, weight: .heavy, design: .monospaced))
                .monospacedDigit()
                .kerning(-1.5)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityLabel("Elapsed time: \(recorder.elapsedFormatted)")

            // "Now matching" banner
            if recorder.isRecording {
                matchingBanner
            }

            // 2×2 stat tile grid
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                dashTile(label: "Distance", value: distanceParts.value, unit: distanceParts.unit)
                dashTile(label: "Speed", value: speedParts.value, unit: speedParts.unit)
                dashTile(label: "Segments", value: recorder.matchedCount.formatted(), unit: "")
                dashTile(
                    label: "GPS accuracy",
                    value: accuracyParts.value,
                    unit: accuracyParts.unit,
                    valueColor: accuracyColor,
                    showDot: recorder.currentAccuracy > 0
                )
            }

            // Control buttons
            if recorder.isRecording {
                recordingButtons
            } else {
                completedButtons
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                .fill(panelBG)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var matchingBanner: some View {
        let tint = recorder.isPaused ? pauseAmber : Color(tmHex: 0x2FB170)
        let accent = recorder.isPaused ? pauseAmber : matchGreen
        return HStack(spacing: 10) {
            Image(systemName: recorder.isPaused ? "pause.circle.fill" : "location.north.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(recorder.isPaused ? "PAUSED" : "NOW MATCHING")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(dimText)
                Text(recorder.currentSegmentName ?? "Waiting for a route match…")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            Text("\(recorder.matchedCount.formatted()) matched")
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(accent)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 13)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private func dashTile(
        label: String,
        value: String,
        unit: String,
        valueColor: Color = .white,
        showDot: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(dimText)
            HStack(spacing: 6) {
                if showDot {
                    Circle()
                        .fill(valueColor)
                        .frame(width: 9, height: 9)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 22, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(dimText)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13)
        .padding(.horizontal, 15)
        .background(tileBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value) \(unit)")
    }

    private var recordingButtons: some View {
        // Pause : End trip at 1 : 1.4 width (audit §4 — primary action is obvious)
        GeometryReader { geo in
            let spacing: CGFloat = 12
            let unitWidth = (geo.size.width - spacing) / 2.4
            HStack(spacing: spacing) {
                // Pause/Resume
                Button {
                    if recorder.isPaused {
                        recorder.resumeTrip()
                    } else {
                        recorder.pauseTrip()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(recorder.isPaused ? matchGreen : pauseAmber)
                        Text(recorder.isPaused ? "Resume" : "Pause")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: unitWidth)
                    .frame(maxHeight: .infinity)
                    .background(pauseButtonBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                // End trip
                Button {
                    showStopConfirmation = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("End trip")
                            .font(.system(size: 16, weight: .heavy))
                    }
                    .foregroundStyle(.white)
                    .frame(width: unitWidth * 1.4)
                    .frame(maxHeight: .infinity)
                    .background(recordRed, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 54)
    }

    private var completedButtons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(matchGreen)
                Text("Trip saved")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(matchGreen)
            }
            .accessibilityElement(children: .combine)
            Button {
                dismiss()
            } label: {
                Label("View Trip", systemImage: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(tmHex: 0x2F6BF0), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
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

    private var midTripSegmentsSheet: some View {
        NavigationStack {
            List {
                if let segments = recorder.currentTrip?.matchedSegments, !segments.isEmpty {
                    ForEach(segments) { seg in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(seg.region) \(seg.routeName)")
                                .font(.headline)
                            Text("\(seg.startWaypoint) → \(seg.endWaypoint)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
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
