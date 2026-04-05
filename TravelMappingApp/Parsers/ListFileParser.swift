import Foundation

struct ListFileParser {

    /// Parse a .list, .rlist, .flist, or .slist file into TravelSegments.
    ///
    /// Format per line (ignoring comments starting with #):
    ///   Single-region:  Region Route Waypoint1 Waypoint2
    ///   Multi-region:   Region1 Route1 Waypoint1 Region2 Route2 Waypoint2
    ///
    /// Multi-region lines are detected when field count >= 5 and field[3]
    /// looks like a region code (all uppercase letters or digits, 2-3 chars,
    /// or a known pattern like state abbreviations).
    static func parse(content: String, category: RouteCategory) -> [TravelSegment] {
        var segments: [TravelSegment] = []
        var currentComment: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines
            if trimmed.isEmpty { continue }

            // Track comment headers for context
            if trimmed.hasPrefix("#") {
                let commentText = trimmed.drop(while: { $0 == "#" || $0 == " " })
                if !commentText.isEmpty {
                    currentComment = String(commentText)
                }
                continue
            }

            // Strip inline comments
            let dataLine: String
            if let hashIndex = trimmed.firstIndex(of: "#") {
                dataLine = String(trimmed[trimmed.startIndex..<hashIndex])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                dataLine = trimmed
            }

            if dataLine.isEmpty { continue }

            let fields = dataLine.split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)

            guard fields.count >= 4 else { continue }

            // Determine if this is a multi-region line.
            // Multi-region: Region1 Route1 Waypoint1 Region2 Route2 Waypoint2
            // Single-region: Region Route Waypoint1 Waypoint2
            //
            // Heuristic: if there are 6 fields, it's likely multi-region.
            // If there are 5 fields, check if field[3] looks like a region code.
            // If there are 4 fields, it's single-region.

            if fields.count >= 6 {
                // Multi-region: R1 Rt1 WP1 R2 Rt2 WP2
                let segment = TravelSegment(
                    region1: fields[0],
                    route: fields[1],
                    waypoint1: fields[2],
                    region2: fields[3],
                    route2: fields[4],
                    waypoint2: fields[5],
                    comment: currentComment,
                    category: category
                )
                segments.append(segment)
            } else if fields.count == 5 && looksLikeRegion(fields[3]) {
                // Multi-region with same route: R1 Rt1 WP1 R2 WP2
                // e.g., "IL I-39 122 WI 113" -- but TM format actually uses
                // "IL I-39 122 WI I-39 113" for multi-region.
                // 5-field lines where field[3] is a region: R1 Rt Wp1 R2 Rt Wp2
                // Actually looking at the data, 5-field lines like:
                // "IL I-39 122 WI I-39 113" would be 6 fields.
                // 5-field: "NY I-86 46 NY I-86Owe 67" is 6 fields.
                // Let me check: "FL I-4 82 FL I-4 132" = 6 fields. Yes.
                //
                // So 5 fields is unusual. Treat as:
                // R1 Route WP1 R2 WP2 (same route carries across regions)
                let segment = TravelSegment(
                    region1: fields[0],
                    route: fields[1],
                    waypoint1: fields[2],
                    region2: fields[3],
                    route2: fields[1], // same route
                    waypoint2: fields[4],
                    comment: currentComment,
                    category: category
                )
                segments.append(segment)
            } else {
                // Single-region: Region Route Waypoint1 Waypoint2
                // (4 fields, or 5+ fields where field[3] is not a region)
                let segment = TravelSegment(
                    region1: fields[0],
                    route: fields[1],
                    waypoint1: fields[2],
                    region2: nil,
                    route2: nil,
                    waypoint2: fields[3],
                    comment: currentComment,
                    category: category
                )
                segments.append(segment)
            }
        }

        return segments
    }

    /// Heuristic: does this string look like a TM region code?
    /// Region codes are 2-3 uppercase letters (US states, country codes)
    /// or longer codes like "NIR", "IRL", etc.
    private static func looksLikeRegion(_ s: String) -> Bool {
        guard s.count >= 2 && s.count <= 3 else { return false }
        return s.allSatisfy { $0.isUppercase || $0.isNumber }
    }
}
