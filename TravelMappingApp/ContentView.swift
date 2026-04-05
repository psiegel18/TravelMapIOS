import SwiftUI

struct ContentView: View {
    @StateObject private var dataService = DataService()

    var body: some View {
        NavigationStack {
            UserListView(dataService: dataService)
                .navigationDestination(for: DataService.UserSummary.self) { user in
                    UserDetailView(
                        username: user.username,
                        dataService: dataService
                    )
                }
        }
    }
}
