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

            // Real-world .list files mix spaces and tabs — split on any whitespace
            let fields = dataLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
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

// MARK: - TravelMapping user log

/// One problem TravelMapping reported with a line of the user's list file during its
/// nightly site update (https://travelmapping.net/logs/users/<user>.log).
struct ListLogIssue: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Waypoint label(s) no longer on the route (often renumbered exits)
        case missingWaypoints([String])
        /// Route was renamed; TravelMapping still accepts the old name for now
        case deprecatedRoute(old: String, canonical: String)
        /// Region/route combination doesn't exist (removed, renamed or mistyped)
        case unknownRoute
        /// Both ends resolve to the same point, so the line adds nothing
        case zeroDistance
    }

    let kind: Kind
    /// The list line exactly as TravelMapping quoted it
    let line: String
    /// TravelMapping's own message
    let message: String
    /// "Route updated 2026-10-15: NY I-81" notes printed under the issue
    var routeNotes: [String] = []

    var id: String { "\(line)|\(message)" }
}

/// Route change history from the log's "Most recent updates for listed routes" table.
struct ListLogRouteUpdate: Hashable, Sendable {
    let date: String
    let root: String
    let description: String
}

enum ListLogParser {
    static func parse(_ text: String) -> (issues: [ListLogIssue], updates: [ListLogRouteUpdate]) {
        var issues: [ListLogIssue] = []
        var updates: [ListLogRouteUpdate] = []
        var inUpdates = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if rawLine.hasPrefix(" "), line.hasPrefix("Route updated"), !issues.isEmpty {
                issues[issues.count - 1].routeNotes.append(line)
                continue
            }
            if line.hasPrefix("Most recent updates for listed routes") { inUpdates = true; continue }
            if inUpdates {
                // date | (country) state | route | root | description
                let cols = line.components(separatedBy: " | ")
                if cols.count >= 5, cols[0].count == 10 {
                    updates.append(ListLogRouteUpdate(date: cols[0], root: cols[3],
                                                      description: cols[4...].joined(separator: " | ")))
                    continue
                }
                inUpdates = false
            }

            guard let range = line.range(of: " in line: ") else { continue }
            let head = String(line[..<range.lowerBound])
            // TM quotes the line with its trailing "# comment"; keep only the entry so it
            // parses and matches the file line (whose comment the fix preserves)
            var listLine = String(line[range.upperBound...])
            if let hash = listLine.firstIndex(of: "#") { listLine = String(listLine[..<hash]) }
            listLine = listLine.trimmingCharacters(in: .whitespaces)
            guard !listLine.isEmpty else { continue }

            if head.hasPrefix("Waypoint label ") && head.hasSuffix(" not found") {
                let label = head.dropFirst("Waypoint label ".count).dropLast(" not found".count)
                issues.append(ListLogIssue(kind: .missingWaypoints([String(label)]), line: listLine, message: line))
            } else if head.hasPrefix("Waypoint labels ") && head.hasSuffix(" not found") {
                // "A and B", or "A, B, and C"
                let labels = head.dropFirst("Waypoint labels ".count).dropLast(" not found".count)
                    .replacingOccurrences(of: ", and ", with: ", ")
                    .replacingOccurrences(of: " and ", with: ", ")
                    .components(separatedBy: ", ")
                issues.append(ListLogIssue(kind: .missingWaypoints(labels), line: listLine, message: line))
            } else if head.hasPrefix("Waypoint ") && head.hasSuffix(" not found") {
                // Multi-region form: "Waypoint NY I-81 27 not found"
                let parts = head.dropFirst("Waypoint ".count).dropLast(" not found".count).split(separator: " ")
                if let label = parts.last {
                    issues.append(ListLogIssue(kind: .missingWaypoints([String(label)]), line: listLine, message: line))
                }
            } else if head.hasPrefix("Note: deprecated route name "), let arrow = head.range(of: " -> canonical name ") {
                let old = unquote(String(head[head.index(head.startIndex, offsetBy: "Note: deprecated route name ".count)..<arrow.lowerBound]))
                let canonical = unquote(String(head[arrow.upperBound...]))
                issues.append(ListLogIssue(kind: .deprecatedRoute(old: old, canonical: canonical), line: listLine, message: line))
            } else if head.hasPrefix("Unknown region/highway combo") {
                // YY/ZZ-prefixed regions are lines users deliberately park
                let region = listLine.split(separator: " ").first.map(String.init) ?? ""
                if region.hasPrefix("YY") || region.hasPrefix("ZZ") { continue }
                issues.append(ListLogIssue(kind: .unknownRoute, line: listLine, message: line))
            } else if head.hasPrefix("Equivalent waypoint labels") {
                issues.append(ListLogIssue(kind: .zeroDistance, line: listLine, message: line))
            }
        }
        // TM repeats some notes once per region of a multi-region line; identical issues
        // would collide as SwiftUI identities
        var seen = Set<String>()
        return (issues.filter { seen.insert($0.id).inserted }, updates)
    }

    /// `"ESP-EX A66"` → `A66`; `I-481` → `I-481`
    private static func unquote(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return trimmed.split(separator: " ").last.map(String.init) ?? trimmed
    }
}
