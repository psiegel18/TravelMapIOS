import SwiftUI
import Sentry
import StoreKit
import UIKit

extension Notification.Name {
    /// Posted (on the main actor) whenever the launch-scoped StoreKit listener finishes
    /// a verified transaction — lets TipJarView update a "Purchase pending..." message
    /// when a deferred purchase (e.g. Ask to Buy) completes later.
    static let tipTransactionFinished = Notification.Name("tipTransactionFinished")
}

@main
struct TravelMappingApp: App {
    private static let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"

    /// App-lifetime StoreKit listener. Unfinished/pending transactions (Ask to Buy,
    /// interrupted purchases) arrive on `Transaction.updates` at any point after launch,
    /// so this must not live in a view's `.task` — it would only process while that
    /// screen is visible. Started once from `init()`.
    private static let transactionListener: Task<Void, Never> = Task.detached {
        for await result in Transaction.updates {
            switch result {
            case .verified(let transaction):
                await transaction.finish()
                SentrySDK.logger.info("StoreKit transaction finished", attributes: [
                    "productId": transaction.productID,
                ])
                await MainActor.run {
                    NotificationCenter.default.post(name: .tipTransactionFinished, object: nil)
                }
            case .unverified(_, let error):
                SentrySDK.capture(error: error)
            }
        }
    }

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
            // Screenshot masking is configured separately from Session Replay. Views with private
            // content (Route Planner, keys, GitHub account) opt in via .sentryReplayMask(), which
            // screenshots honor too, so clear the blanket defaults that black-box everything.
            options.screenshot.maskAllText = false
            options.screenshot.maskAllImages = false
            options.screenshot.maskedViewClasses = []

            // -- HTTP Client Errors --
            options.enableCaptureFailedRequests = true
            // Trace headers only go to our own data sources — never to AI providers or
            // other third parties the user's requests reach.
            options.tracePropagationTargets = ["travelmapping.net", "tmrail.teresco.org"]


