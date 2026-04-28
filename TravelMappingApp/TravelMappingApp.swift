import SwiftUI
import Sentry
import UIKit

@main
struct TravelMappingApp: App {
    private static let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"

    /// UIButton wired into Sentry's User Feedback widget via `customButton`.
    /// Tapping it (programmatically) triggers the Sentry feedback form. The button
    /// must be embedded in the actual view hierarchy for Sentry to find a presenting
    /// view controller — see `FeedbackTriggerHost` below.
    static let feedbackTrigger: UIButton = {
        let b = UIButton(type: .custom)
        b.setTitle("Send Feedback", for: .normal)
        b.alpha = 0
        b.isUserInteractionEnabled = false
        return b
    }()

    // Sentry's user-feedback `customButton` and form config are set once at SDK init,
    // so these statics are mutated right before each invocation to give the same form
    // a different title/placeholder/submit-label depending on whether the user tapped
    // "Share Feedback" or "Report a Bug". The `configureForm` closure reads them at
    // present time.
    static var pendingFeedbackTitle: String = "Send Feedback"
    static var pendingFeedbackPlaceholder: String = "Tell us what's on your mind."
    static var pendingFeedbackSubmitLabel: String = "Send"
    static var pendingFeedbackType: String = "general"

    /// Show the Sentry feedback form. For `bug_report` the call also captures a
    /// warning-level message so the report appears in the Issues feed (not just the
    /// User Feedback feed); the submitted form is then associated with that event.
    @MainActor
    static func presentFeedbackForm(
        type: String,
        title: String,
        placeholder: String,
        submitLabel: String,
        captureIssue: Bool
    ) {
        pendingFeedbackType = type
        pendingFeedbackTitle = title
        pendingFeedbackPlaceholder = placeholder
        pendingFeedbackSubmitLabel = submitLabel

        SentrySDK.configureScope { scope in
            scope.setTag(value: type, key: "feedback_type")
        }

        if captureIssue {
            SentrySDK.capture(message: "User-reported bug") { scope in
                scope.setLevel(.warning)
                scope.setTag(value: type, key: "feedback_type")
            }
        }

        feedbackTrigger.sendActions(for: .touchUpInside)
    }

