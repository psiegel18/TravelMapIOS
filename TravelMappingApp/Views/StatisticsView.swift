import Sentry
import SentrySwiftUI
import SwiftUI

/// In-memory cache for stats data so navigating away and back doesn't reload.
/// Invalidated after 1 hour or on pull-to-refresh.
/// @MainActor so the entries dictionary is never touched off the main actor —
/// prefetch's network awaits hop off, but all cache reads/writes stay isolated.
@MainActor
final class StatsCache {
    static let shared = StatsCache()
    private var entries: [String: CachedStats] = [:]

    struct CachedStats {
        let regionStats: [StatisticsView.RegionStat]
        let allRoutes: [StatisticsView.RouteInfo]
        let railTotals: StatisticsView.CategoryTotals
        let rankInfo: (rank: Int, total: Int, percentile: Double)?
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

        // Don't cache an all-empty result after a total failure — that would pin
        // the empty state for the full 1h TTL and defeat the real load later.
        let producedRealData = !allRoutes.isEmpty
            || regionStats.contains(where: { $0.clinchedMileage > 0 || $0.totalMileage > 0 })
            || railTotals.routeCount > 0
        guard producedRealData else { return }

        set(for: username, stats: CachedStats(
            regionStats: regionStats,
            allRoutes: allRoutes,
            railTotals: railTotals,
            rankInfo: rankInfo,
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
    // Single source of truth for units: Settings-backed SyncedSettingsService.
    // (A local @AppStorage toggle here previously created a dual-source staleness
    // bug — it wrote UserDefaults directly, bypassing the @Published + iCloud sync.)
    @ObservedObject private var settings = SyncedSettingsService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var useMiles: Bool { settings.useMiles }

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
    @ObservedObject private var catalog = CatalogService.shared
    private var regionCountryMap: [String: String] { catalog.regionCountryMap }

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
                loadingHeader
                heroCard
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
            loadedRegionCount = 0
            totalRegionCount = 0
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
                    isLoadingMileage = false
                    isLoadingRoutes = false
                    isLoadingRail = false
                    CatalogService.shared.loadIfNeeded()
                } else {
                    await loadMileageData()
                }
            }
        }
    }

    // MARK: - Loading header (audit §11)

    /// Thin top progress bar + region-count caption shown while route/rail details
    /// stream in. Replaces the mid-card spinners so the layout never jumps.
    @ViewBuilder
    private var loadingHeader: some View {
        if isLoadingRoutes || isLoadingRail {
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(tmLight: 0xE3E3E8, dark: 0x2A2A2E))
                        Capsule()
                            .fill(TMDesign.accent)
                            .frame(width: geo.size.width * loadingProgressFraction)
                    }
                }
                .frame(height: 4)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: loadingProgressFraction)

                Text(totalRegionCount > 0
                     ? "Loading \(loadedRegionCount.formatted()) / \(totalRegionCount.formatted()) regions…"
                     : "Loading regions…")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(TMDesign.tertiaryText)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var loadingProgressFraction: CGFloat {
        guard totalRegionCount > 0 else { return 0.08 }
        return max(0.08, min(1, CGFloat(loadedRegionCount) / CGFloat(totalRegionCount)))
    }

    // MARK: - Overview

    private var categoryBreakdownCard: some View {
        let roadMi = regionStats.reduce(0.0) { $0 + $1.clinchedMileage }
        let roadTotal = regionStats.reduce(0.0) { $0 + $1.totalMileage }
        let roadRoutes = regionStats.reduce(0) { $0 + $1.routeCount }

        return VStack(alignment: .leading, spacing: 14) {
            TMDesign.sectionHeader("By Category")

            categoryRow(
                icon: "car.fill",
                tileBG: TMDesign.blueChipBG, tileFG: TMDesign.blueChipFG,
                name: "Roads",
                routeCount: roadRoutes,
                clinched: roadMi, total: roadTotal,
                barColor: TMDesign.accent,
                percentColor: TMDesign.clinched,
                isLoading: isLoadingRoutes
            )

            Rectangle().fill(TMDesign.hairline).frame(height: 1)

            categoryRow(
                icon: "tram.fill",
                tileBG: TMDesign.redChipBG, tileFG: TMDesign.redChipFG,
                name: "Rail & Transit",
                routeCount: railTotals.routeCount,
                clinched: railTotals.clinchedMileage, total: railTotals.totalMileage,
                barColor: TMDesign.rail,
                percentColor: TMDesign.frontier,
                isLoading: isLoadingRail
            )
        }
        .padding()
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// One "By Category" row (audit §2): 34pt tinted icon tile, name + route-count
    /// subtitle, mileage + colored percent text, and a 6pt progress bar. The percent
    /// is always a numeric label — color reinforces, never carries, the meaning.
    private func categoryRow(
        icon: String, tileBG: Color, tileFG: Color, name: String,
        routeCount: Int, clinched: Double, total: Double,
        barColor: Color, percentColor: Color, isLoading: Bool
    ) -> some View {
        let fraction = total > 0 ? min(clinched / total, 1) : 0

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tileFG)
                    .frame(width: 34, height: 34)
                    .background(tileBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 16, weight: .bold))
                    Text(isLoading ? "Loading routes…" : "\(formatInt(routeCount)) routes")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(TMDesign.tertiaryText)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(isLoading && total <= 0 ? "—" : "\(formatNumber(convert(clinched))) \(unit)")
                        .font(.system(size: 16, weight: .heavy))
                        .monospacedDigit()
                    Text(total > 0 ? String(format: "%.1f%%", clinched / total * 100) : " ")
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(percentColor)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(TMDesign.progressTrack)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * CGFloat(fraction))
                }
            }
            .frame(height: 6)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(categoryAccessibilityLabel(
            name: name, routeCount: routeCount, clinched: clinched, total: total, isLoading: isLoading
        ))
    }

    private func categoryAccessibilityLabel(
        name: String, routeCount: Int, clinched: Double, total: Double, isLoading: Bool
    ) -> String {
        guard !isLoading else { return "\(name), loading" }
        var label = "\(name), \(formatInt(routeCount)) routes, \(formatNumber(convert(clinched))) \(useMiles ? "miles" : "kilometers")"
        if total > 0 {
            label += ", \(String(format: "%.1f", clinched / total * 100)) percent complete"
        }
        return label
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
                    .foregroundStyle(TMDesign.frontier)
                Text("Closest to Clinched")
                    .font(.title3.bold())
            }

            if isLoadingRoutes {
                skeletonRows(count: 3)
            } else if inProgress.isEmpty {
                Text("No routes in progress yet")
                    .font(.system(size: 15))
                    .foregroundStyle(TMDesign.secondaryText)
            } else {
                ForEach(Array(inProgress)) { route in
                    NavigationLink {
                        RouteDetailView(root: route.root, listName: route.listName, username: profile.username)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(route.listName)
                                    .font(.system(size: 15, weight: .bold))
                                Spacer()
                                Text("\(formatNumber(convert(route.remainingMileage))) \(unit) left")
                                    .font(.system(size: 15, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(TMDesign.frontier)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(TMDesign.chevron)
                            }
                            ProgressView(value: route.clinchedMileage, total: route.mileage)
                                .tint(TMDesign.frontier)
                            Text(String(format: "%.1f%% complete", route.percentage))
                                .font(.system(size: 13))
                                .monospacedDigit()
                                .foregroundStyle(TMDesign.secondaryText)
                        }
                        .padding(.vertical, 4)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(route.listName), \(formatNumber(convert(route.remainingMileage))) \(useMiles ? "miles" : "kilometers") left, \(String(format: "%.1f", route.percentage)) percent complete")
                }
            }
        }
        .padding()
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Skeleton placeholder stack used while route details stream in (audit §11).
    private func skeletonRows(count: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                TMSkeletonRow()
            }
        }
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
                    .foregroundStyle(TMDesign.clinched)
                Text("Longest Clinched")
                    .font(.title3.bold())
            }

            if isLoadingRoutes {
                skeletonRows(count: 3)
            } else if clinched.isEmpty {
                Text("No fully clinched routes yet")
                    .font(.system(size: 15))
                    .foregroundStyle(TMDesign.secondaryText)
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
                                .font(.system(size: 15, weight: .bold))
                            Spacer()
                            Text("\(formatNumber(convert(route.mileage))) \(unit)")
                                .font(.system(size: 15, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(TMDesign.clinched)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(TMDesign.chevron)
                        }
                        .padding(.vertical, 2)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(route.listName), clinched, \(formatNumber(convert(route.mileage))) \(useMiles ? "miles" : "kilometers")")
                }
                Text("\(formatInt(aggregatedClinchedRoutes.count)) routes fully clinched")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(TMDesign.secondaryText)
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Hero card (audit §2): completion ring + rank pill + Traveled/Available rows,
    /// with a 3-up regions/routes/segments strip. Replaces the "Travel Overview"
    /// tile grid, which showed the same data as a wall of small numbers.
    private var heroCard: some View {
        let totalMi = regionStats.reduce(0.0) { $0 + $1.totalMileage }
        let clinchedMi = regionStats.reduce(0.0) { $0 + $1.clinchedMileage }
        let totalRoutes = regionStats.reduce(0) { $0 + $1.routeCount }
        let fraction = totalMi > 0 ? clinchedMi / totalMi : 0

        return VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 20) {
                TMCompletionRing(fraction: fraction, diameter: 112)

                VStack(alignment: .leading, spacing: 10) {
                    if let rank = rankInfo {
                        HStack(spacing: 5) {
                            Image(systemName: "trophy.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text("#\(rank.rank.formatted()) · Top \(String(format: "%.1f", rank.percentile))%")
                                .font(.system(size: 13, weight: .bold))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(TMDesign.goldChipBG, in: Capsule())
                        .foregroundStyle(TMDesign.goldChipFG)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Ranked number \(rank.rank.formatted()) of \(rank.total.formatted()), top \(String(format: "%.1f", rank.percentile)) percent")
                    }

                    heroValueRow(label: "Traveled", value: isLoadingMileage ? "—" : "\(formatNumber(convert(clinchedMi))) \(unit)")
                    Rectangle().fill(TMDesign.hairline).frame(height: 1)
                    heroValueRow(label: "Available", value: isLoadingMileage ? "—" : "\(formatNumber(convert(totalMi))) \(unit)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle().fill(TMDesign.hairline).frame(height: 1)

            HStack(spacing: 0) {
                heroCountStat(value: formatInt(profile.allRegions.count), label: "regions")
                heroCountStat(value: formatInt(totalRoutes > 0 ? totalRoutes : profile.allRoutes.count), label: "routes")
                heroCountStat(value: formatInt(profile.totalSegments), label: "segments")
            }
        }
        .padding(20)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func heroValueRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(TMDesign.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func heroCountStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .heavy))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(TMDesign.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
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
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                skeletonRows(count: 4)
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
                                        // Clinched regions get a check shape, never color alone
                                        if stat.percentage >= 100 {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(TMDesign.clinched)
                                                .accessibilityHidden(true)
                                        }
                                        Text(String(format: "%.1f%%", stat.percentage))
                                            .font(.system(size: 13, weight: .bold))
                                            .monospacedDigit()
                                            .foregroundStyle(stat.percentage >= 100 ? TMDesign.clinched : .primary)
                                    }
                                    ProgressView(value: stat.clinchedMileage, total: max(stat.totalMileage, 0.01))
                                        .tint(TMDesign.accent)
                                    Text("\(formatNumber(convert(stat.clinchedMileage))) / \(formatNumber(convert(stat.totalMileage))) \(unit)")
                                        .font(.system(size: 13))
                                        .monospacedDigit()
                                        .foregroundStyle(TMDesign.secondaryText)
                                }
                                .padding(10)
                                .frame(minHeight: 44)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(stat.region), \(String(format: "%.1f", stat.percentage)) percent\(stat.percentage >= 100 ? ", clinched" : ""), \(formatNumber(convert(stat.clinchedMileage))) of \(formatNumber(convert(stat.totalMileage))) \(useMiles ? "miles" : "kilometers")")
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
                                .fill(TMDesign.accent.opacity(0.6))
                                .frame(width: max(width, 2), height: 24)
                        }
                        .frame(height: 24)

                        Text(item.value.formatted())
                            .font(.system(size: 15))
                            .monospacedDigit()
                            .foregroundStyle(TMDesign.secondaryText)
                            .frame(width: 56, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.region), \(item.value.formatted()) segments")
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadMileageData() async {
        let username = profile.username
        let allRegions = Array(profile.allRegions).sorted()

        // Region → country mapping is loaded once per launch by CatalogService and
        // shared across views. Trigger a load if it isn't already in flight; the view
        // re-renders when the published mapping fills in.
        _ = await CatalogService.shared.awaitMapping()

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

        // Cache for instant reload on re-navigation — but only if the load produced
        // real data. Caching an all-zero result after a total failure would pin the
        // empty state for the full 1h TTL; on failure the error/empty UI shows instead.
        let producedRealData = !allRoutes.isEmpty
            || regionStats.contains(where: { $0.clinchedMileage > 0 || $0.totalMileage > 0 })
            || railTotals.routeCount > 0
        if producedRealData {
            StatsCache.shared.set(for: username, stats: .init(
                regionStats: regionStats,
                allRoutes: allRoutes,
                railTotals: railTotals,
                rankInfo: rankInfo,
                date: Date()
            ))
        }
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
                                // API layer already captures with the HTML body attached.
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
                                // API layer already captures with the HTML body attached.
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
