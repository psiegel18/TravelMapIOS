import SwiftUI
import Sentry
import UIKit

@main
struct TravelMappingApp: App {
    private static let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"

    /// Hidden UIButton wired into Sentry's User Feedback widget via `customButton`.
    /// Tapping this button (programmatically) triggers the Sentry feedback form
    /// directly — bypassing the floating widget UI.
    static let feedbackTrigger: UIButton = {
        let b = UIButton(type: .custom)
        b.setTitle("Report a Bug", for: .normal)
        b.isHidden = true
        return b
    }()

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
                    ])
                }
                config.onSubmitError = { error in
                    SentrySDK.capture(error: error)
                }

                config.configureWidget = { widget in
                    widget.autoInject = false
                }

                config.configureForm = { form in
                    form.formTitle = "Report a Bug"
                    form.messageLabel = "What happened?"
                    form.messagePlaceholder = "Describe the issue or what you expected to happen."
                    form.showName = true
                    form.showEmail = true
                    form.isNameRequired = false
                    form.isEmailRequired = false
                    form.submitButtonLabel = "Send Report"
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

        // Initial contexts — refreshed as state changes by the owning services.
        let defaults = UserDefaults.standard
        let primaryUser = defaults.string(forKey: "primaryUser") ?? ""
        let favorites = (defaults.array(forKey: "favoriteUsernames") as? [String]) ?? []
        let recents = (defaults.array(forKey: "recentUsers") as? [String]) ?? []
        SentrySDK.configureScope { scope in
            scope.setContext(value: [
                "hasPrimaryUser": !primaryUser.isEmpty,
                "favoritesCount": favorites.count,
                "recentUsersCount": recents.count,
            ], key: "profile")
            scope.setContext(value: [
                "useMiles": defaults.object(forKey: "useMiles") == nil || defaults.bool(forKey: "useMiles"),
                "sendToWatch": defaults.bool(forKey: "sendToWatch"),
                "accentColor": defaults.string(forKey: "accentColorName") ?? "default",
                "roadLineStyle": defaults.string(forKey: "roadLineStyle") ?? "default",
                "railLineStyle": defaults.string(forKey: "railLineStyle") ?? "default",
            ], key: "preferences")
            scope.setContext(value: [
                "isRecording": false,
            ], key: "trip_state")
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
        }
    }
}
