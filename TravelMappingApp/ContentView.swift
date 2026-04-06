import SwiftUI
import CoreSpotlight

struct ContentView: View {
    @StateObject private var dataService = DataService()
    @ObservedObject private var settings = SyncedSettingsService.shared
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var showOnboarding = false
    @State private var travelersPath = NavigationPath()
    @State private var selectedTab = 0

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
            }
            .onOpenURL { url in
                handleURL(url)
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                    handleSpotlightID(id)
                }
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
}
