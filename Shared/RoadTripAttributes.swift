import ActivityKit
import Foundation

struct RoadTripAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var elapsedTime: TimeInterval
        var currentRoad: String
        var matchedSegments: Int
        var gpsPoints: Int
        var isPaused: Bool

        init(
            elapsedTime: TimeInterval,
            currentRoad: String,
            matchedSegments: Int,
            gpsPoints: Int,
            isPaused: Bool = false
        ) {
            self.elapsedTime = elapsedTime
            self.currentRoad = currentRoad
            self.matchedSegments = matchedSegments
            self.gpsPoints = gpsPoints
            self.isPaused = isPaused
        }

        // Backward-compatible: activities started by a build without isPaused
        // can still be decoded after an app update mid-trip.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            elapsedTime = try container.decode(TimeInterval.self, forKey: .elapsedTime)
            currentRoad = try container.decode(String.self, forKey: .currentRoad)
            matchedSegments = try container.decode(Int.self, forKey: .matchedSegments)
            gpsPoints = try container.decode(Int.self, forKey: .gpsPoints)
            isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        }
    }

    var tripName: String
    var startDate: Date
}
