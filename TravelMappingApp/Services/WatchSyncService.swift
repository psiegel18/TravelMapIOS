import Foundation
import WatchConnectivity

/// Sends trip recording state and route directions to the paired Apple Watch.
class WatchSyncService: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSyncService()

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - Trip Updates

    /// Send current trip recording state to Watch via applicationContext.
    func sendTripUpdate(
        tripName: String,
        elapsedTime: TimeInterval,
        speed: Double,
        distance: Double,
        matchedCount: Int,
        pointCount: Int,
        currentSegment: String?,
        isPaused: Bool,
        tripType: String
    ) {
        guard UserDefaults.standard.bool(forKey: "sendToWatch"),
              WCSession.default.activationState == .activated else { return }

        let context: [String: Any] = [
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

        try? WCSession.default.updateApplicationContext(context)
    }

    /// Clear trip status on Watch when recording stops.
    func clearTripStatus() {
        guard WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(["isRecording": false])
    }

    // MARK: - Directions

    /// Send route directions to Watch.
    func sendDirections(routeName: String, totalDistance: Double, totalTime: TimeInterval, steps: [(instruction: String, distance: Double, notice: String?)]) {
        guard UserDefaults.standard.bool(forKey: "sendToWatch"),
              WCSession.default.activationState == .activated else { return }

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

        WCSession.default.transferUserInfo(data)
    }

    /// Clear directions on Watch.
    func clearDirections() {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(["type": "clearDirections"])
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            print("[WatchSync] Activation error: \(error)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
