import SwiftUI

struct StatisticsView: View {
    let profile: UserProfile
    @State private var regionStats: [RegionStat] = []
    @State private var railTotals: CategoryTotals = .init()
    @State private var isLoadingMileage = true
    @State private var loadingProgress: String?
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

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                unitToggle
                overviewCard
                categoryBreakdownCard
                closestToClinchedCard
                longestClinchedCard
                regionMileageCard
                topRegionsCard
            }
            .padding()
        }
        .refreshable {
            await CacheService.shared.clearAll()
            regionStats = []
            isLoadingMileage = true
            await loadMileageData()
        }
        .task {
            // Only load if we haven't already — prevents re-fetching on navigation back
            if allRoutes.isEmpty && regionStats.isEmpty {
                await loadMileageData()
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
                    Text("\(formatInt(roadRoutes)) routes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Text("\(formatInt(railTotals.routeCount)) routes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(isLoadingMileage ? "..." : "\(formatNumber(convert(railTotals.clinchedMileage))) \(unit)")
                        .font(.subheadline.bold())
                    if railTotals.totalMileage > 0 {
                        Text(String(format: "%.1f%%", railTotals.clinchedMileage / railTotals.totalMileage * 100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

            if isLoadingMileage {
                HStack {
                    ProgressView()
                    Text(loadingProgress ?? "Loading route details...")
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

    private var longestClinchedCard: some View {
        let clinched = allRoutes
            .filter { $0.isClinched }
            .sorted { $0.mileage > $1.mileage }
            .prefix(5)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Longest Clinched")
                    .font(.title3.bold())
            }

            if isLoadingMileage {
                HStack {
                    ProgressView()
                    Text(loadingProgress ?? "Loading route details...")
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
                ForEach(Array(clinched)) { route in
                    NavigationLink {
                        RouteDetailView(root: route.root, listName: route.listName, username: profile.username)
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
                Text("\(formatInt(allRoutes.filter(\.isClinched).count)) routes fully clinched")
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

    // MARK: - Per-Region Mileage

    private var regionMileageCard: some View {
        VStack(spacing: 12) {
            Text("By Region")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            if isLoadingMileage {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(loadingProgress ?? "Loading mileage data...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                let sorted = regionStats.sorted { $0.clinchedMileage > $1.clinchedMileage }

                ForEach(sorted) { stat in
                    NavigationLink {
                        RegionDetailView(region: stat.region, username: profile.username)
                    } label: {
                        HStack {
                            Text(stat.region)
                                .font(.headline)
                                .frame(width: 45, alignment: .leading)

                            VStack(spacing: 2) {
                                ProgressView(value: stat.clinchedMileage, total: max(stat.totalMileage, 0.01))
                                    .tint(.blue)
                                HStack {
                                    Text("\(formatNumber(convert(stat.clinchedMileage))) / \(formatNumber(convert(stat.totalMileage))) \(unit)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1f%%", stat.percentage))
                                        .font(.caption2.bold())
                                        .foregroundStyle(stat.percentage >= 100 ? .green : .primary)
                                }
                            }

                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Top Regions by Segment Count (from local data)

    private var topRegionsCard: some View {
        VStack(spacing: 12) {
            Text("Segments by Region")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            let regionCounts = computeRegionCounts()
            let topRegions = regionCounts.sorted { $0.value > $1.value }.prefix(15)

            ForEach(Array(topRegions), id: \.key) { region, count in
                HStack {
                    Text(region)
                        .font(.headline)
                        .frame(width: 50, alignment: .leading)

                    GeometryReader { geo in
                        let maxCount = topRegions.first?.value ?? 1
                        let width = geo.size.width * CGFloat(count) / CGFloat(maxCount)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.blue.opacity(0.6))
                            .frame(width: max(width, 2), height: 24)
                    }
                    .frame(height: 24)

                    Text(count.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Data Loading

    private func loadMileageData() async {
        let username = profile.username
        let allRegions = Array(profile.allRegions).sorted()

        // PHASE 1: Fast load from CSV (all regions at once, ~1 second)
        loadingProgress = "Loading stats..."
        if let userStats = try? await loadFromCSV(username: username, userRegions: Set(allRegions)) {
            regionStats = userStats
            // Stats shown immediately while Phase 2 loads route-level data
        }

        // PHASE 2: Load detailed route data from API (for Closest to Clinched etc)
        let total = allRegions.count
        var stats: [RegionStat] = []
        var loadedRoutes: [RouteInfo] = []
        var completed = 0
        allRoutes = []

        // Load 6 regions in parallel per batch
        let batchSize = 6
        for batchStart in stride(from: 0, to: allRegions.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, allRegions.count)
            let batch = Array(allRegions[batchStart..<batchEnd])

            await withTaskGroup(of: (stat: RegionStat, routes: [RouteInfo])?.self) { group in
                for region in batch {
                    group.addTask {
                        do {
                            let result = try await TravelMappingAPI.shared.getRegionSegments(
                                region: region,
                                traveler: username
                            )
                            let totalMi = result.routes.reduce(0.0) { $0 + $1.mileage }
                            let clinchedMi = result.routes.reduce(0.0) { $0 + $1.clinchedMileage }
                            let routes = result.routes.map { r in
                                RouteInfo(
                                    id: r.root,
                                    root: r.root,
                                    listName: r.listName,
                                    mileage: r.mileage,
                                    clinchedMileage: r.clinchedMileage
                                )
                            }
                            return (stat: RegionStat(
                                id: region,
                                region: region,
                                totalMileage: totalMi,
                                clinchedMileage: clinchedMi,
                                routeCount: result.routes.count
                            ), routes: routes)
                        } catch {
                            return nil
                        }
                    }
                }

                for await result in group {
                    if let r = result {
                        stats.append(r.stat)
                        loadedRoutes.append(contentsOf: r.routes)
                    }
                    completed += 1
                    loadingProgress = "Loading route details \(completed)/\(total)..."
                }
            }

            // Update progressively
            regionStats = stats
        }

        regionStats = stats
        allRoutes = loadedRoutes

        // Load rail totals from TM Rail API
        var railClinched: Double = 0
        var railTotal: Double = 0
        var railRoutes: Int = 0
        for region in allRegions {
            do {
                let r = try await TravelMappingAPI.rail.getRegionSegments(
                    region: region,
                    traveler: username
                )
                railTotal += r.routes.reduce(0.0) { $0 + $1.mileage }
                railClinched += r.routes.reduce(0.0) { $0 + $1.clinchedMileage }
                railRoutes += r.routes.count
            } catch {
                // no rail data for this region
            }
        }
        railTotals = CategoryTotals(
            clinchedMileage: railClinched,
            totalMileage: railTotal,
            routeCount: railRoutes
        )

        loadingProgress = nil
        isLoadingMileage = false
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

        // Convert to RegionStat (total mileage unknown from CSV, set equal to clinched for now)
        var stats: [RegionStat] = []
        for (region, miles) in user.byRegion where userRegions.contains(region) {
            stats.append(RegionStat(
                id: region,
                region: region,
                totalMileage: miles, // will be updated by API phase
                clinchedMileage: miles,
                routeCount: 0
            ))
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
