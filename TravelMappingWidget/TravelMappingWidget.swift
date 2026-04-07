import WidgetKit
import SwiftUI

// MARK: - Entry

struct TravelStatsEntry: TimelineEntry, Codable {
    let date: Date
    let username: String
    let routes: Int
    let totalMiles: Double
    let rank: Int
    let userCount: Int
    let percentile: Double
    let topRegion: String
    let topRegionMiles: Double
    let regionCount: Int
}

// MARK: - Timeline Provider

struct TravelStatsProvider: TimelineProvider {
    static let suiteName = "group.com.psiegel18.TravelMapping"

    func placeholder(in context: Context) -> TravelStatsEntry {
        TravelStatsEntry(
            date: Date(),
            username: "traveler",
            routes: 597,
            totalMiles: 4801,
            rank: 42,
            userCount: 512,
            percentile: 91.8,
            topRegion: "IL",
            topRegionMiles: 1711.8,
            regionCount: 31
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TravelStatsEntry) -> Void) {
        completion(loadCachedEntry() ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TravelStatsEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            let nextUpdate = Calendar.current.date(byAdding: .hour, value: 6, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
        }
    }

    private func fetchEntry() async -> TravelStatsEntry {
        let username = UserDefaults(suiteName: Self.suiteName)?.string(forKey: "widgetUsername") ?? "psiegel18"

        // Get route count from TM API
        let routes = (try? await fetchRouteCount(username: username)) ?? 0

        // Get mileage + rank from stats CSV
        let statsData = await fetchStatsFromCSV(username: username)

        let entry = TravelStatsEntry(
            date: Date(),
            username: username,
            routes: routes,
            totalMiles: statsData?.totalMiles ?? 0,
            rank: statsData?.rank ?? 0,
            userCount: statsData?.userCount ?? 0,
            percentile: statsData?.percentile ?? 0,
            topRegion: statsData?.topRegion ?? "",
            topRegionMiles: statsData?.topRegionMiles ?? 0,
            regionCount: statsData?.regionCount ?? 0
        )

        cacheEntry(entry)
        return entry
    }

    private func fetchRouteCount(username: String) async throws -> Int {
        let url = URL(string: "https://travelmapping.net/lib/getTravelerRoutes.php?dbname=TravelMapping")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "params={\"traveler\":\"\(username)\"}".data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = json["routes"] as? [String] else {
            return 0
        }
        return routes.count
    }

    private struct StatsResult {
        let totalMiles: Double
        let rank: Int
        let userCount: Int
        let percentile: Double
        let topRegion: String
        let topRegionMiles: Double
        let regionCount: Int
    }

    private func fetchStatsFromCSV(username: String) async -> StatsResult? {
        let url = URL(string: "https://travelmapping.net/stats/allbyregionactiveonly.csv")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }

        let headers = lines[0].components(separatedBy: ",")
        guard headers.count >= 3 else { return nil }
        let regionCodes = Array(headers.dropFirst(2))

        // Build list of (username, totalMiles) and find user
        var allUsers: [(username: String, miles: Double)] = []
        var userFields: [String]?

        for line in lines.dropFirst() {
            let fields = line.components(separatedBy: ",")
            guard fields.count == headers.count else { continue }
            let name = fields[0]
            let total = Double(fields[1]) ?? 0
            allUsers.append((username: name, miles: total))
            if name.lowercased() == username.lowercased() {
                userFields = fields
            }
        }

        guard let fields = userFields else { return nil }

        // Sort to find rank
        allUsers.sort { $0.miles > $1.miles }
        let rank = (allUsers.firstIndex(where: { $0.username.lowercased() == username.lowercased() }) ?? 0) + 1
        let totalMiles = Double(fields[1]) ?? 0
        let percentile = 100.0 - (Double(rank) / Double(allUsers.count) * 100.0)

        // Find top region
        var topRegion = ""
        var topMiles: Double = 0
        var regionCount = 0
        for (i, region) in regionCodes.enumerated() {
            let miles = Double(fields[i + 2]) ?? 0
            if miles > 0 {
                regionCount += 1
                if miles > topMiles {
                    topMiles = miles
                    topRegion = region
                }
            }
        }

        return StatsResult(
            totalMiles: totalMiles,
            rank: rank,
            userCount: allUsers.count,
            percentile: percentile,
            topRegion: topRegion,
            topRegionMiles: topMiles,
            regionCount: regionCount
        )
    }

    private func cacheEntry(_ entry: TravelStatsEntry) {
        if let encoded = try? JSONEncoder().encode(entry) {
            UserDefaults(suiteName: Self.suiteName)?.set(encoded, forKey: "cachedWidgetEntry")
        }
    }

    private func loadCachedEntry() -> TravelStatsEntry? {
        guard let data = UserDefaults(suiteName: Self.suiteName)?.data(forKey: "cachedWidgetEntry"),
              let entry = try? JSONDecoder().decode(TravelStatsEntry.self, from: data) else {
            return nil
        }
        return entry
    }
}

// MARK: - Widget Views

