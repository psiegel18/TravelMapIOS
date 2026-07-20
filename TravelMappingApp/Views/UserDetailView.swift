import SwiftUI
import MapKit
import Sentry
import SentrySwiftUI

struct UserDetailView: View {
    let username: String
    let dataService: DataService
    @State private var profile: UserProfile?
    @State private var isLoading = true
    @State private var selectedTab = 0
    @State private var shareContent: ShareContent?
    @State private var mapLoadedRegions: Set<String> = []
    @State private var userMiles: Double = 0
    @ObservedObject private var catalog = CatalogService.shared
    @ObservedObject private var settings = SyncedSettingsService.shared

    var body: some View {
        SentryTracedView("UserDetailView", waitForFullDisplay: true) {
            bodyContent
        }
    }

    private var bodyContent: some View {
        Group {
            if isLoading {
                ProgressView("Loading \(username)...")
            } else if let profile {
                VStack(spacing: 0) {
                    // Username as the page identity (audit §2: large title 30pt/800).
                    // The redundant compact stat strip that used to sit here duplicated
                    // the totals shown just below in each tab — removed per audit.
                    Text(username)
                        .font(.system(size: 30, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)

                    Picker("View", selection: $selectedTab) {
                        Label("List", systemImage: "list.bullet").tag(0)
                        Label("Map", systemImage: "map").tag(1)
                        Label("Stats", systemImage: "chart.bar").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 10)

                    // Use ZStack with opacity to keep all views alive across tab switches
                    ZStack {
                        listTab(profile: profile)
                            .opacity(selectedTab == 0 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 0)

                        TravelMapView(
                            username: username,
                            dataService: dataService,
                            loadedRegionsBinding: $mapLoadedRegions,
                            isActiveTab: selectedTab == 1
                        )
                        .opacity(selectedTab == 1 ? 1 : 0)
                        .allowsHitTesting(selectedTab == 1)

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
        // Username renders as the in-content 30pt/800 large title (audit §2);
        // an inline nav-bar title would duplicate it directly above.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sentryScreen("UserDetail")
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
                            shareMap()
                        } label: {
                            Label("Share Map", systemImage: "map")
                        }
                        Button {
                            Haptics.light()
                            shareLink()
                        } label: {
                            Label("Share Profile Link", systemImage: "link")
                        }
                        Divider()
                        Button {
                            Haptics.light()
                            copyLink()
                        } label: {
                            Label("Copy Profile Link", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share options")
                }
            }
        }
        .sheet(item: $shareContent) { content in
            SharePreviewSheet(content: content)
        }
        .task {
            SyncedSettingsService.shared.recordRecentUser(username)
            profile = await dataService.loadUserProfile(username: username)
            // Show profile immediately so StatisticsView can start loading
            isLoading = false
            SentrySDK.reportFullyDisplayed()
            // Load supporting data in background (doesn't block the UI)
            if let snapshot = try? await TMStatsService.shared.loadRegionStats(forceRefresh: false),
               let user = snapshot.users.first(where: { $0.username.lowercased() == username.lowercased() }) {
                userMiles = user.totalMiles
            }
            CatalogService.shared.loadIfNeeded()
        }
        .refreshable {
            // Keep the loaded profile if the refresh fails transiently —
            // replacing it with nil would flash the "No Data" screen.
            if let refreshed = await dataService.loadUserProfile(username: username) {
                profile = refreshed
            }
        }
    }

    private func shareStats() {
        guard let profile else { return }
        Task {
            var clinched = 0.0
            var rank: (rank: Int, total: Int)? = nil
            if let snapshot = try? await TMStatsService.shared.loadRegionStats(forceRefresh: false),
               let user = snapshot.users.first(where: { $0.username.lowercased() == username.lowercased() }) {
                clinched = user.totalMiles
                if let pos = snapshot.position(of: username) {
                    rank = (rank: pos.rank, total: snapshot.userCount)
                }
            }
            let card = ProfileShareCard(
                username: username,
                regions: profile.allRegions.count,
                routes: profile.allRoutes.count,
                clinchedMiles: clinched,
                useMiles: SyncedSettingsService.shared.useMiles,
                rank: rank
            )
            if let image = renderShareImage(view: card) {
                let subtitle = "\(profile.allRegions.count.formatted()) regions, \(profile.allRoutes.count.formatted()) routes"
                shareContent = .stats(image: image, username: username, subtitle: subtitle)
            }
        }
    }

    private func shareMap() {
        let regions = mapLoadedRegions.isEmpty ? [] : Array(mapLoadedRegions)
        guard !regions.isEmpty, let profile else { return }

        Task {
            guard let mapImage = await renderMapSnapshot(username: username, regions: regions) else { return }

            let mapCard = MapShareCard(
                username: username,
                mapImage: mapImage,
                regionCount: profile.allRegions.count,
                routeCount: profile.allRoutes.count
            )
            if let cardImage = renderShareImage(view: mapCard) {
                shareContent = .map(image: mapImage, cardImage: cardImage, username: username)
            }
        }
    }

    /// Longitude center/span that stays correct for regions straddling the
    /// antimeridian (±180°, e.g. the Aleutians): when the raw span exceeds 180°,
    /// shift western longitudes by +360 and normalize the center back.
    private static func longitudeCenterAndSpan(for lngs: [Double]) -> (center: Double, span: Double) {
        guard let rawMin = lngs.min(), let rawMax = lngs.max() else { return (0, 0) }
        if rawMax - rawMin <= 180 {
            return ((rawMin + rawMax) / 2, rawMax - rawMin)
        }
        let shifted = lngs.map { $0 < 0 ? $0 + 360 : $0 }
        let sMin = shifted.min()!
        let sMax = shifted.max()!
        var center = (sMin + sMax) / 2
        if center > 180 { center -= 360 }
        return (center, sMax - sMin)
    }

    private func renderMapSnapshot(username: String, regions: [String]) async -> UIImage? {
        // Fetch all regions concurrently instead of serially
        var allSegments: [TravelMappingAPI.MapSegment] = []
        await withTaskGroup(of: [TravelMappingAPI.MapSegment].self) { group in
            for region in regions {
                group.addTask {
                    guard let result = try? await TravelMappingAPI.shared.getRegionSegments(
                        region: region,
                        traveler: username
                    ) else { return [] }
                    return result.segments.filter(\.isClinched)
                }
            }
            for await segs in group {
                allSegments.append(contentsOf: segs)
            }
        }

        guard !allSegments.isEmpty else { return nil }

        let lats = allSegments.flatMap { [$0.start.latitude, $0.end.latitude] }
        let lngs = allSegments.flatMap { [$0.start.longitude, $0.end.longitude] }
        let centerLat = (lats.min()! + lats.max()!) / 2
        let (centerLng, lngSpan) = Self.longitudeCenterAndSpan(for: lngs)
        let spanLat = max((lats.max()! - lats.min()!) * 1.2, 0.05)
        let spanLng = max(lngSpan * 1.2, 0.05)

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: min(spanLng, 360))
        )
        options.size = CGSize(width: 1200, height: 800)
        options.mapType = .standard

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        // Project coordinates to image points (cheap math), then do all
        // CoreGraphics stroking off the main actor.
        let image = snapshot.image
        let lines: [(start: CGPoint, end: CGPoint)] = allSegments.map {
            (snapshot.point(for: $0.start), snapshot.point(for: $0.end))
        }

        return await Task.detached(priority: .userInitiated) {
            Self.drawSegmentLines(lines, on: image)
        }.value
    }

    /// Strokes segment lines onto the snapshot image. Runs off the main actor —
    /// UIGraphicsImageRenderer is thread-safe.
    nonisolated private static func drawSegmentLines(
        _ lines: [(start: CGPoint, end: CGPoint)],
        on image: UIImage
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)

        return renderer.image { rendererContext in
            image.draw(at: .zero)
            let context = rendererContext.cgContext
            context.setLineWidth(4)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(UIColor.systemBlue.cgColor)

            for line in lines {
                context.move(to: line.start)
                context.addLine(to: line.end)
                context.strokePath()
            }
        }
    }

