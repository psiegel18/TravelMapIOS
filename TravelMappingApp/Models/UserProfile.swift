import Foundation

struct UserProfile: Identifiable, Hashable {
    let id: String // username
    let username: String
    var categories: [RouteCategory: [TravelSegment]]

    var totalSegments: Int {
        categories.values.reduce(0) { $0 + $1.count }
    }

    var allRegions: Set<String> {
        var regions = Set<String>()
        for segments in categories.values {
            for segment in segments {
                regions.insert(segment.primaryRegion)
                if let r2 = segment.region2 {
                    regions.insert(r2)
                }
            }
        }
        return regions
    }

    var allRoutes: Set<String> {
        var routes = Set<String>()
        for segments in categories.values {
            for segment in segments {
                routes.insert("\(segment.region1) \(segment.route)")
                if let r2 = segment.region2, let route2 = segment.route2 {
                    routes.insert("\(r2) \(route2)")
                }
            }
        }
        return routes
    }

    /// Segments grouped by section header (from comments in the file)
    func segments(for category: RouteCategory) -> [TravelSegment] {
        categories[category] ?? []
    }

    func segmentsByRegion(for category: RouteCategory) -> [(region: String, segments: [TravelSegment])] {
        let segs = segments(for: category)
        let grouped = Dictionary(grouping: segs) { $0.primaryRegion }
        return grouped.sorted { $0.key < $1.key }
            .map { (region: $0.key, segments: $0.value) }
    }

    static func == (lhs: UserProfile, rhs: UserProfile) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
