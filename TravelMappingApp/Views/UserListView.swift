import SwiftUI

struct UserListView: View {
    @ObservedObject var dataService: DataService
    @ObservedObject private var favoritesService = FavoritesService.shared
    @ObservedObject private var settings = SyncedSettingsService.shared
    @State private var searchText = ""

    private var primaryUser: String { settings.primaryUser }

    var filteredUsers: [DataService.UserSummary] {
        let base: [DataService.UserSummary]
        if searchText.isEmpty {
            base = dataService.users
        } else {
            base = dataService.users.filter {
                $0.username.localizedCaseInsensitiveContains(searchText)
            }
        }

        let favs = favoritesService.favorites
        return base.sorted { a, b in
            let aFav = favs.contains(a.username)
            let bFav = favs.contains(b.username)
            if aFav != bFav { return aFav }
            return a.username.localizedCaseInsensitiveCompare(b.username) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if dataService.isLoading {
                ProgressView("Loading users...")
            } else if let error = dataService.errorMessage {
                ErrorView(message: error) {
                    await MainActor.run {
                        dataService.loadUserList()
                    }
                }
            } else {
                List {
                    if !primaryUser.isEmpty, let user = dataService.users.first(where: { $0.username == primaryUser }) {
                        Section {
                            NavigationLink(value: user) {
                                HStack {
                                    Image(systemName: "person.fill")
                                        .foregroundStyle(.blue)
                                    Text(primaryUser)
                                        .font(.headline)
                                    Spacer()
                                    Text("My Profile")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Recent users
                    if searchText.isEmpty && !settings.recentUsers.isEmpty {
                        Section("Recent") {
                            ForEach(settings.recentUsers.prefix(5), id: \.self) { recentName in
                                if let user = dataService.users.first(where: { $0.username == recentName }) {
                                    NavigationLink(value: user) {
                                        HStack {
                                            Image(systemName: "clock")
                                                .foregroundStyle(.secondary)
                                                .font(.caption)
                                            Text(user.username)
                                                .font(.subheadline)
                                        }
                                    }
                                }
                            }
                        }
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
                .searchable(text: $searchText, prompt: "Search users")
                .overlay {
                    if filteredUsers.isEmpty && !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
        }
        .navigationTitle("Travelers (\(dataService.users.count))")
        .onAppear {
            if dataService.users.isEmpty {
                dataService.loadUserList()
            }
        }
        .refreshable {
            dataService.loadUserList()
        }
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
        HStack {
            if isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(user.username)
                    .font(.headline)
                HStack(spacing: 8) {
                    if user.hasRoads {
                        Label("Roads", systemImage: "car.fill")
                    }
                    if user.hasRail {
                        Label("Rail", systemImage: "tram.fill")
                    }
                    if user.hasFerry {
                        Label("Ferry", systemImage: "ferry.fill")
                    }
                    if user.hasScenic {
                        Label("Scenic", systemImage: "leaf.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(user.username)\(isFavorite ? ", favorited" : ""). \(categoryDescription)")
    }
}
