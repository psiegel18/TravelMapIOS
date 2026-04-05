import Foundation

struct TravelSegment: Identifiable {
    let id = UUID()
    let region1: String
    let route: String
    let waypoint1: String
    let region2: String?
    let route2: String?
    let waypoint2: String
    let comment: String?
    let category: RouteCategory

    /// Human-readable display of the segment
    var displayName: String {
        if let region2, let route2, region2 != region1 || route2 != route {
            return "\(region1) \(route) \(waypoint1) → \(region2) \(route2) \(waypoint2)"
        }
        return "\(region1) \(route) \(waypoint1) → \(waypoint2)"
    }

    /// The primary region for grouping
    var primaryRegion: String { region1 }
}
