import Sentry
import SentrySwiftUI
import SwiftUI

/// In-memory cache for stats data so navigating away and back doesn't reload.
/// Invalidated after 1 hour or on pull-to-refresh.
final class StatsCache {
    static let shared = StatsCache()
    private var entries: [String: CachedStats] = [:]

    struct CachedStats {
        let regionStats: [StatisticsView.RegionStat]
        let allRoutes: [StatisticsView.RouteInfo]
        let railTotals: StatisticsView.CategoryTotals
        let rankInfo: (rank: Int, total: Int, percentile: Double)?
        let regionCountryMap: [String: String]
        let date: Date
    }

    func get(for username: String) -> CachedStats? {
        guard let entry = entries[username.lowercased()],
              Date().timeIntervalSince(entry.date) < 3600 else { return nil }
        return entry
    }

    func set(for username: String, stats: CachedStats) {
        entries[username.lowercased()] = stats
    }

    func invalidate(for username: String) {
        entries.removeValue(forKey: username.lowercased())
    }

    /// Prefetch stats for a user in the background so the view loads instantly.
    func prefetch(username: String, profile: UserProfile) async {
        // Skip if already cached
        guard get(for: username) == nil else { return }

        let allRegions = Array(profile.allRegions).sorted()
        let batchSize = 3

        // CSV stats (fast)
        var regionStats: [StatisticsView.RegionStat] = []
        if let snapshot = try? await TMStatsService.shared.loadRegionStats(forceRefresh: false) {
            let userRegions = Set(allRegions)
            for user in snapshot.users where user.username.lowercased() == username.lowercased() {
                for (region, miles) in user.byRegion where userRegions.contains(region) {
                    let total = snapshot.regionTotals[region] ?? miles
                    regionStats.append(StatisticsView.RegionStat(
                        id: region, region: region,
                        totalMileage: total, clinchedMileage: miles, routeCount: 0
                    ))
                }
            }
        }

        // Route details (expensive — batched)
        var allRoutes: [StatisticsView.RouteInfo] = []
        await withTaskGroup(of: [StatisticsView.RouteInfo].self) { group in
            for batchStart in stride(from: 0, to: allRegions.count, by: batchSize) {
                let batch = Array(allRegions[batchStart..<min(batchStart + batchSize, allRegions.count)])
                group.addTask {
                    guard let result = try? await TravelMappingAPI.shared.getRegionSegments(
                        regions: batch, traveler: username
                    ) else { return [] }
                    return result.routes.map { r in
                        StatisticsView.RouteInfo(id: r.root, root: r.root, listName: r.listName,
                                                  mileage: r.mileage, clinchedMileage: r.clinchedMileage)
                    }
                }
            }
            for await routes in group {
                allRoutes.append(contentsOf: routes)
            }
        }

        // Merge route counts into region stats
        if !allRoutes.isEmpty {
            var routeCountByRegion: [String: Int] = [:]
            for route in allRoutes {
                let region = String(route.root.split(separator: ".").first ?? "").uppercased()
                routeCountByRegion[region, default: 0] += 1
            }
            regionStats = regionStats.map { stat in
                StatisticsView.RegionStat(id: stat.id, region: stat.region,
                                           totalMileage: stat.totalMileage, clinchedMileage: stat.clinchedMileage,
                                           routeCount: routeCountByRegion[stat.region] ?? 0)
            }
        }

        // Rail totals
        var railTotals = StatisticsView.CategoryTotals()
        await withTaskGroup(of: (Double, Double, Int).self) { group in
            for batchStart in stride(from: 0, to: allRegions.count, by: batchSize) {
                let batch = Array(allRegions[batchStart..<min(batchStart + batchSize, allRegions.count)])
                group.addTask {
                    guard let r = try? await TravelMappingAPI.rail.getRegionSegments(
                        regions: batch, traveler: username
                    ) else { return (0.0, 0.0, 0) }
                    return (
                        r.routes.reduce(0.0) { $0 + $1.clinchedMileage },
                        r.routes.reduce(0.0) { $0 + $1.mileage },
                        r.routes.count
                    )
                }
            }
            for await (c, t, n) in group {
                railTotals.clinchedMileage += c
                railTotals.totalMileage += t
                railTotals.routeCount += n
            }
        }

        // Rank info
        var rankInfo: (rank: Int, total: Int, percentile: Double)?
        if let snapshot = try? await TMStatsService.shared.loadRegionStats(forceRefresh: false),
           let pos = snapshot.position(of: username) {
            rankInfo = (pos.rank, snapshot.userCount, pos.percentile)
        }

        set(for: username, stats: CachedStats(
            regionStats: regionStats,
            allRoutes: allRoutes,
            railTotals: railTotals,
            rankInfo: rankInfo,
            regionCountryMap: [:],
            date: Date()
        ))
    }
}

