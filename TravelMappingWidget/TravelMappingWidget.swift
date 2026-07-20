import WidgetKit
import SwiftUI

// MARK: - Brand palette (design audit §12)
// The widget target can't see TMDesign (app target). Widget surfaces are fixed
// dark gradients, so fixed brand hexes are correct here (dark-surface variants).

extension Color {
    /// Fixed hex color for widget / Live Activity surfaces.
    init(tmwHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

private enum WidgetPalette {
    static let blue = Color(tmwHex: 0x5B8CFF)        // Trailblazer Blue (bright variant)
    static let blueDeep = Color(tmwHex: 0x2F6BF0)    // Trailblazer Blue (base)
    static let green = Color(tmwHex: 0x4FD69C)       // Clinched Green
    static let amber = Color(tmwHex: 0xF6B45A)       // Frontier Amber
    static let gold = Color(tmwHex: 0xFFD84D)        // rank trophy
    static let gradientTop = Color(tmwHex: 0x0F1A3D)
    static let gradientBottom = Color(tmwHex: 0x221450)

    /// Shared progress-bar gradient (replaces the old cyan/purple).
    static let barGradient = LinearGradient(
        colors: [blue, blueDeep],
        startPoint: .leading,
        endPoint: .trailing
    )
}

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
    /// Whether to display distances in miles (false = kilometers). Mirrors the app's
    /// units preference, written to the app group as "widgetUseMiles" and encoded
    /// into "cachedWidgetEntry" by ContentView. Distances are always *stored* in miles.
    let useMiles: Bool
}

// Custom decoding lives in an extension so the memberwise initializer is preserved.
// `useMiles` uses decodeIfPresent so cached entries written before the field existed
// still decode (backward-compatible Codable convention).
extension TravelStatsEntry {
    enum CodingKeys: String, CodingKey {
        case date, username, routes, totalMiles, rank, userCount
        case percentile, topRegion, topRegionMiles, regionCount, useMiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        username = try container.decode(String.self, forKey: .username)
        routes = try container.decode(Int.self, forKey: .routes)
        totalMiles = try container.decode(Double.self, forKey: .totalMiles)
        rank = try container.decode(Int.self, forKey: .rank)
        userCount = try container.decode(Int.self, forKey: .userCount)
        percentile = try container.decode(Double.self, forKey: .percentile)
        topRegion = try container.decode(String.self, forKey: .topRegion)
        topRegionMiles = try container.decode(Double.self, forKey: .topRegionMiles)
        regionCount = try container.decode(Int.self, forKey: .regionCount)
        useMiles = try container.decodeIfPresent(Bool.self, forKey: .useMiles) ?? true
    }
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
            regionCount: 31,
            useMiles: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TravelStatsEntry) -> Void) {
        completion(loadCachedEntry() ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TravelStatsEntry>) -> Void) {
        Task {
            if let entry = await fetchEntry() {
                // Only successful fetches are cached — a failure must never
                // clobber the last good entry with zeros.
                cacheEntry(entry)
                let nextUpdate = Calendar.current.date(byAdding: .hour, value: 6, to: Date())!
                completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
            } else {
                // Network failure: show the last good (possibly stale) entry and
                // retry sooner. Zeros only when there's no cache at all.
                let fallback = loadCachedEntry() ?? emptyEntry()
                let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
                completion(Timeline(entries: [fallback], policy: .after(nextUpdate)))
            }
        }
    }

    /// Returns nil when the stats fetch fails so getTimeline can fall back to cache.
    private func fetchEntry() async -> TravelStatsEntry? {
        let defaults = UserDefaults(suiteName: Self.suiteName)
        let username = defaults?.string(forKey: "widgetUsername") ?? "psiegel18"

        // Get mileage + rank from stats CSV — the core of the widget. No stats, no entry.
        guard let statsData = await fetchStatsFromCSV(username: username) else {
            return nil
        }

        // Get route count from TM API; fall back to the cached count on failure so a
        // partial outage doesn't zero the routes stat.
        let routes = (try? await fetchRouteCount(username: username)) ?? loadCachedEntry()?.routes ?? 0

        return TravelStatsEntry(
            date: Date(),
            username: username,
            routes: routes,
            totalMiles: statsData.totalMiles,
            rank: statsData.rank,
            userCount: statsData.userCount,
            percentile: statsData.percentile,
            topRegion: statsData.topRegion,
            topRegionMiles: statsData.topRegionMiles,
            regionCount: statsData.regionCount,
            useMiles: preferredUseMiles()
        )
    }

    private func emptyEntry() -> TravelStatsEntry {
        let username = UserDefaults(suiteName: Self.suiteName)?.string(forKey: "widgetUsername") ?? "psiegel18"
        return TravelStatsEntry(
            date: Date(),
            username: username,
            routes: 0,
            totalMiles: 0,
            rank: 0,
            userCount: 0,
            percentile: 0,
            topRegion: "",
            topRegionMiles: 0,
            regionCount: 0,
            useMiles: preferredUseMiles()
        )
    }

    /// Units preference written by the app (ContentView) to the app group.
    /// Absent key (widget added before the app ever wrote it) defaults to miles.
    private func preferredUseMiles() -> Bool {
        (UserDefaults(suiteName: Self.suiteName)?.object(forKey: "widgetUseMiles") as? Bool) ?? true
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
            // Skip the summary row (same pattern as TMStatsService) — counting it
            // shifts every rank by one and inflates userCount.
            if name.uppercased() == "TOTAL" { continue }
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
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }

            Spacer()

            Text(formatMiles(entry.totalMiles))
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(distanceCaption)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))

            Spacer()

            if entry.rank > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "trophy.fill")
                            .font(.caption2)
                            .foregroundStyle(WidgetPalette.gold)
                        Text("#\(entry.rank.formatted())")
                            .font(.caption.bold())
                            .monospacedDigit()
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
                                .fill(WidgetPalette.barGradient)
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
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(distanceCaption)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))

                Spacer()

                if entry.rank > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top \(String(format: "%.1f%%", entry.percentile))")
                            .font(.caption2.bold())
                            .foregroundStyle(WidgetPalette.blue)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.white.opacity(0.15))
                                Capsule()
                                    .fill(WidgetPalette.barGradient)
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
                            .foregroundStyle(WidgetPalette.gold)
                        Text("#\(entry.rank.formatted())")
                            .font(.title3.bold())
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                }

                HStack(spacing: 12) {
                    VStack(spacing: 2) {
                        Text("\(entry.routes.formatted())")
                            .font(.headline.bold())
                            .monospacedDigit()
                            .foregroundStyle(WidgetPalette.blue)
                        Text("routes")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    VStack(spacing: 2) {
                        Text("\(entry.regionCount.formatted())")
                            .font(.headline.bold())
                            .monospacedDigit()
                            .foregroundStyle(WidgetPalette.green)
                        Text("regions")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                if !entry.topRegion.isEmpty {
                    VStack(spacing: 2) {
                        Text(entry.topRegion)
                            .font(.headline.bold())
                            .foregroundStyle(WidgetPalette.amber)
                        Text("\(formatMiles(entry.topRegionMiles)) \(unitAbbreviation)")
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
                    .font(.system(size: 48, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(distanceCaption)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Rank + Percentile
            if entry.rank > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "trophy.fill")
                        .foregroundStyle(WidgetPalette.gold)
                    Text("#\(entry.rank.formatted())")
                        .font(.title3.bold())
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("of \(entry.userCount.formatted())")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Text("Top \(String(format: "%.1f%%", entry.percentile))")
                        .font(.caption.bold())
                        .foregroundStyle(WidgetPalette.blue)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.12))
                        Capsule()
                            .fill(WidgetPalette.barGradient)
                            .frame(width: max(geo.size.width * entry.percentile / 100, 6))
                    }
                }
                .frame(height: 6)
            }

            // Stats cards
            HStack(spacing: 8) {
                statCard(value: "\(entry.routes.formatted())", label: "Routes", icon: "road.lanes", color: WidgetPalette.blue)
                statCard(value: "\(entry.regionCount.formatted())", label: "Regions", icon: "map", color: WidgetPalette.green)
                if !entry.topRegion.isEmpty {
                    statCard(value: entry.topRegion, label: "Top Region", icon: "star.fill", color: WidgetPalette.amber, subtext: "\(formatMiles(entry.topRegionMiles)) \(unitAbbreviation)")
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

    /// Completion fraction for the lock-screen ring. The entry carries no
    /// traveled/available mileage pair, so the ring mirrors the percentile that
    /// already drives the home-widget progress bars (Top X% → X% of the ring).
    private var ringFraction: Double {
        guard entry.rank > 0 else { return 0 }
        return min(max(entry.percentile / 100, 0), 1)
    }

    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: 5)
                .padding(3)
            Circle()
                .trim(from: 0, to: ringFraction)
                .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
            VStack(spacing: 0) {
                Text(formatMilesShort(entry.totalMiles))
                    .font(.system(.subheadline, design: .rounded).bold())
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(unitAbbreviation)
                    .font(.caption2)
            }
            .padding(.horizontal, 10)
        }
        .accessibilityLabel("\(formatMiles(entry.totalMiles)) \(distanceCaption), top \(Int(entry.percentile.rounded())) percent")
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "road.lanes")
                Text(entry.username)
                    .lineLimit(1)
            }
            .font(.caption.bold())

            Text("\(formatMiles(entry.totalMiles)) \(unitAbbreviation)")
                .font(.headline)
            if entry.rank > 0 {
                Text("#\(entry.rank.formatted()) · \(entry.routes.formatted()) routes")
                    .font(.caption2)
            }
        }
    }

    private var accessoryInline: some View {
        if entry.rank > 0 {
            Text("\(formatMiles(entry.totalMiles)) \(unitAbbreviation) · #\(entry.rank.formatted())")
        } else {
            Text("\(formatMiles(entry.totalMiles)) \(unitAbbreviation)")
        }
    }

    // MARK: - Formatting

    /// All stored distances are miles; convert for display when the user prefers km.
    private func displayDistance(_ miles: Double) -> Double {
        entry.useMiles ? miles : miles * 1.609344
    }

    private var unitAbbreviation: String {
        entry.useMiles ? "mi" : "km"
    }

    private var distanceCaption: String {
        entry.useMiles ? "miles traveled" : "km traveled"
    }

    private func formatMiles(_ miles: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: displayDistance(miles))) ?? "0"
    }

    private func formatMilesShort(_ miles: Double) -> String {
        let value = displayDistance(miles)
        if value >= 10000 {
            return String(format: "%.0fk", value / 1000)
        }
        return String(format: "%.0f", value)
    }
}

// MARK: - Widget Configuration

struct TravelMappingWidget: Widget {
    let kind: String = "TravelMappingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TravelStatsProvider()) { entry in
            TravelMappingWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    // Brand indigo gradient (audit §12): #0F1A3D → #221450, 135°.
                    LinearGradient(
                        colors: [WidgetPalette.gradientTop, WidgetPalette.gradientBottom],
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
