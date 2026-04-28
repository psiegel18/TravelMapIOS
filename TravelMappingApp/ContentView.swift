import SwiftUI
import CoreSpotlight
import WidgetKit
import Sentry

struct ContentView: View {
    @StateObject private var dataService = DataService()
    @ObservedObject private var settings = SyncedSettingsService.shared
    @ObservedObject private var favorites = FavoritesService.shared
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var showOnboarding = false
    @State private var travelersPath = NavigationPath()
    @State private var selectedTab = 0

    private static let tabScreenNames = ["Travelers", "RoadTrips", "RoutePlanner", "Leaderboard", "Settings"]

    var body: some View {
        mainContent
            .sheet(isPresented: $showOnboarding) {
                OnboardingView(isPresented: $showOnboarding)
                    .interactiveDismissDisabled()
            }
            .onAppear {
                if !hasOnboarded {
                    showOnboarding = true
                    hasOnboarded = true
                }
                Self.updateScreenTag(for: selectedTab)
            }
            .onChange(of: selectedTab) {
                Self.updateScreenTag(for: selectedTab)
            }
            .onOpenURL { url in
                handleURL(url)
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                    handleSpotlightID(id)
                }
            }
            .task {
                CatalogService.shared.loadIfNeeded()
                await CacheService.shared.purgeExpired()
                await prefetchUserData()
            }
    }

    private func handleURL(_ url: URL) {
        // travelmapping://user/psiegel18
        guard url.scheme == "travelmapping" else { return }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        if url.host == "user", let username = pathComponents.first {
            navigateToUser(username)
        }
    }

    private func handleSpotlightID(_ id: String) {
        // user.psiegel18
        guard id.hasPrefix("user.") else { return }
        let username = String(id.dropFirst(5))
        navigateToUser(username)
    }

    private func navigateToUser(_ username: String) {
        selectedTab = 0
        // Find the user summary
        if let user = dataService.users.first(where: { $0.username == username }) {
            travelersPath = NavigationPath()
            travelersPath.append(user)
        } else {
            // Create a minimal summary if user list not loaded yet
            let user = DataService.UserSummary(
                id: username,
                username: username,
                hasRoads: true,
                hasRail: false,
                hasFerry: false,
                hasScenic: false
            )
            travelersPath = NavigationPath()
            travelersPath.append(user)
        }
    }

    /// Set the `current_screen` Sentry tag so future events surface which top-level
    /// tab the user was on. Detail navigation can layer on top with its own tags.
    private static func updateScreenTag(for tab: Int) {
        let name = tabScreenNames.indices.contains(tab) ? tabScreenNames[tab] : "Unknown"
        SentrySDK.configureScope { scope in
            scope.setTag(value: name, key: "current_screen")
        }
    }

    private var mainContent: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $travelersPath) {
                UserListView(dataService: dataService)
                    .navigationDestination(for: DataService.UserSummary.self) { user in
                        UserDetailView(
                            username: user.username,
                            dataService: dataService
                        )
                    }
            }
            .tabItem {
                Label("Travelers", systemImage: "person.2")
            }
            .tag(0)

            NavigationStack {
                RoadTripListView()
            }
            .tabItem {
                Label("Road Trips", systemImage: "car.fill")
            }
            .tag(1)

            NavigationStack {
                RoutePlannerView()
            }
            .tabItem {
                Label("Route Planner", systemImage: "arrow.triangle.turn.up.right.diamond")
            }
            .tag(2)

            NavigationStack {
                LeaderboardView()
            }
            .tabItem {
                Label("Leaderboard", systemImage: "trophy")
            }
            .tag(3)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(4)
        }
        .tint(ThemeService.color(named: settings.accentColorName))
    }

    private func prefetchUserData() async {
        // 1. Prefetch primary user's profile and stats
        let primaryUser = settings.primaryUser.trimmingCharacters(in: .whitespaces)
        if !primaryUser.isEmpty {
            let profile = await dataService.loadUserProfile(username: primaryUser)
            let snapshot = try? await TMStatsService.shared.loadRegionStats(forceRefresh: false)

            // Write widget data to app group so the widget can display without its own network calls
            if let snapshot {
                updateWidgetCache(username: primaryUser, profile: profile, snapshot: snapshot)
            }

            // Prefetch full stats so the Stats tab loads instantly when opened
            if let profile {
                await StatsCache.shared.prefetch(username: primaryUser, profile: profile)
            }
        }

        // 2. Prefetch up to 3 favorites (excluding primary user) in background
        let favoritesToPrefetch = Array(
            favorites.favorites
                .filter { $0 != primaryUser }
                .prefix(3)
        )
        await withTaskGroup(of: Void.self) { group in
            for username in favoritesToPrefetch {
                group.addTask {
                    _ = await dataService.loadUserProfile(username: username)
                }
            }
        }
    }

    private func updateWidgetCache(username: String, profile: UserProfile?, snapshot: TMStatsService.LeaderboardSnapshot) {
        let userStats = snapshot.users.first { $0.username.lowercased() == username.lowercased() }
        let position = snapshot.position(of: username)

        // Find top region
        var topRegion = ""
        var topMiles: Double = 0
        for (region, miles) in userStats?.byRegion ?? [:] {
            if miles > topMiles {
                topMiles = miles
                topRegion = region
            }
        }

        let entry: [String: Any] = [
            "date": Date().timeIntervalSince1970,
            "username": username,
            "routes": profile?.allRoutes.count ?? 0,
            "totalMiles": userStats?.totalMiles ?? 0,
            "rank": position?.rank ?? 0,
            "userCount": snapshot.userCount,
            "percentile": position?.percentile ?? 0,
            "topRegion": topRegion,
            "topRegionMiles": topMiles,
            "regionCount": userStats?.byRegion.count ?? 0
        ]

        // Encode as the same format the widget expects
        struct WidgetEntry: Codable {
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
            let useMiles: Bool
        }

        let widgetEntry = WidgetEntry(
            date: Date(),
            username: username,
            routes: entry["routes"] as? Int ?? 0,
            totalMiles: entry["totalMiles"] as? Double ?? 0,
            rank: entry["rank"] as? Int ?? 0,
            userCount: entry["userCount"] as? Int ?? 0,
            percentile: entry["percentile"] as? Double ?? 0,
            topRegion: entry["topRegion"] as? String ?? "",
            topRegionMiles: entry["topRegionMiles"] as? Double ?? 0,
            regionCount: entry["regionCount"] as? Int ?? 0,
            useMiles: settings.useMiles
        )

        if let encoded = try? JSONEncoder().encode(widgetEntry) {
            let defaults = UserDefaults(suiteName: "group.com.psiegel18.TravelMapping")
            defaults?.set(encoded, forKey: "cachedWidgetEntry")
            defaults?.set(settings.useMiles, forKey: "widgetUseMiles")
        }

        WidgetCenter.shared.reloadAllTimelines()
    }
}
