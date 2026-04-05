import SwiftUI

struct LeaderboardView: View {
    @State private var snapshot: TMStatsService.LeaderboardSnapshot?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var lastUpdated: Date?
    @State private var searchText = ""
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

    var body: some View {
        Group {
            if isLoading && snapshot == nil {
                ProgressView("Loading leaderboard...")
            } else if let snapshot {
                List {
                    if !settings.primaryUser.isEmpty,
                       let position = snapshot.position(of: settings.primaryUser),
                       let user = snapshot.users.first(where: { $0.username.lowercased() == settings.primaryUser.lowercased() }) {
                        Section("Your Rank") {
                            YourRankRow(
                                rank: position.rank,
                                total: snapshot.userCount,
                                percentile: position.percentile,
                                miles: user.totalMiles,
                                useMiles: settings.useMiles
                            )
                        }
                    }

                    Section(searchText.isEmpty ? "Top Travelers" : "Search Results") {
                        ForEach(filteredTop100, id: \.user.username) { item in
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

struct YourRankRow: View {
    let rank: Int
    let total: Int
    let percentile: Double
    let miles: Double
    let useMiles: Bool

    private var displayMiles: Double { useMiles ? miles : miles * 1.60934 }
    private var unit: String { useMiles ? "mi" : "km" }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("#\(rank) of \(total)")
                    .font(.title2.bold())
                    .foregroundStyle(.blue)
                Text(String(format: "Top %.1f%%", percentile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.0f %@", displayMiles, unit))
                    .font(.title3.bold())
                    .monospacedDigit()
                Text("traveled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct LeaderboardRow: View {
    let rank: Int
    let username: String
    let miles: Double
    let useMiles: Bool

    private var displayMiles: Double { useMiles ? miles : miles * 1.60934 }
    private var unit: String { useMiles ? "mi" : "km" }

    private var numberFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }

    var body: some View {
        HStack {
            Text("#\(rank)")
                .font(.caption.bold())
                .foregroundStyle(rank <= 3 ? .yellow : .secondary)
                .frame(width: 40, alignment: .leading)
                .monospacedDigit()

            Text(username)
                .font(.headline)

            Spacer()

            Text("\(numberFormatter.string(from: NSNumber(value: displayMiles)) ?? "0") \(unit)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rank \(rank), \(username)")
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