struct StatisticsView: View {
    let profile: UserProfile
    @State private var regionStats: [RegionStat] = []
    @State private var railTotals: CategoryTotals = .init()
    @State private var isLoadingMileage = true
    @State private var isLoadingRoutes = true
    @State private var isLoadingRail = true
    @State private var loadedRegionCount = 0
    @State private var totalRegionCount = 0
    @AppStorage("useMiles") private var useMiles = true

    struct RegionStat: Identifiable {
        let id: String
        let region: String
        let totalMileage: Double
        let clinchedMileage: Double
        let routeCount: Int

        var percentage: Double {
            totalMileage > 0 ? clinchedMileage / totalMileage * 100 : 0
        }
    }

    struct CategoryTotals {
        var clinchedMileage: Double = 0
        var totalMileage: Double = 0
        var routeCount: Int = 0
    }

    struct RouteInfo: Identifiable, Hashable {
        let id: String // root
        let root: String
        let listName: String
        let mileage: Double
        let clinchedMileage: Double

        var remainingMileage: Double { mileage - clinchedMileage }
        var isClinched: Bool { clinchedMileage >= mileage && mileage > 0 }
        var percentage: Double { mileage > 0 ? clinchedMileage / mileage * 100 : 0 }
    }

    @State private var allRoutes: [RouteInfo] = []
    @State private var rankInfo: (rank: Int, total: Int, percentile: Double)?
    @State private var regionCountryMap: [String: String] = [:] // region code → country name

