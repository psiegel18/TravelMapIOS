import Sentry
import Foundation
import WatchConnectivity

/// Sends trip recording state and route directions to the paired Apple Watch.
class WatchSyncService: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSyncService()

    /// Serializes access to the pending payload buffers. WCSession delegate callbacks
    /// arrive on a background thread while sends come from the main actor, so all
    /// reads/writes of `pendingDirections` / `pendingTripContext` go through this queue.
    private let stateQueue = DispatchQueue(label: "com.psiegel18.TravelMapping.WatchSyncService")

    /// Last payload dropped because the session hadn't finished activating yet.
    /// Flushed in `activationDidCompleteWith` so the first send after launch isn't
    /// silently lost (the UI haptic has already claimed success by then).
    private var pendingDirections: [String: Any]?
    private var pendingTripContext: [String: Any]?

    /// The Settings toggle is `@AppStorage("sendToWatch") = true`, which never persists
    /// until the user actually flips it — so an absent key means "on", not "off".
    private var sendToWatchEnabled: Bool {
        UserDefaults.standard.object(forKey: "sendToWatch") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "sendToWatch")
    }

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - Username

    /// Push the TM username to the Watch. UserDefaults doesn't cross devices, so the
    /// watch app/complication would otherwise never learn the user's username.
    /// Not gated on the "sendToWatch" toggle — that governs trip updates, not identity.
    func syncUsername(_ username: String) {
        guard !username.isEmpty,
              WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(["type": "username", "username": username])
    }

    // MARK: - Trip Updates

    /// Send current trip recording state to Watch via applicationContext.
    /// `startDate` lets the watch tick its timer locally between (coalesced) context
    /// pushes; when the caller doesn't provide one it's derived from `elapsedTime`
    /// while recording, and omitted while paused so the watch falls back to the
    /// static `elapsedTime`.
    func sendTripUpdate(
        tripName: String,
        elapsedTime: TimeInterval,
        speed: Double,
        distance: Double,
        matchedCount: Int,
        pointCount: Int,
        currentSegment: String?,
        isPaused: Bool,
        tripType: String,
        startDate: Date? = nil
    ) {
        guard sendToWatchEnabled else { return }

        var context: [String: Any] = [
            "tripName": tripName,
            "elapsedTime": elapsedTime,
            "speed": speed,
            "distance": distance,
            "matchedCount": matchedCount,
            "pointCount": pointCount,
            "currentSegment": currentSegment ?? "",
            "isPaused": isPaused,
            "isRecording": true,
            "tripType": tripType
        ]
        if let startDate {
            context["startDate"] = startDate.timeIntervalSince1970
        } else if !isPaused {
            // Derive from elapsed time so the watch timer ticks smoothly even though
            // the recorder only pushes coalesced snapshots. Re-derived on every push,
            // so pause gaps stay accounted for.
            context["startDate"] = Date().timeIntervalSince1970 - elapsedTime
        }

        guard WCSession.default.activationState == .activated else {
            stateQueue.sync { pendingTripContext = context }
            return
        }
        try? WCSession.default.updateApplicationContext(context)
    }

    /// Clear trip status on Watch when recording stops.
    func clearTripStatus() {
        let context: [String: Any] = ["isRecording": false]
        guard WCSession.default.activationState == .activated else {
            // Replace any buffered trip update so a stale "recording" snapshot
            // doesn't flush after the trip already ended.
            stateQueue.sync { pendingTripContext = context }
            return
        }
        stateQueue.sync { pendingTripContext = nil }
        try? WCSession.default.updateApplicationContext(context)
    }

    // MARK: - Directions

    /// Send route directions to Watch.
    func sendDirections(routeName: String, totalDistance: Double, totalTime: TimeInterval, steps: [(instruction: String, distance: Double, notice: String?)]) {
        guard sendToWatchEnabled else { return }

        let stepDicts: [[String: Any]] = steps.map { step in
            var dict: [String: Any] = [
                "instruction": step.instruction,
                "distance": step.distance
            ]
            if let notice = step.notice {
                dict["notice"] = notice
            }
            return dict
        }

        let data: [String: Any] = [
            "type": "directions",
            "routeName": routeName,
            "totalDistance": totalDistance,
            "totalTime": totalTime,
            "steps": stepDicts
        ]

        guard WCSession.default.activationState == .activated else {
            stateQueue.sync { pendingDirections = data }
            return
        }
        WCSession.default.transferUserInfo(data)
    }

    /// Clear directions on Watch.
    func clearDirections() {
        let data: [String: Any] = ["type": "clearDirections"]
        guard WCSession.default.activationState == .activated else {
            // Replace any buffered directions so they don't flush after being cleared.
            stateQueue.sync { pendingDirections = data }
            return
        }
        stateQueue.sync { pendingDirections = nil }
        WCSession.default.transferUserInfo(data)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            SentrySDK.capture(error: error)
            return
        }
        let stateName: String = switch activationState {
        case .activated: "activated"
        case .inactive: "inactive"
        case .notActivated: "notActivated"
        @unknown default: "unknown"
        }
        SentrySDK.logger.info("Watch session state changed", attributes: [
            "state": stateName,
            "paired": session.isPaired,
            "watchAppInstalled": session.isWatchAppInstalled,
        ])
        // Re-push the username on every activation so a watch paired/installed after
        // the username was set (or one that missed an earlier transfer) still gets it.
        if activationState == .activated, session.isWatchAppInstalled,
           let username = UserDefaults.standard.string(forKey: "primaryUser"), !username.isEmpty {
            WCSession.default.transferUserInfo(["type": "username", "username": username])
        }
        // Flush anything dropped while activation was still in flight.
        if activationState == .activated {
            let (tripContext, directions) = stateQueue.sync { () -> ([String: Any]?, [String: Any]?) in
                defer {
                    pendingTripContext = nil
                    pendingDirections = nil
                }
                return (pendingTripContext, pendingDirections)
            }
            if let tripContext {
                try? WCSession.default.updateApplicationContext(tripContext)
            }
            if let directions {
                WCSession.default.transferUserInfo(directions)
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
