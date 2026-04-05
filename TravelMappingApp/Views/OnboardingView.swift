import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var settings = SyncedSettingsService.shared
    @AppStorage("watchUsername") private var watchUsername = ""
    @State private var page = 0
    @State private var usernameInput = ""

    var body: some View {
        TabView(selection: $page) {
            welcomePage.tag(0)
            featuresPage.tag(1)
            usernamePage.tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .overlay(alignment: .bottom) {
            Button {
                Haptics.light()
                advance()
            } label: {
                Text(page < 2 ? "Next" : "Get Started")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal)
            .padding(.bottom, 60)
        }
    }

    private func advance() {
        if page < 2 {
            withAnimation { page += 1 }
        } else {
            finish()
        }
    }

    private func finish() {
        let trimmed = usernameInput.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            settings.primaryUser = trimmed
            watchUsername = trimmed
            // Auto-favorite your own profile
            FavoritesService.shared.addFavorite(trimmed)
        }
        isPresented = false
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 40)
            Image(systemName: "road.lanes")
                .font(.system(size: 80))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse)
            Text("Travel Mapping")
                .font(.largeTitle.bold())
            Text("Track the roads and rails you've traveled across the country")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            Spacer().frame(height: 100)
        }
        .padding(.horizontal, 40)
    }

    private var featuresPage: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 40)
            Text("What You Can Do")
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 16) {
                featureRow("map", "Browse maps", "See every road and rail segment you've traveled")
                featureRow("chart.bar", "View statistics", "Track progress with mileage stats and rankings")
                featureRow("location.fill", "Record road trips", "GPS tracking to auto-detect routes you drive")
                featureRow("square.and.arrow.up", "Share segments", "Export your travels to .list format for GitHub")
            }
            .padding(.horizontal, 20)
            Spacer()
        }
    }

    private var usernamePage: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 40)
            Image(systemName: "person.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            Text("Your Username")
                .font(.title.bold())
            Text("If you're an existing Travel Mapping user, enter your username for quick access.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            TextField("e.g. psiegel18", text: $usernameInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 40)

            VStack(spacing: 8) {
                Text("New to Travel Mapping?")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Link(destination: URL(string: "https://travelmapping.net/participate.php")!) {
                    HStack(spacing: 4) {
                        Text("Sign up at travelmapping.net")
                        Image(systemName: "arrow.up.forward")
                    }
                    .font(.caption)
                }
                Text("You can browse the app without a username and add one later in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .padding(.top, 8)

            Spacer()
        }
    }

    @ViewBuilder
    private func featureRow(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
