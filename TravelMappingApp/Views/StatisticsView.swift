import SwiftUI

struct StatisticsView: View {
    let profile: UserProfile
    @State private var regionStats: [RegionStat] = []
    @State private var isLoadingMileage = true
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

    private var unit: String { useMiles ? "mi" : "km" }
    private func convert(_ miles: Double) -> Double { useMiles ? miles : miles * 1.60934 }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                unitToggle
                overviewCard
                regionMileageCard
                topRegionsCard
            }
            .padding()
        }
        .task {
            await loadMileageData()
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

    private var overviewCard: some View {
        VStack(spacing: 12) {
            Text("Travel Overview")
                .font(.title2.bold())

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
                    value: "\(profile.allRegions.count)"
                )
                StatTile(
                    icon: "road.lanes",
                    title: "Routes",
                    value: "\(totalRoutes > 0 ? totalRoutes : profile.allRoutes.count)"
                )
                StatTile(
                    icon: "point.topleft.down.to.point.bottomright.curvepath",
                    title: "Traveled",
                    value: isLoadingMileage ? "..." : String(format: "%.1f %@", convert(clinchedMi), unit)
                )
                StatTile(
                    icon: "ruler",
                    title: "Total Available",
                    value: isLoadingMileage ? "..." : String(format: "%.1f %@", convert(totalMi), unit)
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
                ProgressView("Loading mileage data...")
                    .padding()
            } else {
                let sorted = regionStats.sorted { $0.clinchedMileage > $1.clinchedMileage }

                ForEach(sorted) { stat in
                    HStack {
                        Text(stat.region)
                            .font(.headline)
                            .frame(width: 45, alignment: .leading)

                        VStack(spacing: 2) {
                            ProgressView(value: stat.clinchedMileage, total: max(stat.totalMileage, 0.01))
                                .tint(.blue)
                            HStack {
                                Text(String(format: "%.1f / %.1f %@", convert(stat.clinchedMileage), convert(stat.totalMileage), unit))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f%%", stat.percentage))
                                    .font(.caption2.bold())
                                    .foregroundStyle(stat.percentage >= 100 ? .green : .primary)
                            }
                        }
                    }
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

                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
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

        do {
            // Single API call with all regions at once
            let result = try await TravelMappingAPI.shared.getRegionSegments(
                regions: allRegions,
                traveler: username
            )

            // Group route metadata by region
            var regionMap: [String: (total: Double, clinched: Double, count: Int)] = [:]
            for route in result.routes {
                // Extract region from listName (e.g. "FL I-95" -> "FL")
                let region = route.listName.split(separator: " ").first.map(String.init) ?? ""
                var entry = regionMap[region, default: (0, 0, 0)]
                entry.total += route.mileage
                entry.clinched += route.clinchedMileage
                entry.count += 1
                regionMap[region] = entry
            }

            regionStats = regionMap.map { region, data in
                RegionStat(
                    id: region,
                    region: region,
                    totalMileage: data.total,
                    clinchedMileage: data.clinched,
                    routeCount: data.count
                )
            }
        } catch {
            // Fallback: show what we can without mileage
        }

        isLoadingMileage = false
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