    init() {
        let buildChannel: String
        #if DEBUG
        buildChannel = "development"
        #else
        buildChannel = Self.isTestFlight ? "testflight" : "appstore"
        #endif

        SentrySDK.start(configureOptions: { options in
            options.dsn = "https://4d5e26ddfb95aaaef4721256a35176e5@o4510452629700608.ingest.us.sentry.io/4511177068183552"

            options.environment = buildChannel
            #if DEBUG
            options.debug = true
            #else
            options.debug = false
            #endif

            // -- Release & Session Health --
            options.enableAutoSessionTracking = true
            options.sessionTrackingIntervalMillis = 30_000
            options.dist = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

            // -- Error & Performance Sampling --
            options.sampleRate = 1.0
            options.tracesSampleRate = buildChannel == "appstore" ? 0.2 : 1.0
            options.enableAutoPerformanceTracing = true

            // -- Continuous Profiling (Sentry 9.x) --
            options.configureProfiling = { profiling in
                profiling.sessionSampleRate = buildChannel == "appstore" ? 0.2 : 1.0
                profiling.lifecycle = .trace
                profiling.profileAppStarts = true
            }
            options.enableUserInteractionTracing = true
            options.enableNetworkTracking = true
            options.enableFileIOTracing = true

            // -- Crash Reporting & App Hangs --
            options.enableCrashHandler = true
            options.attachStacktrace = true
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 2.0
            options.enableWatchdogTerminationTracking = true

            // -- Breadcrumbs --
            options.enableAutoBreadcrumbTracking = true
            options.enableNetworkBreadcrumbs = true
            options.maxBreadcrumbs = 100

            // -- Screenshots & View Hierarchy on Errors --
            options.attachScreenshot = true
            options.attachViewHierarchy = true
            // Screenshot masking is configured separately from Session Replay. App has no PII,
            // so clear the defaults so error-attached screenshots aren't black-boxed.
            options.screenshot.maskAllText = false
            options.screenshot.maskAllImages = false
            options.screenshot.maskedViewClasses = []

            // -- HTTP Client Errors --
            options.enableCaptureFailedRequests = true

            // -- Session Replay (all unmasked — no private info) --
            // TestFlight gets full coverage for beta debugging; App Store is sampled to conserve quota.
            switch buildChannel {
            case "development": options.sessionReplay.sessionSampleRate = 1.0
            case "testflight":  options.sessionReplay.sessionSampleRate = 1.0
            default:            options.sessionReplay.sessionSampleRate = 0.1
            }
            options.sessionReplay.onErrorSampleRate = 1.0
            options.sessionReplay.maskAllText = false
            options.sessionReplay.maskAllImages = false
            options.sessionReplay.maskedViewClasses = []
            options.sessionReplay.quality = .medium
            // App has no PII, so override the iOS 26+ Liquid Glass safeguard that auto-disables
            // Session Replay on recent iOS/Xcode combos. Without this, most beta testers (iOS 26+)
            // generate zero replays.
            options.experimental.enableSessionReplayInUnreliableEnvironment = true

            // -- User Feedback Widget --
            options.configureUserFeedback = { config in
                config.useShakeGesture = true
                config.showFormForScreenshots = true
                config.customButton = TravelMappingApp.feedbackTrigger
                config.onSubmitSuccess = { data in
                    SentrySDK.logger.info("User feedback submitted", attributes: [
                        "hasName": !((data["name"] as? String) ?? "").isEmpty,
                        "hasEmail": !((data["email"] as? String) ?? "").isEmpty,
                        "hasAttachment": !((data["attachments"] as? [Any]) ?? []).isEmpty,
                        "feedback_type": TravelMappingApp.pendingFeedbackType,
                    ])
                }
                config.onSubmitError = { error in
                    SentrySDK.capture(error: error)
                }

                config.configureWidget = { widget in
                    widget.autoInject = false
                }

                config.configureForm = { form in
                    form.formTitle = TravelMappingApp.pendingFeedbackTitle
                    form.messageLabel = "Message"
                    form.messagePlaceholder = TravelMappingApp.pendingFeedbackPlaceholder
                    form.showName = true
                    form.showEmail = true
                    form.isNameRequired = false
                    form.isEmailRequired = false
                    form.submitButtonLabel = TravelMappingApp.pendingFeedbackSubmitLabel
                    form.useSentryUser = true
                    form.showBranding = false
                }
            }

            // -- Structured logs (Sentry 9.x) --
            options.enableLogs = true
            options.beforeSendLog = { log in
                // Drop trace/debug in App Store to save quota; keep them in dev/testflight
                if buildChannel == "appstore", log.level == .trace || log.level == .debug {
                    return nil
                }
                return log
            }

            // -- Filter out expected noise (cancellations, denied permissions) --
            options.beforeSend = { event in
                if let exceptions = event.exceptions {
                    for exception in exceptions {
                        // URLSessionTask cancelled — normal when user navigates away mid-request
                        if exception.type == "NSURLErrorDomain",
                           exception.value?.contains("Code=-999") == true {
                            return nil
                        }
                        // Core Location: user denied permission (1), transient location unknown (0),
                        // or region-monitoring denied (4). All user-driven or transient, not bugs.
                        if exception.type == "kCLErrorDomain",
                           let value = exception.value,
                           ["Code: 0", "Code: 1", "Code: 4"].contains(where: value.contains) {
                            return nil
                        }
                    }
                }
                return event
            }

            // -- Custom tags & context --
            options.initialScope = { scope in
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
                scope.setTag(value: version, key: "app.version")
                scope.setTag(value: build, key: "app.build")
                scope.setTag(value: "ios", key: "app.platform")
                scope.setTag(value: buildChannel, key: "app.channel")
                scope.setTag(value: UIDevice.current.systemVersion, key: "os.version")
                scope.setTag(value: UIDevice.current.model, key: "device.model")
                let useMiles = UserDefaults.standard.object(forKey: "useMiles") == nil || UserDefaults.standard.bool(forKey: "useMiles")
                scope.setTag(value: useMiles ? "miles" : "km", key: "tm.units")
                let primaryUserSet = !((UserDefaults.standard.string(forKey: "primaryUser") ?? "").isEmpty)
                scope.setTag(value: primaryUserSet ? "true" : "false", key: "primary_user_set")
                scope.setTag(value: "false", key: "trip_active")
                scope.setContext(value: ["version": version, "build": build, "data_source": "travelmapping.net"], key: "app")
                return scope
            }
        })

        if let username = UserDefaults.standard.string(forKey: "primaryUser"), !username.isEmpty {
            SentrySDK.configureScope { scope in
                scope.setUser(User(userId: username))
                scope.setTag(value: username, key: "tm.username")
            }
        }

        // Initial contexts — read from the source-of-truth services so the values match
        // whatever those services will write on subsequent updates (no drift).
        SyncedSettingsService.shared.syncPreferencesContext()
        SentrySDK.configureScope { scope in
            scope.setContext(value: ["isRecording": false], key: "trip_state")
        }

        SentrySDK.logger.info("App launched", attributes: [
            "channel": buildChannel,
            "hasPrimaryUser": !(UserDefaults.standard.string(forKey: "primaryUser") ?? "").isEmpty,
            "favoritesCount": (UserDefaults.standard.array(forKey: "favoriteUsernames") as? [String])?.count ?? 0,
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(FeedbackTriggerHost().frame(width: 0, height: 0))
        }
    }
}

extension View {
    /// Set Sentry's `current_screen` tag whenever this view appears. ContentView already
    /// sets this on tab change for the 5 main tabs; use this on detail views pushed onto
    /// a navigation stack so future Sentry events show which sub-screen the user was on.
    func sentryScreen(_ name: String) -> some View {
        self.onAppear {
            SentrySDK.configureScope { scope in
                scope.setTag(value: name, key: "current_screen")
            }
        }
    }
}

/// Embeds the Sentry feedback UIButton into the SwiftUI hierarchy so it has a window/VC
/// chain. Without this, sendActions(for:) on an orphan UIButton silently fails because
/// Sentry can't find a presenting view controller.
private struct FeedbackTriggerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.isUserInteractionEnabled = false
        let button = TravelMappingApp.feedbackTrigger
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.widthAnchor.constraint(equalToConstant: 1),
            button.heightAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