struct TravelMappingWidgetEntryView: View {
    var entry: TravelStatsProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallWidget
        case .systemMedium:
            mediumWidget
        case .systemLarge:
            largeWidget
        case .accessoryCircular:
            accessoryCircular
        case .accessoryRectangular:
            accessoryRectangular
        case .accessoryInline:
            accessoryInline
        default:
            smallWidget
        }
    }

    // MARK: - Small

    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image("WidgetIcon")
                    .resizable()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(entry.username)
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }

            Spacer()

            Text(formatMiles(entry.totalMiles))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("miles traveled")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))

            Spacer()

            if entry.rank > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "trophy.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                        Text("#\(entry.rank.formatted())")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                        Text("· \(entry.routes.formatted()) routes")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.white.opacity(0.15))
                                .frame(height: 4)
                            Capsule()
                                .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(geo.size.width * entry.percentile / 100, 4), height: 4)
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
    }

    // MARK: - Medium

    private var mediumWidget: some View {
        HStack(spacing: 12) {
            // Left: Identity & Miles
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image("WidgetIcon")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text("Travel Mapping")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.7))
                }

                Text(entry.username)
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Text(formatMiles(entry.totalMiles))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("miles traveled")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))

                Spacer()

                if entry.rank > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top \(String(format: "%.1f%%", entry.percentile))")
                            .font(.caption2.bold())
                            .foregroundStyle(.cyan)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.white.opacity(0.15))
                                Capsule()
                                    .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(geo.size.width * entry.percentile / 100, 4))
                            }
                        }
                        .frame(height: 5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Divider
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1)
                .padding(.vertical, 4)

            // Right: Rank & Stats
            VStack(spacing: 8) {
                if entry.rank > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "trophy.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                        Text("#\(entry.rank.formatted())")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                    }
                }

                HStack(spacing: 12) {
                    VStack(spacing: 2) {
                        Text("\(entry.routes.formatted())")
                            .font(.headline.bold())
                            .foregroundStyle(.cyan)
                        Text("routes")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    VStack(spacing: 2) {
                        Text("\(entry.regionCount.formatted())")
                            .font(.headline.bold())
                            .foregroundStyle(.green)
                        Text("regions")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                if !entry.topRegion.isEmpty {
                    VStack(spacing: 2) {
                        Text(entry.topRegion)
                            .font(.headline.bold())
                            .foregroundStyle(.orange)
                        Text("\(formatMiles(entry.topRegionMiles)) mi")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Large

    private var largeWidget: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image("WidgetIcon")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("Travel Mapping")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                Spacer()
                Text(entry.username)
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.1), in: Capsule())
            }

            // Hero: Miles
            VStack(alignment: .leading, spacing: 2) {
                Text(formatMiles(entry.totalMiles))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("miles traveled")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Rank + Percentile
            if entry.rank > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "trophy.fill")
                        .foregroundStyle(.yellow)
                    Text("#\(entry.rank.formatted())")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("of \(entry.userCount.formatted())")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Text("Top \(String(format: "%.1f%%", entry.percentile))")
                        .font(.caption.bold())
                        .foregroundStyle(.cyan)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.12))
                        Capsule()
                            .fill(LinearGradient(colors: [.cyan, .blue, .purple], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(geo.size.width * entry.percentile / 100, 6))
                    }
                }
                .frame(height: 6)
            }

            // Stats cards
            HStack(spacing: 8) {
                statCard(value: "\(entry.routes.formatted())", label: "Routes", icon: "road.lanes", color: .cyan)
                statCard(value: "\(entry.regionCount.formatted())", label: "Regions", icon: "map", color: .green)
                if !entry.topRegion.isEmpty {
                    statCard(value: entry.topRegion, label: "Top Region", icon: "star.fill", color: .orange, subtext: "\(formatMiles(entry.topRegionMiles)) mi")
                }
            }

            Spacer()

            // Footer
            Text("Updated \(entry.date.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private func statCard(value: String, label: String, icon: String, color: Color, subtext: String? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            if let sub = subtext {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(color.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Accessory (Lock Screen)

    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(formatMilesShort(entry.totalMiles))
                    .font(.system(.headline, design: .rounded).bold())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("mi")
                    .font(.caption2)
            }
        }
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "road.lanes")
                Text(entry.username)
                    .lineLimit(1)
            }
            .font(.caption.bold())

            Text("\(formatMiles(entry.totalMiles)) mi")
                .font(.headline)
            if entry.rank > 0 {
                Text("#\(entry.rank) · \(entry.routes) routes")
                    .font(.caption2)
            }
        }
    }

    private var accessoryInline: some View {
        if entry.rank > 0 {
            Text("\(formatMiles(entry.totalMiles)) mi · #\(entry.rank)")
        } else {
            Text("\(formatMiles(entry.totalMiles)) mi")
        }
    }

    // MARK: - Formatting

    private func formatMiles(_ miles: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: miles)) ?? "0"
    }

    private func formatMilesShort(_ miles: Double) -> String {
        if miles >= 10000 {
            return String(format: "%.0fk", miles / 1000)
        }
        return String(format: "%.0f", miles)
    }
}

// MARK: - Widget Configuration

struct TravelMappingWidget: Widget {
    let kind: String = "TravelMappingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TravelStatsProvider()) { entry in
            TravelMappingWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.06, green: 0.10, blue: 0.24),
                            Color(red: 0.13, green: 0.08, blue: 0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .configurationDisplayName("Travel Stats")
        .description("Shows your Travel Mapping rank, miles, and regions.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

@main
struct TravelMappingWidgetBundle: WidgetBundle {
    var body: some Widget {
        TravelMappingWidget()
        RoadTripLiveActivity()
    }
}
