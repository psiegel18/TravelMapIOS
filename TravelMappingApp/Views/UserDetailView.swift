import SwiftUI
import MapKit

struct UserDetailView: View {
    let username: String
    let dataService: DataService
    @State private var profile: UserProfile?
    @State private var isLoading = true
    @State private var selectedTab = 0
    @State private var shareItem: ShareItem?
    @State private var mapLoadedRegions: Set<String> = []
    @State private var userMiles: Double = 0
    @ObservedObject private var settings = SyncedSettingsService.shared

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading \(username)...")
            } else if let profile {
                VStack(spacing: 0) {
                    // Compact stats row
                    HStack(spacing: 0) {
                        compactStat(value: profile.allRegions.count.formatted(), label: "regions")
                        Divider().frame(height: 24)
                        compactStat(value: profile.allRoutes.count.formatted(), label: "routes")
                        Divider().frame(height: 24)
                        compactStat(value: profile.totalSegments.formatted(), label: "segments")
                        if userMiles > 0 {
                            Divider().frame(height: 24)
                            let displayMiles = settings.useMiles ? userMiles : userMiles * 1.60934
                            let unit = settings.useMiles ? "mi" : "km"
                            compactStat(value: "\(Int(displayMiles).formatted()) \(unit)", label: "traveled")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)

                    Picker("View", selection: $selectedTab) {
                        Label("List", systemImage: "list.bullet").tag(0)
                        Label("Map", systemImage: "map").tag(1)
                        Label("Stats", systemImage: "chart.bar").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    // Use ZStack to keep views alive and avoid zero-size layout
                    ZStack {
                        listTab(profile: profile)
                            .opacity(selectedTab == 0 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 0)

                        if selectedTab == 1 {
                            TravelMapView(
                                username: username,
                                dataService: dataService,
                                loadedRegionsBinding: $mapLoadedRegions
                            )
                        }

                        StatisticsView(profile: profile)
                            .opacity(selectedTab == 2 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 2)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "doc.questionmark",
                    description: Text("No travel data found for \(username)")
                )
            }
        }
        .navigationTitle(username)
        .toolbar {
            if profile != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Haptics.light()
                            shareStats()
                        } label: {
                            Label("Share Stats Card", systemImage: "chart.bar")
                        }
                        Button {
                            Haptics.light()
                            shareMapScreenshot()
                        } label: {
                            Label("Share Map Screenshot", systemImage: "map")
                        }
                        Button {
                            Haptics.light()
                            shareLink()
                        } label: {
                            Label("Share Profile Link", systemImage: "link")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share options")
                }
            }
        }
        .sheet(item: $shareItem) { item in
            SharePreviewView(image: item.image)
        }
        .task {
            SyncedSettingsService.shared.recordRecentUser(username)
            profile = await dataService.loadUserProfile(username: username)
            // Load mileage from cached leaderboard data
            if let snapshot = try? await TMStatsService.shared.loadRegionStats(forceRefresh: false),
               let user = snapshot.users.first(where: { $0.username.lowercased() == username.lowercased() }) {
                userMiles = user.totalMiles
            }
            isLoading = false
        }
        .refreshable {
            profile = await dataService.loadUserProfile(username: username)
        }
    }

    private func compactStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func shareStats() {
        guard let profile else { return }
        Task {
            // Look up mileage from cached leaderboard data
            var clinched = 0.0
            if let snapshot = try? await TMStatsService.shared.loadRegionStats(forceRefresh: false),
               let user = snapshot.users.first(where: { $0.username.lowercased() == username.lowercased() }) {
                clinched = user.totalMiles
            }
            let card = ShareableStatsCard(
                username: username,
                regions: profile.allRegions.count,
                routes: profile.allRoutes.count,
                clinchedMiles: clinched,
                useMiles: SyncedSettingsService.shared.useMiles
            )
            if let image = renderShareImage(view: card) {
                shareItem = ShareItem(image: image)
            }
        }
    }

    private func shareMapScreenshot() {
        // Use only the currently loaded regions, not all
        let regions = mapLoadedRegions.isEmpty ? [] : Array(mapLoadedRegions)
        guard !regions.isEmpty else { return }

        Task {
            let image = await renderMapSnapshot(
                username: username,
                regions: regions
            )
            if let image {
                shareItem = ShareItem(image: image)
            }
        }
    }

    @MainActor
    private func renderMapSnapshot(username: String, regions: [String]) async -> UIImage? {
        // Get segments for all loaded regions
        var allSegments: [TravelMappingAPI.MapSegment] = []
        for region in regions {
            if let result = try? await TravelMappingAPI.shared.getRegionSegments(
                region: region,
                traveler: username
            ) {
                allSegments.append(contentsOf: result.segments.filter(\.isClinched))
            }
        }

        guard !allSegments.isEmpty else { return nil }

        // Compute bounding box
        let lats = allSegments.flatMap { [$0.start.latitude, $0.end.latitude] }
        let lngs = allSegments.flatMap { [$0.start.longitude, $0.end.longitude] }
        let centerLat = (lats.min()! + lats.max()!) / 2
        let centerLng = (lngs.min()! + lngs.max()!) / 2
        let spanLat = max((lats.max()! - lats.min()!) * 1.2, 0.05)
        let spanLng = max((lngs.max()! - lngs.min()!) * 1.2, 0.05)

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLng)
        )
        options.size = CGSize(width: 1080, height: 1080)
        options.mapType = .standard

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        // Draw routes on snapshot
        let image = snapshot.image
        UIGraphicsBeginImageContextWithOptions(image.size, true, image.scale)
        defer { UIGraphicsEndImageContext() }

        image.draw(at: .zero)
        guard let context = UIGraphicsGetCurrentContext() else { return image }

        context.setLineWidth(3)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for seg in allSegments {
            let start = snapshot.point(for: seg.start)
            let end = snapshot.point(for: seg.end)
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        }

        // Add watermark
        let watermark = "\(username) · travelmapping.net"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24, weight: .medium),
            .foregroundColor: UIColor.label.withAlphaComponent(0.6)
        ]
        let textSize = watermark.size(withAttributes: attrs)
        watermark.draw(at: CGPoint(x: 20, y: image.size.height - textSize.height - 20), withAttributes: attrs)

        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }

    private func shareLink() {
        // Share the TM website link for this user
        let urlString = "https://travelmapping.net/user/mapview.php?u=\(username)"
        if let url = URL(string: urlString) {
            DispatchQueue.main.async {
                let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = scene.windows.first?.rootViewController {
                    activityVC.popoverPresentationController?.sourceView = root.view
                    root.present(activityVC, animated: true)
                }
            }
        }
    }

    @ViewBuilder
    private func listTab(profile: UserProfile) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                statsHeader(profile: profile)
                categoryBreakdown(profile: profile)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func statsHeader(profile: UserProfile) -> some View {
        let regions = profile.allRegions
        let routes = profile.allRoutes

        VStack(spacing: 16) {
            HStack(spacing: 24) {
                StatBox(value: regions.count.formatted(), label: "Regions", icon: "globe")
                StatBox(value: routes.count.formatted(), label: "Routes", icon: "road.lanes")
                StatBox(value: profile.totalSegments.formatted(), label: "Segments", icon: "point.topleft.down.to.point.bottomright.curvepath")
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func categoryBreakdown(profile: UserProfile) -> some View {
        ForEach(RouteCategory.allCases) { category in
            let regionGroups = profile.segmentsByRegion(for: category)
            if !regionGroups.isEmpty {
                CategorySectionView(
                    category: category,
                    regionGroups: regionGroups
                )
            }
        }
    }
}

struct StatBox: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
            Text(value)
                .font(.title.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CategorySectionView: View {
    let category: RouteCategory
    let regionGroups: [(region: String, segments: [TravelSegment])]
    @State private var isExpanded = true

    var totalSegments: Int {
        regionGroups.reduce(0) { $0 + $1.segments.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: category.systemImage)
                        .foregroundStyle(.blue)
                    Text(category.rawValue)
                        .font(.title3.bold())
                    Text("(\(totalSegments.formatted()) segments)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(regionGroups, id: \.region) { group in
                    RegionGroupView(region: group.region, segments: group.segments)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct RegionGroupView: View {
    let region: String
    let segments: [TravelSegment]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(region)
                        .font(.headline)
                    Text("\(segments.count.formatted()) segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(segments) { segment in
                    SegmentRowView(segment: segment)
                }
            }
        }
        .padding(.leading, 8)
    }
}

struct SegmentRowView: View {
    let segment: TravelSegment

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(segment.route)
                    .font(.subheadline.bold())
                Text("\(segment.waypoint1) → \(segment.waypoint2)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let r2 = segment.region2, r2 != segment.region1 {
                Spacer()
                Text("→ \(r2)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, 12)
    }
}
