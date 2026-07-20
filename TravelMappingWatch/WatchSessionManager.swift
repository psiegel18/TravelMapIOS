import Foundation
import Sentry
import WatchConnectivity

/// Receives trip state and directions from the paired iPhone.
class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    /// UserDefaults key where the last received directions payload is persisted, so a
    /// watch app relaunch mid-drive doesn't lose them (transferUserInfo is one-shot).
    private static let persistedDirectionsKey = "persistedDirections"

    // MARK: - Trip State

    struct TripState {
        var tripName: String
        var elapsedTime: TimeInterval
        var speed: Double          // m/s
        var distance: Double       // meters
        var matchedCount: Int
        var pointCount: Int
        var currentSegment: String
        var isPaused: Bool
        var tripType: String
        /// Trip start reference from the phone. When present (and not paused) the UI
        /// computes elapsed time locally so the timer ticks between coalesced
        /// applicationContext pushes; `elapsedTime` is the static fallback.
        var startDate: Date?

        static func format(_ elapsed: TimeInterval) -> String {
            let h = Int(elapsed) / 3600
            let m = (Int(elapsed) % 3600) / 60
            let s = Int(elapsed) % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        }

        var formattedTime: String { Self.format(elapsedTime) }

        var speedMPH: Double { speed * 2.23694 }
        var distanceMiles: Double { distance / 1609.34 }
    }

    // MARK: - Directions

    struct DirectionsData {
        var routeName: String
        var totalDistance: Double   // meters
        var totalTime: TimeInterval
        var steps: [DirectionStep]

        var distanceMiles: String { String(format: "%.0f mi", totalDistance / 1609.34) }
        var timeFormatted: String {
            let h = Int(totalTime) / 3600
            let m = (Int(totalTime) % 3600) / 60
            return h > 0 ? "\(h)h \(m)m" : "\(m)m"
        }
    }

    struct DirectionStep: Identifiable {
        let id = UUID()
        let instruction: String
        let distance: Double       // meters
        let notice: String?

        var distanceMiles: String {
            distance > 0 ? String(format: "%.1f mi", distance / 1609.34) : ""
        }
    }

    // MARK: - Published State

    @Published var tripState: TripState?
    @Published var directions: DirectionsData?
    @Published var isRecording = false

    private override init() {
        super.init()
        // Restore persisted directions so a relaunch mid-drive keeps them.
        if let saved = UserDefaults.standard.dictionary(forKey: Self.persistedDirectionsKey) {
            directions = Self.parseDirections(saved)
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            SentrySDK.capture(error: error)
        }
        // Check for existing context on launch
        if activationState == .activated {
            DispatchQueue.main.async {
                self.handleContext(session.receivedApplicationContext)
            }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.handleContext(applicationContext)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        DispatchQueue.main.async {
            self.handleUserInfo(userInfo)
        }
    }

    // MARK: - Parsing

    private func handleContext(_ context: [String: Any]) {
        let recording = context["isRecording"] as? Bool ?? false
        isRecording = recording

        if recording {
            tripState = TripState(
                tripName: context["tripName"] as? String ?? "Trip",
                elapsedTime: context["elapsedTime"] as? TimeInterval ?? 0,
                speed: context["speed"] as? Double ?? 0,
                distance: context["distance"] as? Double ?? 0,
                matchedCount: context["matchedCount"] as? Int ?? 0,
                pointCount: context["pointCount"] as? Int ?? 0,
                currentSegment: context["currentSegment"] as? String ?? "",
                isPaused: context["isPaused"] as? Bool ?? false,
                tripType: context["tripType"] as? String ?? "road",
                startDate: (context["startDate"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
            )
        } else {
            tripState = nil
        }
    }

    private func handleUserInfo(_ info: [String: Any]) {
        let type = info["type"] as? String ?? ""

        if type == "directions" {
            directions = Self.parseDirections(info)
            // Persist for relaunch. The payload is plist-compatible (strings, doubles,
            // arrays of dictionaries), so it can go into UserDefaults as-is.
            UserDefaults.standard.set(info, forKey: Self.persistedDirectionsKey)
        } else if type == "clearDirections" {
            directions = nil
            UserDefaults.standard.removeObject(forKey: Self.persistedDirectionsKey)
        } else if type == "username" {
            if let username = info["username"] as? String, !username.isEmpty {
                UserDefaults.standard.set(username, forKey: "watchUsername")
            }
        }
    }

    private static func parseDirections(_ info: [String: Any]) -> DirectionsData {
        let stepDicts = info["steps"] as? [[String: Any]] ?? []
        let steps = stepDicts.map { dict in
            DirectionStep(
                instruction: dict["instruction"] as? String ?? "",
                distance: dict["distance"] as? Double ?? 0,
                notice: dict["notice"] as? String
            )
        }
        return DirectionsData(
            routeName: info["routeName"] as? String ?? "",
            totalDistance: info["totalDistance"] as? Double ?? 0,
            totalTime: info["totalTime"] as? TimeInterval ?? 0,
            steps: steps
        )
    }
}