            // -- Session Replay (unmasked except views marked .sentryReplayMask()) --
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
            // Private views are masked individually, so override the iOS 26+ Liquid Glass safeguard that auto-disables
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
                        "hasAttachment": !((data["attachments"] as? [Any]) ?? []).isEmpty,
                        "feedback_type": "shake",
                    ])
                }
                config.onSubmitError = { error in
                    SentrySDK.capture(error: error)
                }

                config.configureWidget = { widget in
                    widget.autoInject = false
                }

                config.configureForm = { form in
                    form.messageLabel = "Message"
                    // No name/email: feedback stays anonymous (App Store label has no Contact Info).
                    form.showName = false
                    form.showEmail = false
                    form.isNameRequired = false
                    form.isEmailRequired = false
                    form.useSentryUser = false
                    form.showBranding = false
                    // Sentry's form now only serves shake / screenshot detection; the
                    // Settings buttons use the native FeedbackSheet (SettingsView.swift).
                    form.formTitle = "Send Feedback"
                    form.messagePlaceholder = "Tell us what's on your mind."
                    form.submitButtonLabel = "Send"
                }
            }

            // -- Structured logs (Sentry 9.x) --
            options.enableLogs = true
            options.beforeSendLog = { log in
                // Drop trace/debug in App Store to save quota; keep them in dev/testflight
                if buildChannel == "appstore", log.level == .trace || log.level == .debug {
                    return nil
                }
                return SentryPrivacy.scrub(log)
            }

            // -- Keep the user's username out of diagnostics (see SentryPrivacy) --
            options.beforeBreadcrumb = { crumb in SentryPrivacy.scrub(crumb) }
            options.beforeSendSpan = { span in SentryPrivacy.scrub(span) }

            // -- Filter out expected noise (cancellations, denied permissions) --
            options.beforeSend = { event in
                // AI requests use the user's own key and account; their errors are theirs
                if let url = event.request?.url, AIService.isAIProviderURL(url) { return nil }
                if let exceptions = event.exceptions {
                    for exception in exceptions {
                        // NSURLError noise we don't want pinged for: -999 cancelled (user
                        // navigated away mid-request), -1001 timeout, -1005 connection
                        // lost. All transient network conditions, not app bugs.
                        if exception.type == "NSURLErrorDomain",
                           let value = exception.value,
                           ["Code=-999", "Code=-1001", "Code=-1005"].contains(where: value.contains) {
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
                return SentryPrivacy.scrub(event)
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

        // Kick off the app-lifetime StoreKit transaction listener.
        _ = Self.transactionListener

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

/// Keeps the device owner's TravelMapping username (and GitHub login) out of everything sent to Sentry, so
/// diagnostics aren't linked to an identity (App Store label: "Data Not Linked to You").
/// The username still reaches Sentry indirectly — in log text, breadcrumb and span URLs
/// (`?u=`, `traveler`) and extras — so it's replaced wherever it appears as a whole token.
/// Other travelers' names (favorites, comparisons) are public and left alone.
enum SentryPrivacy {
    static let placeholder = "[user]"

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var names: [String] = []
        var regex: NSRegularExpression?
    }
    private static let cache = Cache()

    /// The TravelMapping username and, when signed in, the GitHub login (it's in fork URLs).
    private static func regex() -> NSRegularExpression? {
        let names = ["primaryUser", "githubLogin"]
            .compactMap { UserDefaults.standard.string(forKey: $0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        cache.lock.lock(); defer { cache.lock.unlock() }
        if cache.names != names {
            cache.names = names
            let tokens = names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            cache.regex = try? NSRegularExpression(
                pattern: "(?<![A-Za-z0-9_-])(?:\(tokens))(?![A-Za-z0-9_-])",
                options: .caseInsensitive)
        }
        return cache.regex
    }

    static func scrub(_ text: String) -> String {
        guard let regex = regex() else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: placeholder))
    }

    static func scrubValue(_ value: Any) -> Any {
        switch value {
        case let text as String: return scrub(text)
        case let dict as [String: Any]: return dict.mapValues(scrubValue)
        case let array as [Any]: return array.map(scrubValue)
        default: return value
        }
    }

    static func scrub(_ event: Event) -> Event {
        if let message = event.message {
            let scrubbed = SentryMessage(formatted: scrub(message.formatted))
            scrubbed.message = message.message.map(scrub)
            scrubbed.params = message.params?.map(scrub)
            event.message = scrubbed
        }
        event.transaction = event.transaction.map(scrub)
        event.tags = event.tags?.mapValues(scrub)
        event.extra = event.extra?.mapValues(scrubValue)
        event.context = event.context?.mapValues { (scrubValue($0) as? [String: Any]) ?? $0 }
        event.exceptions?.forEach {
            $0.value = $0.value.map(scrub)
            // NSError captures put error.description and userInfo here — a URLError's
            // failing URL names the user's .list file or GitHub fork
            $0.mechanism?.desc = $0.mechanism?.desc.map(scrub)
            $0.mechanism?.data = $0.mechanism?.data?.mapValues(scrubValue)
        }
        if let request = event.request {
            request.url = request.url.map(scrub)
            request.queryString = request.queryString.map(scrub)
        }
        event.breadcrumbs?.forEach { _ = scrub($0) }
        return event
    }

    static func scrub(_ crumb: Breadcrumb) -> Breadcrumb {
        crumb.message = crumb.message.map(scrub)
        crumb.data = crumb.data?.mapValues(scrubValue)
        return crumb
    }

    static func scrub(_ span: Span) -> Span {
        span.spanDescription = span.spanDescription.map(scrub)
        for (key, value) in span.data {
            if let text = value as? String { span.setData(value: scrub(text), key: key) }
        }
        return span
    }

    static func scrub(_ log: SentryLog) -> SentryLog {
        log.body = scrub(log.body)
        for (key, attribute) in log.attributes {
            if let text = attribute.value as? String {
                log.attributes[key] = SentryLog.Attribute(string: scrub(text))
            } else if let texts = attribute.value as? [String] {
                log.attributes[key] = SentryLog.Attribute(stringArray: texts.map(scrub))
            }
        }
        return log
    }
}
