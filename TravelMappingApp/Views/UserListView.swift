import SwiftUI

struct UserListView: View {
    @ObservedObject var dataService: DataService
    @ObservedObject private var favoritesService = FavoritesService.shared
    @ObservedObject private var settings = SyncedSettingsService.shared
    @State private var searchText = ""
    @State private var filter: TravelerFilter = .all
    @State private var heroStats: TravelerHeroStats?

    enum TravelerFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case favorites = "Favorites"
        case recent = "Recent"
        var id: String { rawValue }
    }

    private var primaryUser: String { settings.primaryUser }

    var filteredUsers: [DataService.UserSummary] {
        let searched: [DataService.UserSummary]
        if searchText.isEmpty {
            searched = dataService.users
        } else {
            searched = dataService.users.filter {
                $0.username.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch filter {
        case .all:
            // Explicit filter chips replace the old implicit favorites-first sort.
            return searched.sorted {
                $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
            }
        case .favorites:
            let favs = favoritesService.favorites
            return searched
                .filter { favs.contains($0.username) }
                .sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
        case .recent:
            // Preserve most-recent-first ordering from settings.recentUsers.
            return settings.recentUsers.compactMap { recentName in
                searched.first { $0.username == recentName }
            }
        }
    }

    var body: some View {
        Group {
            // Only show the full-screen states when there's no data yet — a pull-refresh
            // with existing data keeps the List alive instead of tearing it down.
            if dataService.isLoading && dataService.users.isEmpty {
                ProgressView("Loading users...")
            } else if let error = dataService.errorMessage, dataService.users.isEmpty {
                ErrorView(message: error) {
                    await MainActor.run {
                        dataService.loadUserList()
                    }
                }
            } else {
                List {
                    if !primaryUser.isEmpty, let user = dataService.users.first(where: { $0.username.lowercased() == primaryUser.lowercased() }) {
                        Section {
                            ZStack {
                                // Invisible link keeps navigation while hiding the List chevron
                                // next to the gradient card.
                                NavigationLink(value: user) { EmptyView() }
                                    .opacity(0)
                                TravelerHeroCard(
                                    username: user.username,
                                    stats: heroStats,
                                    useMiles: settings.useMiles
                                )
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }

                    Section {
                        filterChipRow
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }

                    Section {
                        ForEach(filteredUsers) { user in
                            NavigationLink(value: user) {
                                UserRowView(
                                    user: user,
                                    isFavorite: favoritesService.isFavorite(user.username)
                                )
                            }
                    .swipeActions(edge: .leading) {
                        Button {
                            Haptics.selection()
                            favoritesService.toggleFavorite(user.username)
                        } label: {
                            if favoritesService.isFavorite(user.username) {
                                Label("Unfavorite", systemImage: "star.slash")
                            } else {
                                Label("Favorite", systemImage: "star.fill")
                            }
                        }
                        .tint(.yellow)
                    }
                    .accessibilityHint(favoritesService.isFavorite(user.username) ? "Favorited. Swipe right to unfavorite." : "Swipe right to favorite.")
                        }
                    }
                }
                .searchable(text: $searchText, prompt: "Search \(dataService.users.count.formatted()) travelers")
                .overlay {
                    if filteredUsers.isEmpty {
                        if !searchText.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        } else if filter == .favorites {
                            ContentUnavailableView(
                                "No Favorites Yet",
                                systemImage: "star",
                                description: Text("Swipe right on a traveler to add them to your favorites.")
                            )
                        } else if filter == .recent {
                            ContentUnavailableView(
                                "No Recent Travelers",
                                systemImage: "clock",
                                description: Text("Travelers you view will show up here.")
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle("Travelers")
        .onAppear {
            if dataService.users.isEmpty {
                dataService.loadUserList()
            }
        }
        .refreshable {
            dataService.loadUserList()
            // loadUserList kicks off an internal Task — wait for it to finish so
            // the pull-to-refresh spinner reflects the actual reload.
            while dataService.isLoading {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .task(id: settings.primaryUser) {
            guard !settings.primaryUser.isEmpty else {
                heroStats = nil
                return
            }
            // Same cached snapshot the Leaderboard tab uses (12h TTL) — no new API surface.
            guard let snapshot = try? await TMStatsService.shared.loadRegionStats(forceRefresh: false),
                  let position = snapshot.position(of: settings.primaryUser),
                  let user = snapshot.users.first(where: { $0.username.lowercased() == settings.primaryUser.lowercased() }) else {
                return
            }
            heroStats = TravelerHeroStats(
                rank: position.rank,
                totalUsers: snapshot.userCount,
                percentile: position.percentile,
                miles: user.totalMiles,
                regionCount: user.byRegion.filter { $0.value > 0 }.count
            )
        }
    }

    private var filterChipRow: some View {
        HStack(spacing: 8) {
            ForEach(TravelerFilter.allCases) { option in
                let isSelected = filter == option
                Button {
                    filter = option
                } label: {
                    HStack(spacing: 5) {
                        if option == .favorites {
                            Image(systemName: "star.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isSelected ? .white : TMDesign.gold)
                        }
                        Text(option.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 8)
                    .background(
                        isSelected ? TMDesign.accent : TMDesign.cardBG,
                        in: Capsule()
                    )
                    .foregroundStyle(isSelected ? .white : Color(tmLight: 0x3A3A40, dark: 0xE0E0E6))
                    .frame(minHeight: 44) // 44pt target; visible capsule stays compact
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
    }
}

/// Primary-user stats for the hero card, sourced from the cached leaderboard snapshot.
struct TravelerHeroStats {
    let rank: Int
    let totalUsers: Int
    let percentile: Double
    let miles: Double
    let regionCount: Int
}

/// Gradient identity hero for the primary user (audit §1). Gradient is fixed
/// per spec — white text in both light and dark mode.
struct TravelerHeroCard: View {
    let username: String
    let stats: TravelerHeroStats?
    let useMiles: Bool

    private var displayMiles: Int {
        Int(useMiles ? (stats?.miles ?? 0) : (stats?.miles ?? 0) * 1.60934)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                TMMonogramAvatar(
                    name: username,
                    size: 52,
                    background: Color.white.opacity(0.22),
                    foreground: .white
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(username)
                        .font(.system(size: 21, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Your profile")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.82))
                }
                Spacer(minLength: 8)
                if let stats {
                    HStack(spacing: 4) {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(tmHex: 0xFFD84D))
                        Text("#\(stats.rank.formatted())")
                            .font(.system(size: 13, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.18), in: Capsule())
                }
            }

            if let stats {
                HStack(spacing: 0) {
                    heroStat(value: stats.regionCount.formatted(), label: "regions")
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1)
                        .padding(.vertical, 6)
                    heroStat(value: displayMiles.formatted(), label: useMiles ? "miles" : "km")
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1)
                        .padding(.vertical, 6)
                    heroStat(value: String(format: "%.1f%%", stats.percentile), label: "percentile")
                }
                .background(
                    Color.white.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(tmHex: 0x2F6BF0), Color(tmHex: 0x1E4FD0)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .shadow(color: Color(tmHex: 0x2F6BF0).opacity(0.28), radius: 11, x: 0, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private func heroStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 19, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var heroAccessibilityLabel: String {
        var label = "\(username), your profile"
        if let stats {
            label += ". Rank \(stats.rank.formatted()) of \(stats.totalUsers.formatted()). "
            label += "\(stats.regionCount.formatted()) regions, \(displayMiles.formatted()) \(useMiles ? "miles" : "kilometers")"
        }
        return label
    }
}

struct UserRowView: View {
    let user: DataService.UserSummary
    let isFavorite: Bool

    private var categoryDescription: String {
        var cats: [String] = []
        if user.hasRoads { cats.append("Roads") }
        if user.hasRail { cats.append("Rail") }
        if user.hasFerry { cats.append("Ferry") }
        if user.hasScenic { cats.append("Scenic") }
        return cats.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 12) {
            TMMonogramAvatar(name: user.username, size: 40, isFavorite: isFavorite)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(user.username)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(TMDesign.gold)
                            .font(.system(size: 13))
                            .accessibilityHidden(true)
                    }
                }
                HStack(spacing: 6) {
                    if user.hasRoads {
                        TMChip(text: "Roads", icon: "car.fill", bg: TMDesign.blueChipBG, fg: TMDesign.blueChipFG)
                    }
                    if user.hasRail {
                        TMChip(text: "Rail", icon: "tram.fill", bg: TMDesign.redChipBG, fg: TMDesign.redChipFG)
                    }
                    if user.hasFerry {
                        TMChip(text: "Ferry", icon: "ferry.fill", bg: TMDesign.greenChipBG, fg: TMDesign.greenChipFG)
                    }
                    if user.hasScenic {
                        TMChip(text: "Scenic", icon: "leaf.fill", bg: TMDesign.purpleChipBG, fg: TMDesign.purpleChipFG)
                    }
                }
            }
        }
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(user.username)\(isFavorite ? ", favorited" : ""). \(categoryDescription)")
    }
}