    private var unit: String { useMiles ? "mi" : "km" }
    private func convert(_ miles: Double) -> Double { useMiles ? miles : miles * 1.60934 }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f
    }()

    private func formatNumber(_ n: Double) -> String {
        Self.numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func formatInt(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    @State private var regionViewMode: RegionViewMode = .distance
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum RegionViewMode: String, CaseIterable {
        case distance = "Distance"
        case segments = "Segments"
    }

    var body: some View {
        SentryTracedView("StatisticsView", waitForFullDisplay: true) {
            bodyContent
        }
    }

    private var bodyContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                unitToggle
                overviewCard
                categoryBreakdownCard
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 16) {
                        closestToClinchedCard
                        longestClinchedCard
                    }
                } else {
                    closestToClinchedCard
                    longestClinchedCard
                }
                regionCard
            }
            .padding()
        }
        .refreshable {
            await CacheService.shared.clearAll()
            StatsCache.shared.invalidate(for: profile.username)
            // Reset state so loading indicators show
            regionStats = []
            allRoutes = []
            railTotals = .init()
            rankInfo = nil
            isLoadingMileage = true
            isLoadingRoutes = true
            isLoadingRail = true
            await loadMileageData()
        }
        .task {
            if regionStats.isEmpty {
                // Try cache first
                if let cached = StatsCache.shared.get(for: profile.username) {
                    regionStats = cached.regionStats
                    allRoutes = cached.allRoutes
                    railTotals = cached.railTotals
                    rankInfo = cached.rankInfo
                    regionCountryMap = cached.regionCountryMap
                    isLoadingMileage = false
                    isLoadingRoutes = false
                    isLoadingRail = false
                } else {
                    await loadMileageData()
                }
            }
        }
    }

    // MARK: - Unit Toggle

    private var unitToggle: some View {
        Picker("Units", selection: $useMiles) {
            Text("Miles").tag(true)
            Text("Kilometers").tag(false)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Overview

    private var categoryBreakdownCard: some View {
        let roadMi = regionStats.reduce(0.0) { $0 + $1.clinchedMileage }
        let roadTotal = regionStats.reduce(0.0) { $0 + $1.totalMileage }
        let roadRoutes = regionStats.reduce(0) { $0 + $1.routeCount }

        return VStack(alignment: .leading, spacing: 12) {
            Text("By Category")
                .font(.title2.bold())

            // Roads row
            HStack {
                Image(systemName: "car.fill")
                    .foregroundStyle(.blue)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Roads")
                        .font(.headline)
                    if isLoadingRoutes {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            if totalRegionCount > 0 {
                                Text("Loading \(loadedRegionCount)/\(totalRegionCount) regions...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Loading...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("\(formatInt(roadRoutes)) routes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(formatNumber(convert(roadMi))) \(unit)")
                        .font(.subheadline.bold())
                    if roadTotal > 0 {
                        Text(String(format: "%.1f%%", roadMi / roadTotal * 100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            // Rail row
            HStack {
                Image(systemName: "tram.fill")
                    .foregroundStyle(.red)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rail & Transit")
                        .font(.headline)
                    if isLoadingRail {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Loading...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("\(formatInt(railTotals.routeCount)) routes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !isLoadingRail {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(formatNumber(convert(railTotals.clinchedMileage))) \(unit)")
                            .font(.subheadline.bold())
                        if railTotals.totalMileage > 0 {
                            Text(String(format: "%.1f%%", railTotals.clinchedMileage / railTotals.totalMileage * 100))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
            .background(.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Closest to Clinched

    private var closestToClinchedCard: some View {
        let inProgress = allRoutes
            .filter { $0.clinchedMileage > 0 && !$0.isClinched }
            .sorted { $0.remainingMileage < $1.remainingMileage }
            .prefix(5)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "target")
                    .foregroundStyle(.orange)
                Text("Closest to Clinched")
                    .font(.title3.bold())
            }

            if isLoadingRoutes {
                HStack {
                    ProgressView()
                    Text(totalRegionCount > 0 ? "Loading \(loadedRegionCount)/\(totalRegionCount) regions..." : "Loading route details...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else if inProgress.isEmpty {
                Text("No routes in progress yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(inProgress)) { route in
                    NavigationLink {
                        RouteDetailView(root: route.root, listName: route.listName, username: profile.username)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(route.listName)
                                    .font(.subheadline.bold())
                                Spacer()
                                Text("\(formatNumber(convert(route.remainingMileage))) \(unit) left")
                                    .font(.caption.bold())
                                    .foregroundStyle(.orange)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            ProgressView(value: route.clinchedMileage, total: route.mileage)
                                .tint(.orange)
                            Text(String(format: "%.1f%% complete", route.percentage))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Longest Clinched

    /// Extract the route name from a root like "il.i090" → "i090" or listName "IL I-90" → "I-90"
    private func routeBaseName(from root: String) -> String {
        if let dotIndex = root.firstIndex(of: ".") {
            return String(root[root.index(after: dotIndex)...])
        }
        return root
    }

    /// Aggregate routes across regions — I-90 in IL + WI + IN = one combined entry
    private var aggregatedClinchedRoutes: [RouteInfo] {
        // Group by route base name (the part after the dot in root)
        let grouped = Dictionary(grouping: allRoutes) { routeBaseName(from: $0.root) }

        return grouped.compactMap { (baseName, regionRoutes) -> RouteInfo? in
            let totalMileage = regionRoutes.reduce(0) { $0 + $1.mileage }
            let totalClinched = regionRoutes.reduce(0) { $0 + $1.clinchedMileage }
            guard totalMileage > 0, totalClinched >= totalMileage else { return nil }

            // Use the route name without region prefix for display
            let routeName: String
            if let firstName = regionRoutes.first?.listName {
                let parts = firstName.split(separator: " ", maxSplits: 1)
                routeName = parts.count > 1 ? String(parts[1]) : firstName
            } else {
                routeName = baseName
            }

            // Collect all roots for cross-region detail view
            let allRoots = regionRoutes.map(\.root).sorted()
            let regions = regionRoutes.compactMap { r -> String? in
                let parts = r.listName.split(separator: " ", maxSplits: 1)
                return parts.count > 0 ? String(parts[0]) : nil
            }
            let displayName = regions.count > 1 ? routeName : (regionRoutes.first?.listName ?? routeName)

            return RouteInfo(
                id: baseName,
                root: allRoots.first ?? baseName,
                listName: displayName,
                mileage: totalMileage,
                clinchedMileage: totalClinched
            )
        }
        .sorted { $0.mileage > $1.mileage }
    }

    private var longestClinchedCard: some View {
        let clinched = Array(aggregatedClinchedRoutes.prefix(5))

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Longest Clinched")
                    .font(.title3.bold())
            }

            if isLoadingRoutes {
                HStack {
                    ProgressView()
                    Text(totalRegionCount > 0 ? "Loading \(loadedRegionCount)/\(totalRegionCount) regions..." : "Loading route details...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else if clinched.isEmpty {
                Text("No fully clinched routes yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(clinched) { route in
                    let baseName = routeBaseName(from: route.root)
                    let allRoots = allRoutes.filter { routeBaseName(from: $0.root) == baseName }.map(\.root)
                    NavigationLink {
                        RouteDetailView(
                            roots: allRoots,
                            listName: route.listName,
                            username: profile.username
                        )
                    } label: {
                        HStack {
                            Text(route.listName)
                                .font(.subheadline.bold())
                            Spacer()
                            Text("\(formatNumber(convert(route.mileage))) \(unit)")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                Text("\(formatInt(aggregatedClinchedRoutes.count)) routes fully clinched")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var overviewCard: some View {
        VStack(spacing: 12) {
            Text("Travel Overview")
                .font(.title2.bold())

            if let rank = rankInfo {
                HStack(spacing: 6) {
                    Image(systemName: "trophy.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(String(format: "Ranked #%d of %d · Top %.1f%%", rank.rank, rank.total, rank.percentile))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }

            let totalMi = regionStats.reduce(0.0) { $0 + $1.totalMileage }
            let clinchedMi = regionStats.reduce(0.0) { $0 + $1.clinchedMileage }
            let totalRoutes = regionStats.reduce(0) { $0 + $1.routeCount }

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                StatTile(
                    icon: "globe",
                    title: "Regions",
                    value: formatInt(profile.allRegions.count)
                )
                StatTile(
                    icon: "road.lanes",
                    title: "Routes",
                    value: formatInt(totalRoutes > 0 ? totalRoutes : profile.allRoutes.count)
                )
                StatTile(
                    icon: "point.topleft.down.to.point.bottomright.curvepath",
                    title: "Traveled",
                    value: isLoadingMileage ? "..." : "\(formatNumber(convert(clinchedMi))) \(unit)"
                )
                StatTile(
                    icon: "ruler",
                    title: "Total Available",
                    value: isLoadingMileage ? "..." : "\(formatNumber(convert(totalMi))) \(unit)"
                )
            }

            if totalMi > 0 {
                VStack(spacing: 4) {
                    ProgressView(value: clinchedMi, total: totalMi)
                        .tint(.blue)
                    Text(String(format: "%.1f%% overall completion", clinchedMi / totalMi * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Combined Region Card (Distance / Segments toggle)

    private var regionCardTitle: String {
        regionViewMode == .distance
            ? "\(useMiles ? "Miles" : "Kilometers") by Region"
            : "Segments by Region"
    }

    private var regionCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text(regionCardTitle)
                    .font(.title2.bold())
                Spacer()
            }

            Picker("View", selection: $regionViewMode) {
                ForEach(RegionViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if regionViewMode == .distance {
                regionDistanceView
            } else {
                regionSegmentsView
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func groupedByCountry<T>(_ items: [(region: String, value: T)]) -> [(country: String, items: [(region: String, value: T)])] {
        var groups: [String: [(region: String, value: T)]] = [:]
        for item in items {
            let country = regionCountryMap[item.region] ?? "Other"
            groups[country, default: []].append(item)
        }
        return groups.sorted { $0.key < $1.key }.map { (country: $0.key, items: $0.value) }
    }

    private var regionDistanceColumns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private var regionDistanceView: some View {
        Group {
            if isLoadingMileage {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading mileage data...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                let sorted = regionStats.sorted { $0.clinchedMileage > $1.clinchedMileage }
                let grouped = groupedByCountry(sorted.map { (region: $0.region, value: $0) })

                ForEach(grouped, id: \.country) { country, stats in
                    if grouped.count > 1 {
                        Text(country)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }

                    LazyVGrid(columns: regionDistanceColumns, spacing: 8) {
                        ForEach(stats, id: \.region) { item in
                            let stat = item.value
                            NavigationLink {
                                RegionDetailView(region: stat.region, username: profile.username)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(stat.region)
                                            .font(.headline)
                                        Spacer()
                                        Text(String(format: "%.1f%%", stat.percentage))
                                            .font(.caption2.bold())
                                            .foregroundStyle(stat.percentage >= 100 ? .green : .primary)
                                    }
                                    ProgressView(value: stat.clinchedMileage, total: max(stat.totalMileage, 0.01))
                                        .tint(.blue)
                                    Text("\(formatNumber(convert(stat.clinchedMileage))) / \(formatNumber(convert(stat.totalMileage))) \(unit)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var regionSegmentsView: some View {
        Group {
            let regionCounts = computeRegionCounts()
            let topRegions = regionCounts.sorted { $0.value > $1.value }
            let grouped = groupedByCountry(topRegions.map { (region: $0.key, value: $0.value) })

            ForEach(grouped, id: \.country) { country, items in
                if grouped.count > 1 {
                    Text(country)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }

                let maxCount = topRegions.first?.value ?? 1
                ForEach(items, id: \.region) { item in
                    HStack {
                        Text(item.region)
                            .font(.headline)
                            .frame(width: 50, alignment: .leading)

                        GeometryReader { geo in
                            let width = geo.size.width * CGFloat(item.value) / CGFloat(maxCount)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.blue.opacity(0.6))
                                .frame(width: max(width, 2), height: 24)
                        }
                        .frame(height: 24)

                        Text(item.value.formatted())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadMileageData() async {
        let username = profile.username
        let allRegions = Array(profile.allRegions).sorted()

        // Load region → country mapping (cached after first fetch)
        if regionCountryMap.isEmpty {
            do {
                let catalog = try await TravelMappingAPI.shared.getAllRoutes()
                var mapping: [String: String] = [:]
                let regions = catalog.regions ?? []
                let countries = catalog.countries ?? []
                for (i, region) in regions.enumerated() where i < countries.count {
                    if mapping[region] == nil {
                        mapping[region] = countries[i]
                    }
                }
                regionCountryMap = mapping
            } catch {
                SentrySDK.capture(error: error)
            }
        }

        // PHASE 1: Load from CSV — instant, gives clinched + total available per region
        do {
            if let csvStats = try await loadFromCSV(username: username, userRegions: Set(allRegions)) {
                regionStats = csvStats
                isLoadingMileage = false // Show CSV data immediately
            }
        } catch {
            SentrySDK.capture(error: error)
        }

        // PHASE 2: Load route-level data AND rail totals in parallel
        // Small batches (3 regions) = ~2.5MB/6s each vs 25 regions = 21MB/65s
        isLoadingRoutes = true
        isLoadingRail = true
        totalRegionCount = allRegions.count
        loadedRegionCount = 0
        let batchSize = 3

        // Kick off rail loading concurrently — different server, no contention
        async let railResult = loadRailTotals(regions: allRegions, username: username, batchSize: batchSize)

        // Load road routes with incremental UI updates
        await loadRouteDetailsIncrementally(regions: allRegions, username: username, batchSize: batchSize)
        isLoadingRoutes = false

        // Merge route counts into regionStats (CSV data preserved as mileage source)
        if !allRoutes.isEmpty {
            var routeCountByRegion: [String: Int] = [:]
            for route in allRoutes {
                let region = String(route.root.split(separator: ".").first ?? "").uppercased()
                routeCountByRegion[region, default: 0] += 1
            }

            if regionStats.isEmpty {
                // No CSV data — build regionStats from route-level data
                var routesByRegion: [String: (mileage: Double, clinched: Double, count: Int)] = [:]
                for route in allRoutes {
                    let region = String(route.root.split(separator: ".").first ?? "").uppercased()
                    var entry = routesByRegion[region] ?? (0, 0, 0)
                    entry.mileage += route.mileage
                    entry.clinched += route.clinchedMileage
                    entry.count += 1
                    routesByRegion[region] = entry
                }
                regionStats = routesByRegion.map { region, data in
                    RegionStat(id: region, region: region,
                               totalMileage: data.mileage, clinchedMileage: data.clinched,
                               routeCount: data.count)
                }
            } else {
                // Merge route counts into existing CSV-derived stats
                regionStats = regionStats.map { stat in
                    RegionStat(id: stat.id, region: stat.region,
                               totalMileage: stat.totalMileage, clinchedMileage: stat.clinchedMileage,
                               routeCount: routeCountByRegion[stat.region] ?? stat.routeCount)
                }
            }
        }

        railTotals = await railResult
        isLoadingRail = false
        isLoadingMileage = false

        // Cache for instant reload on re-navigation
        StatsCache.shared.set(for: username, stats: .init(
            regionStats: regionStats,
            allRoutes: allRoutes,
            railTotals: railTotals,
            rankInfo: rankInfo,
            regionCountryMap: regionCountryMap,
            date: Date()
        ))
        SentrySDK.reportFullyDisplayed()
    }

    /// Loads route details in small batches and updates allRoutes incrementally
    /// so the user sees Closest/Longest Clinched populate as data arrives.
    /// Does NOT overwrite regionStats — CSV data from Phase 1 is preserved.
    private func loadRouteDetailsIncrementally(regions: [String], username: String, batchSize: Int) async {
        await withTaskGroup(of: (Int, [RouteInfo]).self) { group in
            for batchStart in stride(from: 0, to: regions.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, regions.count)
                let batch = Array(regions[batchStart..<batchEnd])
                group.addTask {
                    // Wrap in unstructured Task so URLSession requests
                    // survive parent cancellation (e.g. refreshable ending)
                    await withCheckedContinuation { continuation in
                        Task {
                            do {
                                let result = try await TravelMappingAPI.shared.getRegionSegments(
                                    regions: batch, traveler: username
                                )
                                let routes = result.routes.map { r in
                                    RouteInfo(id: r.root, root: r.root, listName: r.listName,
                                              mileage: r.mileage, clinchedMileage: r.clinchedMileage)
                                }
                                continuation.resume(returning: (batch.count, routes))
                            } catch {
                                SentrySDK.capture(error: error)
                                continuation.resume(returning: (batch.count, []))
                            }
                        }
                    }
                }
            }
            for await (count, routes) in group {
                loadedRegionCount += count
                allRoutes.append(contentsOf: routes)
            }
        }
    }

    private func loadRailTotals(regions: [String], username: String, batchSize: Int) async -> CategoryTotals {
        var railClinched: Double = 0
        var railTotal: Double = 0
        var railRoutes: Int = 0
        await withTaskGroup(of: (Double, Double, Int).self) { group in
            for batchStart in stride(from: 0, to: regions.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, regions.count)
                let batch = Array(regions[batchStart..<batchEnd])
                group.addTask {
                    await withCheckedContinuation { continuation in
                        Task {
                            do {
                                let r = try await TravelMappingAPI.rail.getRegionSegments(
                                    regions: batch, traveler: username
                                )
                                continuation.resume(returning: (
                                    r.routes.reduce(0.0) { $0 + $1.clinchedMileage },
                                    r.routes.reduce(0.0) { $0 + $1.mileage },
                                    r.routes.count
                                ))
                            } catch {
                                SentrySDK.capture(error: error)
                                continuation.resume(returning: (0.0, 0.0, 0))
                            }
                        }
                    }
                }
            }
            for await (c, t, n) in group {
                railClinched += c
                railTotal += t
                railRoutes += n
            }
        }
        return CategoryTotals(clinchedMileage: railClinched, totalMileage: railTotal, routeCount: railRoutes)
    }

    private func loadFromCSV(username: String, userRegions: Set<String>) async throws -> [RegionStat]? {
        let snapshot = try await TMStatsService.shared.loadRegionStats()
        guard let user = snapshot.users.first(where: { $0.username.lowercased() == username.lowercased() }) else {
            return nil
        }

        // Capture rank info
        if let pos = snapshot.position(of: username) {
            rankInfo = (rank: pos.rank, total: snapshot.userCount, percentile: pos.percentile)
        }

        // Build RegionStats using clinched from user data + total available from TOTAL row
        var stats: [RegionStat] = []
        for (region, clinchedMiles) in user.byRegion where userRegions.contains(region) {
            let totalAvailable = snapshot.regionTotals[region] ?? clinchedMiles
            stats.append(RegionStat(
                id: region,
                region: region,
                totalMileage: totalAvailable,
                clinchedMileage: clinchedMiles,
                routeCount: 0
            ))
        }
        // Also add regions the user hasn't traveled but has in their profile
        for region in userRegions where user.byRegion[region] == nil {
            if let totalAvailable = snapshot.regionTotals[region] {
                stats.append(RegionStat(
                    id: region,
                    region: region,
                    totalMileage: totalAvailable,
                    clinchedMileage: 0,
                    routeCount: 0
                ))
            }
        }
        return stats
    }

    private func computeRegionCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for segments in profile.categories.values {
            for segment in segments {
                counts[segment.primaryRegion, default: 0] += 1
            }
        }
        return counts
    }
}

struct StatTile: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
            Text(value)
                .font(.title3.bold())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}
