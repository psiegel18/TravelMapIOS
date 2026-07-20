import SwiftUI
import Sentry

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var settings = SyncedSettingsService.shared
    @AppStorage("watchUsername") private var watchUsername = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var usernameInput = ""
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var showGetStarted = false

    // Live (debounced) validation drives the inline check + "Found — N routes" line.
    // Mirrors the SettingsView pattern: a nil result (network failure) leaves the
    // previous state unchanged rather than clearing a good checkmark.
    @State private var liveValidationResult: Bool?
    @State private var liveRouteCount: Int?
    @State private var isLiveValidating = false
    @State private var lastLiveValidated = ""

    var body: some View {
        TabView(selection: $page) {
            welcomePage.tag(0)
            featuresPage.tag(1)
            usernamePage.tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .overlay(alignment: .bottom) {
            bottomControls
        }
        .sheet(isPresented: $showGetStarted) {
            NavigationStack {
                GetStartedView()
            }
        }
    }

    private func advance() {
        if page < 2 {
            if reduceMotion {
                page += 1
            } else {
                withAnimation { page += 1 }
            }
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

        if exists == false {
            // Only block on a definitive "not found" — nil means the request failed
            // (offline, server down), and valid users shouldn't be locked out for that.
            validationError = "Username \"\(username)\" not found on Travel Mapping. Check your spelling or leave blank to skip."
        } else {
            finish()
        }
    }

    /// Returns true if found, false if confirmed not found, nil if the request failed
    /// (mirrors SettingsView.validateUsername — network failure is "unknown", not "invalid").
    /// Also stashes the route count for the inline "Found — N routes" line.
    private func validateUsername(_ username: String) async -> Bool? {
        let url = URL(string: "https://travelmapping.net/lib/getTravelerRoutes.php?dbname=TravelMapping")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        let encoded = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username
        request.httpBody = "params={\"traveler\":\"\(encoded)\"}".data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let routes = json["routes"] as? [Any] else {
                return nil  // Unexpected payload — treat as unknown, don't block
            }
            liveRouteCount = routes.count
            return !routes.isEmpty
        } catch {
            SentrySDK.capture(error: error)
            return nil
        }
    }

    private func finish() {
        let trimmed = usernameInput.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            settings.primaryUser = trimmed
            watchUsername = trimmed
            FavoritesService.shared.addFavorite(trimmed)
            // Mirror the launch-time scope setup in TravelMappingApp.init so events from
            // this first session already carry the user and tm.username tag.
            SentrySDK.configureScope { scope in
                scope.setUser(User(userId: trimmed))
                scope.setTag(value: trimmed, key: "tm.username")
                scope.setTag(value: "true", key: "primary_user_set")
            }
        }
        isPresented = false
        SentrySDK.logger.info("Onboarding completed", attributes: [
            "withUsername": !trimmed.isEmpty,
        ])
    }

    // MARK: - Bottom controls (dots + buttons)

    private var bottomControls: some View {
        VStack(spacing: 12) {
            pageDots

            Button {
                Haptics.light()
                advance()
            } label: {
                Group {
                    if isValidating {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(page < 2 ? "Continue" : "Enter my dashboard")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(TMDesign.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isValidating)

            if page == 2 {
                Button {
                    Haptics.light()
                    showGetStarted = true
                } label: {
                    Text("New here? Create an account")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TMDesign.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.light()
                    // Skip = the existing skip behavior: finish with no username set.
                    usernameInput = ""
                    finish()
                } label: {
                    Text("or browse without one")
                        .font(.system(size: 13))
                        .foregroundStyle(TMDesign.tertiaryText)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index == page ? TMDesign.accent : Color(tmLight: 0xC9C9D0, dark: 0x3A3A3E))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page + 1) of 3")
    }

    // MARK: - Page 1 · Welcome

    private var welcomePage: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(tmLight: 0xEAF1FE, dark: 0x12294D),
                    Color(tmLight: 0xF2F2F7, dark: 0x000000),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(TMDesign.accent)
                        .frame(width: 96, height: 96)
                        .shadow(color: Color(tmHex: 0x2F6BF0, opacity: 0.35), radius: 15, y: 8)
                    Image(systemName: "road.lanes")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

                Text("Travel Mapping")
                    .font(.system(size: 32, weight: .heavy))

                Text("Track every road and rail you've traveled — and see how far you've gone.")
                    .font(.system(size: 17))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(TMDesign.secondaryText)

                Spacer()
                // Room for the pinned dots + Continue button.
                Spacer().frame(height: 120)
            }
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Page 2 · Features

    private var featuresPage: some View {
        ZStack {
            TMDesign.secondarySurface.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Spacer().frame(height: 16)
                Text("What you can do")
                    .font(.system(size: 30, weight: .heavy))
                    .padding(.bottom, 4)

                featureCard(
                    icon: "map.fill", bg: TMDesign.blueChipBG, fg: TMDesign.blueChipFG,
                    title: "Browse your map",
                    detail: "Every road & rail segment you've traveled."
                )
                featureCard(
                    icon: "chart.bar.fill", bg: TMDesign.greenChipBG, fg: TMDesign.greenChipFG,
                    title: "Track your stats",
                    detail: "Mileage, completion, and your community rank."
                )
                featureCard(
                    icon: "location.north.line.fill", bg: TMDesign.amberChipBG, fg: TMDesign.amberChipFG,
                    title: "Record road trips",
                    detail: "GPS auto-detects the routes you drive."
                )
                featureCard(
                    icon: "square.and.arrow.up", bg: TMDesign.purpleChipBG, fg: TMDesign.purpleChipFG,
                    title: "Share & export",
                    detail: "Post stat cards or export .list for GitHub."
                )

                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }

    private func featureCard(icon: String, bg: Color, fg: Color, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(fg)
                .frame(width: 48, height: 48)
                .background(bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(TMDesign.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Page 3 · Connect your profile

    private var usernamePage: some View {
        ZStack {
            TMDesign.secondarySurface.ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer().frame(height: 24)

                Text("Connect your profile")
                    .font(.system(size: 28, weight: .heavy))

                Text("Enter your Travel Mapping username to unlock your dashboard, widgets & Watch.")
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(TMDesign.secondaryText)

                usernameField

                if liveValidationResult == true, usernameInput.trimmingCharacters(in: .whitespaces) == lastLiveValidated {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 14, weight: .semibold))
                        if let count = liveRouteCount, count > 0 {
                            Text("Found — \(count.formatted()) route\(count == 1 ? "" : "s")")
                                .monospacedDigit()
                        } else {
                            Text("Username found")
                        }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TMDesign.clinched)
                    .accessibilityElement(children: .combine)
                }

                if let error = validationError {
                    Text(error)
                        .font(.system(size: 15))
                        .foregroundStyle(TMDesign.rail)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding(.horizontal, 32)
        }
    }

    private var usernameField: some View {
        HStack(spacing: 10) {
            Image(systemName: "at")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(TMDesign.accent)
                .accessibilityHidden(true)
            TextField("e.g. psiegel18", text: $usernameInput)
                .font(.system(size: 17, weight: .semibold))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel("Travel Mapping username")
            if isLiveValidating {
                ProgressView()
                    .controlSize(.small)
            } else if liveValidationResult == true,
                      usernameInput.trimmingCharacters(in: .whitespaces) == lastLiveValidated {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(TMDesign.clinched)
                    .accessibilityLabel("Username validated")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TMDesign.accent, lineWidth: 2)
        )
        .onChange(of: usernameInput) { validationError = nil }
        .task(id: usernameInput) {
            let trimmed = usernameInput.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                liveValidationResult = nil
                liveRouteCount = nil
                lastLiveValidated = ""
                return
            }
            guard trimmed != lastLiveValidated else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            isLiveValidating = true
            let result = await validateUsername(trimmed)
            if let result {
                // Only surface definitive results; a nil (network failure) leaves
                // the previous state so a good check isn't wiped by a blip.
                liveValidationResult = result
                lastLiveValidated = trimmed
            }
            isLiveValidating = false
        }
    }
}
