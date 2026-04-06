import Foundation
import CoreLocation

enum TripStatus: String, Codable {
    case recording
    case processing
    case completed
    case failed
}

enum TripType: String, Codable {
    case road
    case rail
}

enum TravelDirection: String, Codable {
    case forward   // traveled w1 -> w2
    case reverse   // traveled w2 -> w1
    case unknown
}

struct GPSPoint: Codable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let speed: Double         // m/s, -1 if unavailable
    let course: Double        // degrees, -1 if unavailable
    let timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(from location: CLLocation) {
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.speed = location.speed
        self.course = location.course
        self.timestamp = location.timestamp
    }
}

struct MatchedSegment: Identifiable, Codable {
    let id: UUID
    let root: String            // e.g., "fl.i095"
    let listName: String        // e.g., "FL I-95"
    let startWaypoint: String   // e.g., "12B"
    let endWaypoint: String     // e.g., "45"
    let entryTime: Date
    var exitTime: Date
    let direction: TravelDirection
    let confidence: Double      // 0.0-1.0

    /// The region extracted from listName (e.g., "FL" from "FL I-95")
    var region: String {
        String(listName.split(separator: " ").first ?? "")
    }

    /// The route name extracted from listName (e.g., "I-95" from "FL I-95")
    var routeName: String {
        let parts = listName.split(separator: " ", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : ""
    }
}

struct RoadTrip: Identifiable, Codable {
    let id: UUID
    var name: String
    var notes: String = ""
    let startDate: Date
    var endDate: Date?
    var status: TripStatus
    var tripType: TripType
    var rawPoints: [GPSPoint]
    var matchedSegments: [MatchedSegment]

    var duration: TimeInterval? {
        guard let end = endDate else { return nil }
        return end.timeIntervalSince(startDate)
    }

    var durationFormatted: String {
        guard let dur = duration else { return "Recording..." }
        let hours = Int(dur) / 3600
        let minutes = (Int(dur) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    // Backward-compatible decoding — existing trips without tripType default to .road
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        status = try container.decode(TripStatus.self, forKey: .status)
        tripType = try container.decodeIfPresent(TripType.self, forKey: .tripType) ?? .road
        rawPoints = try container.decode([GPSPoint].self, forKey: .rawPoints)
        matchedSegments = try container.decode([MatchedSegment].self, forKey: .matchedSegments)
    }

    init(name: String? = nil, tripType: TripType = .road) {
        self.id = UUID()
        self.name = name ?? "\(tripType == .rail ? "Train Trip" : "Trip") on \(Date().formatted(date: .abbreviated, time: .omitted))"
        self.notes = ""
        self.startDate = Date()
        self.endDate = nil
        self.status = .recording
        self.tripType = tripType
        self.rawPoints = []
        self.matchedSegments = []
    }
}
