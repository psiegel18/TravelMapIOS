import SwiftUI

struct UserListView: View {
    @ObservedObject var dataService: DataService
    @State private var searchText = ""
    @AppStorage("favoriteUsers") private var favoriteUsersData: Data = Data()

    private var favoriteUsernames: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: favoriteUsersData)) ?? []
    }

    private func setFavorites(_ favorites: Set<String>) {
        favoriteUsersData = (try? JSONEncoder().encode(favorites)) ?? Data()
    }

    private func toggleFavorite(_ username: String) {
        var favs = favoriteUsernames
        if favs.contains(username) {
            favs.remove(username)
        } else {
            favs.insert(username)
        }
        setFavorites(favs)
    }

    var filteredUsers: [DataService.UserSummary] {
        let base: [DataService.UserSummary]
        if searchText.isEmpty {
            base = dataService.users
        } else {
            base = dataService.users.filter {
                $0.username.localizedCaseInsensitiveContains(searchText)
            }
        }

        let favs = favoriteUsernames
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
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Error loading data")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                List(filteredUsers) { user in
                    NavigationLink(value: user) {
                        UserRowView(
                            user: user,
                            isFavorite: favoriteUsernames.contains(user.username)
                        )
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            toggleFavorite(user.username)
                        } label: {
                            if favoriteUsernames.contains(user.username) {
                                Label("Unfavorite", systemImage: "star.slash")
                            } else {
                                Label("Favorite", systemImage: "star.fill")
                            }
                        }
                        .tint(.yellow)
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
    }
}

struct UserRowView: View {
    let user: DataService.UserSummary
    let isFavorite: Bool

    var body: some View {
        HStack {
            if isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
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
    }
}
