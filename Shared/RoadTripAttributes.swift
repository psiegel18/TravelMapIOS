import ActivityKit
import Foundation

struct RoadTripAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var elapsedTime: TimeInterval
        var currentRoad: String
        var matchedSegments: Int
        var gpsPoints: Int
    }

    var tripName: String
    var startDate: Date
}
