import ActivityKit
import Foundation

struct RoadTripAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var elapsedTime: TimeInterval
        var currentRoad: String
        var matchedSegments: Int
        var gpsPoints: Int
        var isPaused: Bool
        /// Trip distance so far, in meters (converted to mi/km at display time).
        var distanceMeters: Double
        /// Current speed in meters per second (converted to mph/km/h at display time).
        var speedMps: Double

        init(
            elapsedTime: TimeInterval,
            currentRoad: String,
            matchedSegments: Int,
            gpsPoints: Int,
            isPaused: Bool = false,
            distanceMeters: Double = 0,
            speedMps: Double = 0
        ) {
            self.elapsedTime = elapsedTime
            self.currentRoad = currentRoad
            self.matchedSegments = matchedSegments
            self.gpsPoints = gpsPoints
            self.isPaused = isPaused
            self.distanceMeters = distanceMeters
            self.speedMps = speedMps
        }

        // Backward-compatible: activities started by a build without isPaused /
        // distanceMeters / speedMps can still be decoded after an app update mid-trip.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            elapsedTime = try container.decode(TimeInterval.self, forKey: .elapsedTime)
            currentRoad = try container.decode(String.self, forKey: .currentRoad)
            matchedSegments = try container.decode(Int.self, forKey: .matchedSegments)
            gpsPoints = try container.decode(Int.self, forKey: .gpsPoints)
            isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
            distanceMeters = try container.decodeIfPresent(Double.self, forKey: .distanceMeters) ?? 0
            speedMps = try container.decodeIfPresent(Double.self, forKey: .speedMps) ?? 0
        }
    }

    var tripName: String
    var startDate: Date
}
