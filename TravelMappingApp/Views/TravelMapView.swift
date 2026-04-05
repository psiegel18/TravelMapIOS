import SwiftUI
import MapKit

struct TravelMapView: View {
    let username: String
    let dataService: DataService
    @State private var segments: [TravelMappingAPI.MapSegment] = []
    @State private var routeMetadata: [TravelMappingAPI.RouteMetadata] = []
    @State private var isLoading = true
    @State private var loadingProgress: String?
    @State private var errorMessage: String?
    @State private var showClinched = true
    @State private var showUnclinched = false
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedRegion: String?
    @State private var availableRegions: [String] = []

    private var displayedSegments: [TravelMappingAPI.MapSegment] {
        segments.filter { seg in
            if showClinched && seg.isClinched { return true }
            if showUnclinched && !seg.isClinched { return true }
            return false
        }
    }

    private var clinchedCount: Int { segments.filter(\.isClinched).count }
    private var totalCount: Int { segments.count }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer

            // Zoom controls - top trailing
            VStack {
                HStack {
                    Spacer()
                    zoomControls
                        .padding(.trailing, 12)
                        .padding(.top, 8)
                }
                Spacer()
            }

            VStack(spacing: 8) {
                if isLoading {
                    loadingIndicator
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                controlBar
                    .padding(.bottom, 8)
            }
        }
        .navigationTitle("\(username)'s Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                regionPicker
            }
        }
        .task {
            await loadRegions()
        }
        .onChange(of: selectedRegion) {
            Task { await loadSegments() }
        }
    }

    // MARK: - Map

    private var mapLayer: some View {
        Map(position: $mapPosition) {
            ForEach(displayedSegments) { seg in
                MapPolyline(coordinates: [seg.start, seg.end])
                    .stroke(
                        seg.isClinched ? colorForRoot(seg.root) : .gray.opacity(0.4),
                        lineWidth: seg.isClinched ? 3 : 1.5
                    )
            }
        }
        .mapStyle(.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: - Zoom Controls

    private var zoomControls: some View {
        VStack(spacing: 0) {
            Button {
                zoomIn()
            } label: {
                Image(systemName: "plus")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }

            Divider()
                .frame(width: 44)

            Button {
                zoomOut()
            } label: {
                Image(systemName: "minus")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func zoomIn() {
        adjustZoom(factor: 0.5)
    }

    private func zoomOut() {
        adjustZoom(factor: 2.0)
    }

    @State private var currentSpanLat: Double = 5.0
    @State private var currentSpanLng: Double = 5.0

    private func adjustZoom(factor: Double) {
        guard !displayedSegments.isEmpty else { return }
        let allLats = displayedSegments.flatMap { [$0.start.latitude, $0.end.latitude] }
        let allLngs = displayedSegments.flatMap { [$0.start.longitude, $0.end.longitude] }
        let centerLat = (allLats.min()! + allLats.max()!) / 2
        let centerLng = (allLngs.min()! + allLngs.max()!) / 2

        currentSpanLat = min(max(currentSpanLat * factor, 0.001), 180)
        currentSpanLng = min(max(currentSpanLng * factor, 0.001), 360)

        withAnimation {
            mapPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
                span: MKCoordinateSpan(latitudeDelta: currentSpanLat, longitudeDelta: currentSpanLng)
            ))
        }
    }

    // MARK: - Subviews

    private var loadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(loadingProgress ?? "Loading routes...")
                .font(.caption)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                showClinched.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showClinched ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.blue)
                    Text("Traveled (\(clinchedCount))")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)

            Button {
                showUnclinched.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showUnclinched ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.gray)
                    Text("Remaining (\(totalCount - clinchedCount))")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if !routeMetadata.isEmpty {
                MileageLabel(routeMetadata: routeMetadata)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var regionPicker: some View {
        Menu {
            Button("All Regions") {
                selectedRegion = nil
            }
            Divider()
            ForEach(availableRegions, id: \.self) { region in
                Button(region) {
                    selectedRegion = region
                }
            }
        } label: {
            Label(selectedRegion ?? "Region", systemImage: "globe")
                .font(.caption)
        }
    }

    // MARK: - Data Loading

    private func loadRegions() async {
        guard let profile = await dataService.loadUserProfile(username: username) else {
            errorMessage = "Could not load user profile"
            isLoading = false
            return
        }

        let regions = Array(profile.allRegions).sorted()
        availableRegions = regions

        if regions.count <= 3 {
            selectedRegion = nil
            await loadSegments()
        } else {
            let regionCounts = profile.categories.values.flatMap { $0 }
                .reduce(into: [String: Int]()) { counts, seg in
                    counts[seg.primaryRegion, default: 0] += 1
                }
            selectedRegion = regionCounts.max(by: { $0.value < $1.value })?.key
        }
    }

    private func loadSegments() async {
        isLoading = true
        loadingProgress = nil
        errorMessage = nil
        segments = []
        routeMetadata = []

        do {
            let result: (segments: [TravelMappingAPI.MapSegment], routes: [TravelMappingAPI.RouteMetadata])

            if let region = selectedRegion {
                loadingProgress = "Loading \(region)..."
                result = try await TravelMappingAPI.shared.getRegionSegments(
                    region: region,
                    traveler: username
                )
            } else {
                guard let profile = await dataService.loadUserProfile(username: username) else {
                    errorMessage = "Could not load profile"
                    isLoading = false
                    return
                }

                let allRegions = Array(profile.allRegions).sorted()
                loadingProgress = "Loading all regions..."

                // Single API call with all regions, keep only clinched segments
                // (full data is 210K+ segments / 21MB — too much to render)
                let fullResult = try await TravelMappingAPI.shared.getRegionSegments(
                    regions: allRegions,
                    traveler: username
                )

                // For "All Regions" view, only keep clinched segments to stay performant
                let clinchedOnly = fullResult.segments.filter(\.isClinched)
                result = (clinchedOnly, fullResult.routes)
            }

            segments = result.segments
            routeMetadata = result.routes
        } catch {
            errorMessage = "API error: \(error.localizedDescription)"
        }

        loadingProgress = nil
        isLoading = false
    }

    // MARK: - Helpers

    private func colorForRoot(_ root: String) -> Color {
        guard let meta = routeMetadata.first(where: { $0.root == root }) else {
            return .blue
        }
        return Color(hex: meta.displayColorHex)
    }
}

// MARK: - Mileage Label with unit toggle

struct MileageLabel: View {
    let routeMetadata: [TravelMappingAPI.RouteMetadata]
    @AppStorage("useMiles") private var useMiles = true

    private var totalMi: Double { routeMetadata.reduce(0.0) { $0 + $1.mileage } }
    private var clinchedMi: Double { routeMetadata.reduce(0.0) { $0 + $1.clinchedMileage } }

    private var displayClinched: Double { useMiles ? clinchedMi : clinchedMi * 1.60934 }
    private var displayTotal: Double { useMiles ? totalMi : totalMi * 1.60934 }
    private var unit: String { useMiles ? "mi" : "km" }

    var body: some View {
        Button {
            useMiles.toggle()
        } label: {
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f / %.1f %@", displayClinched, displayTotal, unit))
                    .font(.caption2.bold())
                if displayTotal > 0 {
                    Text(String(format: "%.1f%%", displayClinched / displayTotal * 100))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Color from Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
