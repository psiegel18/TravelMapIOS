import SwiftUI

struct LeaderboardView: View {
    @State private var snapshot: TMStatsService.LeaderboardSnapshot?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var lastUpdated: Date?
    @State private var searchText = ""
    @State private var podiumSelection: PodiumSelection?
    @StateObject private var dataService = DataService()
    @ObservedObject private var settings = SyncedSettingsService.shared

    private var filteredTop100: [(index: Int, user: TMStatsService.UserRegionStats)] {
        guard let snapshot else { return [] }
        let top = Array(snapshot.users.prefix(100).enumerated())
        if searchText.isEmpty {
            return top.map { (index: $0.offset, user: $0.element) }
        }
        // Search across all users, not just top 100
        return Array(snapshot.users.enumerated())
            .filter { $0.element.username.localizedCaseInsensitiveContains(searchText) }
            .prefix(100)
            .map { (index: $0.offset, user: $0.element) }
    }

    /// Podium leads the list only when no search filter is active.
    private var showsPodium: Bool {
        searchText.isEmpty && (snapshot?.users.count ?? 0) >= 3
    }

    var body: some View {
        Group {
            if isLoading && snapshot == nil {
                ProgressView("Loading leaderboard...")
            } else if let snapshot {
                List {
                    if showsPodium {
                        Section {
                            PodiumView(
                                users: Array(snapshot.users.prefix(3)),
                                useMiles: settings.useMiles,
                                onSelect: { podiumSelection = PodiumSelection(username: $0) }
                            )
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }

                    Section(searchText.isEmpty ? "Top Travelers" : "Search Results") {
                        // Ranks 1-3 live on the podium when it's visible.
                        ForEach(showsPodium ? Array(filteredTop100.dropFirst(3)) : filteredTop100, id: \.user.username) { item in
                            NavigationLink(value: item.user.username) {
                                LeaderboardRow(
                                    rank: item.index + 1,
                                    username: item.user.username,
                                    miles: item.user.totalMiles,
                                    useMiles: settings.useMiles
                                )
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    // Pinned your-rank bar — always in reach when the primary user is ranked.
                    if !settings.primaryUser.isEmpty,
                       let position = snapshot.position(of: settings.primaryUser),
                       let user = snapshot.users.first(where: { $0.username.lowercased() == settings.primaryUser.lowercased() }) {
                        PinnedRankBar(
                            username: user.username,
                            rank: position.rank,
                            total: snapshot.userCount,
                            percentile: position.percentile,
                            miles: user.totalMiles,
                            useMiles: settings.useMiles
                        )
                    }
                }
            } else {
                ErrorView(
                    title: "Couldn't Load Leaderboard",
                    message: errorMessage ?? "Unknown error"
                ) {
                    await load(forceRefresh: true)
                }
            }
        }
        .navigationTitle("Leaderboard")
        .searchable(text: $searchText, prompt: "Search travelers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FreshnessIndicator(lastUpdated: lastUpdated)
            }
        }
        .navigationDestination(for: String.self) { username in
            LeaderboardUserDetailView(username: username, dataService: dataService)
        }
        .navigationDestination(item: $podiumSelection) { selection in
            LeaderboardUserDetailView(username: selection.username, dataService: dataService)
        }
        .refreshable {
            await load(forceRefresh: true)
        }
        .task {
            if snapshot == nil {
                await load(forceRefresh: false)
            }
        }
    }

    private func load(forceRefresh: Bool) async {
        isLoading = true
        errorMessage = nil
        do {
            snapshot = try await TMStatsService.shared.loadRegionStats(forceRefresh: forceRefresh)
            lastUpdated = await TMStatsService.shared.lastUpdated()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

/// Programmatic podium navigation target — the podium's three columns share one
/// List row, so value-based NavigationLinks there all collapse into a single row
/// tap that fires the last link (rank 3).
struct PodiumSelection: Identifiable, Hashable {
    let username: String
    var id: String { username }
}

/// Shared miles/km display used by podium, rows, and the pinned bar.
private func formattedDistance(miles: Double, useMiles: Bool) -> String {
    let value = Int(useMiles ? miles : miles * 1.60934)
    return "\(value.formatted()) \(useMiles ? "mi" : "km")"
}

/// Podium for the top three (audit §3): center column tallest, crown on #1,
/// gradient plinths with always-present numerals (rank never rides on color alone).
struct PodiumView: View {
    let users: [TMStatsService.UserRegionStats]
    let useMiles: Bool
    let onSelect: (String) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if users.count >= 3 {
                podiumColumn(place: 2, user: users[1])
                podiumColumn(place: 1, user: users[0])
                podiumColumn(place: 3, user: users[2])
            }
        }
    }

    private func podiumColumn(place: Int, user: TMStatsService.UserRegionStats) -> some View {
        // Plain-style Button per column: three NavigationLinks in one List row all
        // collapse into a single row tap that activates the last link, so a tap on
        // rank 1 or 2 would open rank 3. .plain keeps each column its own hit target.
        Button {
            onSelect(user.username)
        } label: {
            podiumColumnContent(place: place, user: user)
        }
        .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Rank \(place), \(user.username), \(formattedDistance(miles: user.totalMiles, useMiles: useMiles))")
    }

    private func podiumColumnContent(place: Int, user: TMStatsService.UserRegionStats) -> some View {
            VStack(spacing: 6) {
                if place == 1 {
                    Text("👑")
                        .font(.system(size: 22))
                        .accessibilityHidden(true)
                }

                avatar(place: place, name: user.username)

                Text(user.username)
                    .font(.system(size: 14, weight: .heavy))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(formattedDistance(miles: user.totalMiles, useMiles: useMiles))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(TMDesign.tertiaryText)

                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 12,
                    style: .continuous
                )
                .fill(plinthGradient(place: place))
                .frame(height: plinthHeight(place: place))
                .overlay(
                    Text("\(place)")
                        .font(.system(size: numeralSize(place: place), weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(numeralColor(place: place))
                )
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func avatar(place: Int, name: String) -> some View {
        switch place {
        case 1:
            TMMonogramAvatar(
                name: name,
                size: 54,
                background: Color(tmLight: 0xFFF1C9, dark: 0x3A2F14),
                foreground: Color(tmLight: 0xB47F14, dark: 0xF2C438)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 54 * 0.3, style: .continuous)
                    .stroke(TMDesign.gold, lineWidth: 2)
            )
        case 3:
            TMMonogramAvatar(
                name: name,
                size: 46,
                background: Color(tmLight: 0xF3E3D3, dark: 0x54402A),
                foreground: Color(tmLight: 0x9A6B3F, dark: 0xE0B78A)
            )
        default:
            TMMonogramAvatar(name: name, size: 46)
        }
    }

    private func plinthHeight(place: Int) -> CGFloat {
        switch place {
        case 1: return 72
        case 2: return 52
        default: return 40
        }
    }

    private func numeralSize(place: Int) -> CGFloat {
        switch place {
        case 1: return 19
        case 2: return 17
        default: return 16
        }
    }

    /// Light gradients from §3, dark counterparts from §10.
    private func plinthGradient(place: Int) -> LinearGradient {
        let colors: [Color]
        switch place {
        case 1:
            colors = [Color(tmLight: 0xFBD96B, dark: 0xC79A1E), Color(tmLight: 0xF2C438, dark: 0x9C7815)]
        case 2:
            colors = [Color(tmLight: 0xD7DCE6, dark: 0x3A3F48), Color(tmLight: 0xC3C9D6, dark: 0x2C313A)]
        default:
            colors = [Color(tmLight: 0xE0C4A6, dark: 0x6E5335), Color(tmLight: 0xD0AE8C, dark: 0x54402A)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private func numeralColor(place: Int) -> Color {
        switch place {
        case 1: return Color(tmLight: 0x8A670C, dark: 0xFFE58A)
        case 2: return Color(tmLight: 0x5A6172, dark: 0xAAB0BD)
        default: return Color(tmLight: 0x7C5732, dark: 0xE0B78A)
        }
    }
}

/// Floating your-rank bar pinned above the tab bar (audit §3). Stays
/// Trailblazer Blue in dark mode per §10.
struct PinnedRankBar: View {
    let username: String
    let rank: Int
    let total: Int
    let percentile: Double
    let miles: Double
    let useMiles: Bool

    private var displayMiles: Int { Int(useMiles ? miles : miles * 1.60934) }

    var body: some View {
        HStack(spacing: 12) {
            TMMonogramAvatar(
                name: username,
                size: 38,
                background: Color.white.opacity(0.22),
                foreground: .white
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("#\(rank.formatted())")
                        .font(.system(size: 17, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("of \(total.formatted())")
                        .font(.system(size: 15, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(String(format: "You · Top %.1f%%", percentile))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(displayMiles.formatted())
                    .font(.system(size: 17, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(useMiles ? "miles" : "km")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(tmHex: 0x2F6BF0), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color(tmHex: 0x2F6BF0).opacity(0.4), radius: 13, x: 0, y: 5)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: "Your rank: %@ of %@, top %.1f percent, %@ %@", rank.formatted(), total.formatted(), percentile, displayMiles.formatted(), useMiles ? "miles" : "kilometers"))
    }
}

struct LeaderboardRow: View {
    let rank: Int
    let username: String
    let miles: Double
    let useMiles: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(rank.formatted())
                .font(.system(size: 15, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(TMDesign.tertiaryText)
                .frame(width: 32, alignment: .leading)

            TMMonogramAvatar(name: username, size: 34)

            Text(username)
                .font(.system(size: 16, weight: .bold))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(formattedDistance(miles: miles, useMiles: useMiles))
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(TMDesign.secondaryText)
        }
        .frame(minHeight: 44) // + default list row padding ≈ the spec's 56pt row
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rank \(rank), \(username), \(formattedDistance(miles: miles, useMiles: useMiles))")
    }
}

/// Loads user data then shows UserDetailView
struct LeaderboardUserDetailView: View {
    let username: String
    @ObservedObject var dataService: DataService
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded {
                UserDetailView(username: username, dataService: dataService)
            } else {
                ProgressView("Loading \(username)...")
                    .task {
                        if dataService.users.isEmpty {
                            dataService.loadUserList()
                        }
                        loaded = true
                    }
            }
        }
    }
}
