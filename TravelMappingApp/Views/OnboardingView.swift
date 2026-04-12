import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var settings = SyncedSettingsService.shared
    @AppStorage("watchUsername") private var watchUsername = ""
    @State private var page = 0
    @State private var usernameInput = ""
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var showGetStarted = false

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
                if isValidating {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    Text(page < 2 ? "Next" : "Get Started")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .buttonStyle(.plain)
            .disabled(isValidating)
            .padding(.horizontal)
            .padding(.bottom, 60)
        }
        .sheet(isPresented: $showGetStarted) {
            NavigationStack {
                GetStartedView()
            }
        }
    }

    private func advance() {
        if page < 2 {
            withAnimation { page += 1 }
        } else {
            let trimmed = usernameInput.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                finish()
            } else {
                Task { await validateAndFinish(trimmed) }
            }
        }
    }

    private func validateAndFinish(_ username: String) async {
        isValidating = true
        validationError = nil

        let exists = await validateUsername(username)
        isValidating = false

        if exists {
            finish()
        } else {
            validationError = "Username \"\(username)\" not found on Travel Mapping. Check your spelling or leave blank to skip."
        }
    }

    private func validateUsername(_ username: String) async -> Bool {
        let url = URL(string: "https://travelmapping.net/lib/getTravelerRoutes.php?dbname=TravelMapping")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "params={\"traveler\":\"\(username)\"}".data(using: .utf8)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = json["routes"] as? [Any] else {
            return false
        }
        return !routes.isEmpty
    }

    private func finish() {
        let trimmed = usernameInput.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            settings.primaryUser = trimmed
            watchUsername = trimmed
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
                .onChange(of: usernameInput) { validationError = nil }

            if let error = validationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            VStack(spacing: 8) {
                Text("New to Travel Mapping?")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Button {
                    showGetStarted = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Create an account")
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .font(.caption.bold())
                }
                .buttonStyle(.plain)
                Text("You can also browse without an account and set one up later in Settings.")
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