    private func shareLink() {
        guard let profile else { return }
        Task {
            let card = ProfileShareCard(
                username: username,
                regions: profile.allRegions.count,
                routes: profile.allRoutes.count,
                clinchedMiles: userMiles,
                useMiles: SyncedSettingsService.shared.useMiles,
                rank: nil
            )
            if let image = renderShareImage(view: card) {
                let subtitle = "\(profile.allRegions.count.formatted()) regions, \(profile.allRoutes.count.formatted()) routes"
                shareContent = .stats(image: image, username: username, subtitle: subtitle)
            }
        }
    }

    private func copyLink() {
        UIPasteboard.general.url = URL(string: "https://travelmapping.net/user/?u=\(username)")
        Haptics.success()
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
                    regionGroups: regionGroups,
                    username: username,
                    regionCountryMap: catalog.regionCountryMap
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
                .foregroundStyle(TMDesign.accent)
                .accessibilityHidden(true)
            Text(value)
                .font(.title.bold())
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(TMDesign.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct CategorySectionView: View {
    let category: RouteCategory
    let regionGroups: [(region: String, segments: [TravelSegment])]
    let username: String
    let regionCountryMap: [String: String]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var totalSegments: Int {
        regionGroups.reduce(0) { $0 + $1.segments.count }
    }

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private var groupedByCountry: [(country: String, groups: [(region: String, segments: [TravelSegment])])] {
        var dict: [String: [(region: String, segments: [TravelSegment])]] = [:]
        for group in regionGroups {
            let country = regionCountryMap[group.region] ?? "Other"
            dict[country, default: []].append(group)
        }
        return dict.sorted { $0.key < $1.key }.map { (country: $0.key, groups: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: category.systemImage)
                    .foregroundStyle(TMDesign.accent)
                    .accessibilityHidden(true)
                Text("\(category.rawValue) by Region")
                    .font(.title3.bold())
                Spacer()
                Text("\(totalSegments.formatted()) segments")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(TMDesign.secondaryText)
            }

            let grouped = groupedByCountry
            ForEach(grouped, id: \.country) { country, groups in
                if grouped.count > 1 {
                    Text(country)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(groups, id: \.region) { group in
                        NavigationLink {
                            RegionDetailView(region: group.region, username: username)
                        } label: {
                            HStack(spacing: 6) {
                                Text(group.region)
                                    .font(.system(size: 15, weight: .bold))
                                Spacer()
                                Text(group.segments.count.formatted())
                                    .font(.system(size: 15))
                                    .monospacedDigit()
                                    .foregroundStyle(TMDesign.secondaryText)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(TMDesign.chevron)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .background(
                                Color(.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(group.region), \(group.segments.count.formatted()) segments")
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

