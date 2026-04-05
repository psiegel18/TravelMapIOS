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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "road.lanes")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text(entry.username)
                    .font(.caption.bold())
                    .lineLimit(1)
            }

            Spacer()

            Text(formatMiles(entry.totalMiles))
                .font(.system(.title, design: .rounded).bold())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text("miles")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            if entry.rank > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "trophy.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                    Text("#\(entry.rank) · \(String(format: "%.0f%%", entry.percentile))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Medium

    private var mediumWidget: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "road.lanes")
                        .foregroundStyle(.blue)
                    Text("Travel Mapping")
                        .font(.caption.bold())
                }

                Text(entry.username)
                    .font(.headline)
                    .lineLimit(1)

                if entry.rank > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "trophy.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                        Text("#\(entry.rank) of \(entry.userCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(String(format: "Top %.1f%%", entry.percentile))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(spacing: 2) {
                Text(formatMiles(entry.totalMiles))
                    .font(.system(.title, design: .rounded).bold())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("miles traveled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()
                    .frame(width: 60)
                    .padding(.vertical, 2)

                HStack(spacing: 10) {
                    VStack(spacing: 0) {
                        Text("\(entry.routes)")
                            .font(.subheadline.bold())
                        Text("routes")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        Text("\(entry.regionCount)")
                            .font(.subheadline.bold())
                        Text("regions")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Large

    private var largeWidget: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "road.lanes")
                    .foregroundStyle(.blue)
                Text("Travel Mapping")
                    .font(.headline.bold())
                Spacer()
                Text(entry.username)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Main stat
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatMiles(entry.totalMiles))
                        .font(.system(.largeTitle, design: .rounded).bold())
                    Text("miles traveled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "trophy.fill")
                            .foregroundStyle(.yellow)
                        Text("#\(entry.rank)")
                            .font(.title3.bold())
                    }
                    Text("of \(entry.userCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(format: "Top %.1f%%", entry.percentile))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Stats grid
            HStack {
                statTile(value: "\(entry.routes)", label: "Routes", color: .blue)
                statTile(value: "\(entry.regionCount)", label: "Regions", color: .green)
                if !entry.topRegion.isEmpty {
                    statTile(
                        value: entry.topRegion,
                        label: "Top Region",
                        color: .orange,
                        subtext: String(format: "%.0f mi", entry.topRegionMiles)
                    )
                }
            }

            Spacer()

            // Footer
            Text("Updated \(entry.date.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func statTile(value: String, label: String, color: Color, subtext: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let sub = subtext {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
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
                .containerBackground(.fill.tertiary, for: .widget)
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
