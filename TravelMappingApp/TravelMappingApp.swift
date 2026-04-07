import SwiftUI
import Sentry

@main
struct TravelMappingApp: App {
    init() {
        SentrySDK.start(configureOptions: { options in
            options.dsn = "https://4d5e26ddfb95aaaef4721256a35176e5@o4510452629700608.ingest.us.sentry.io/4511177068183552"

            #if DEBUG
            options.debug = true
            options.environment = "development"
            #else
            options.debug = false
            options.environment = "production"
            #endif

            // -- Release & Session Health --
            options.enableAutoSessionTracking = true
            options.sessionTrackingIntervalMillis = 30_000
            options.dist = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

            // -- Error & Performance Sampling --
            options.sampleRate = 1.0
            options.tracesSampleRate = 1.0
            options.enableAutoPerformanceTracing = true
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

            // -- HTTP Client Errors --
            options.enableCaptureFailedRequests = true

            // -- Session Replay (all unmasked — no private info) --
            #if DEBUG
            options.sessionReplay.sessionSampleRate = 1.0
            #else
            options.sessionReplay.sessionSampleRate = 0.5
            #endif
            options.sessionReplay.onErrorSampleRate = 1.0
            options.sessionReplay.maskAllText = false
            options.sessionReplay.maskAllImages = false
            options.sessionReplay.quality = .medium

            // -- User Feedback Widget --
            options.configureUserFeedback = { config in
                config.useShakeGesture = true
                config.showFormForScreenshots = true

                config.configureWidget = { widget in
                    widget.autoInject = false
                }

                config.configureForm = { form in
                    form.formTitle = "Report a Bug"
                    form.messagePlaceholder = "What happened? What did you expect?"
                    form.showName = true
                    form.showEmail = true
                    form.isNameRequired = false
                    form.isEmailRequired = false
                    form.submitButtonLabel = "Send Report"
                    form.useSentryUser = true
                }
            }

            // -- Custom tags & context --
            options.initialScope = { scope in
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
                scope.setTag(value: version, key: "app.version")
                scope.setTag(value: build, key: "app.build")
                scope.setTag(value: "ios", key: "app.platform")
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
