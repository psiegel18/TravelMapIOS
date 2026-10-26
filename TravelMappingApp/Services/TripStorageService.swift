import Foundation
import Sentry
import CoreLocation

actor TripStorageService {
    static let shared = TripStorageService()

    /// Lazy setup: directory resolution + creation runs off the main thread on first use.
    /// `forUbiquityContainerIdentifier` and `createDirectory` against an iCloud Drive container
    /// can each block for several seconds on a cold launch, which used to hang the main actor
    /// when `shared` was first touched from `TripRecordingService.checkForOrphanedTrip`.
    private let setupTask: Task<(URL, Bool), Never>

    init() {
        setupTask = Task.detached(priority: .userInitiated) {
            let dir: URL
            let isICloud: Bool
            if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents")
                .appendingPathComponent("Trips", isDirectory: true) {
                dir = iCloudURL
                isICloud = true
            } else {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                dir = docs.appendingPathComponent("Trips", isDirectory: true)
                isICloud = false
            }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return (dir, isICloud)
        }
    }

    private func tripsDirectory() async -> URL {
        await setupTask.value.0
    }

    func isUsingICloud() async -> Bool {
        await setupTask.value.1
    }

    func save(_ trip: RoadTrip) async throws {
        let dir = await tripsDirectory()
        let data = try JSONEncoder().encode(trip)
        let fileURL = dir.appendingPathComponent("\(trip.id.uuidString).json")
        // Atomic — a crash mid-write must never leave a truncated/corrupt trip file
        try data.write(to: fileURL, options: .atomic)
    }

    func load(id: UUID) async throws -> RoadTrip {
        let dir = await tripsDirectory()
        let fileURL = dir.appendingPathComponent("\(id.uuidString).json")
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(RoadTrip.self, from: data)
    }

    func listTrips() async throws -> [RoadTrip] {
        let dir = await tripsDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "list-submissions.json" }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return dateA > dateB
            }

        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            do {
                return try JSONDecoder().decode(RoadTrip.self, from: data)
            } catch {
                // Skip the corrupt file but don't lose visibility — a silently
                // dropped trip looks like data loss to the user.
                SentrySDK.capture(error: error)
                return nil
            }
        }
    }

    func delete(id: UUID) async throws {
        let dir = await tripsDirectory()
        let jsonURL = dir.appendingPathComponent("\(id.uuidString).json")
        let listURL = dir.appendingPathComponent("\(id.uuidString).list")
        try? FileManager.default.removeItem(at: jsonURL)
        try? FileManager.default.removeItem(at: listURL)
    }

    // MARK: .list submissions

    /// All .list updates the user has sent (or marked as sent), in one iCloud-synced file
    /// next to the trips. Kept apart from the trip files so a segment submitted from one
    /// trip counts for every trip that drove it, and re-saving a stale trip copy (or a
    /// trip saved by an older app version on another device) can't drop the marks.
    func listSubmissions() async -> [ListSubmission] {
        let url = await tripsDirectory().appendingPathComponent(Self.submissionsFile)
        return readSubmissions(at: url) ?? []
    }

    /// Hop keys currently waiting on TravelMapping for a list type ("list" / "rlist").
    func submittedHopKeys(fileExtension: String) async -> Set<String> {
        Set(await listSubmissions().filter { $0.fileExtension == fileExtension }.flatMap(\.hopKeys))
    }

    /// Records a submission. Lines added to an already-recorded PR merge into its entry.
    func recordSubmission(fileExtension: String, hopKeys: [String], lines: [String], pr: ListUpdatePR?) async {
        let url = await tripsDirectory().appendingPathComponent(Self.submissionsFile)
        // No suspension point from here to the write, so concurrent calls on this actor
        // can't interleave their read-modify-write and drop an update.
        guard var all = readSubmissions(at: url) else {
            SentrySDK.logger.warn("List submission not recorded: submissions file unreadable (iCloud download pending)")
            return
        }
        if let pr, let i = all.firstIndex(where: { $0.pr?.number == pr.number }) {
            all[i].hopKeys = Array(Set(all[i].hopKeys).union(hopKeys))
            all[i].lines += lines.filter { !all[i].lines.contains($0) }
            all[i].pr = pr
        } else {
            all.append(ListSubmission(id: UUID(), date: Date(), fileExtension: fileExtension,
                                      hopKeys: hopKeys, lines: lines, pr: pr))
        }
        writeSubmissions(all, to: url)
    }

    func removeSubmissions(where shouldRemove: @Sendable (ListSubmission) -> Bool) async {
        let url = await tripsDirectory().appendingPathComponent(Self.submissionsFile)
        guard let all = readSubmissions(at: url) else { return }
        let kept = all.filter { !shouldRemove($0) }
        if kept.count != all.count { writeSubmissions(kept, to: url) }
    }

    /// Not ".json": `listTrips()` here and in 1.2 decodes every .json in this folder as a trip.
    private static let submissionsFile = "list-submissions.tmsubmissions"

    /// nil when the file exists but can't be read yet (e.g. an iCloud placeholder still
    /// downloading on this device) — writers must not overwrite it with a partial list.
    private func readSubmissions(at url: URL) -> [ListSubmission]? {
        let fm = FileManager.default
        // Early 1.3 betas used list-submissions.json — adopt it once, then remove it so
        // listTrips() (here and in 1.2) stops tripping over it
        let legacy = url.deletingLastPathComponent().appendingPathComponent("list-submissions.json")
        if !fm.fileExists(atPath: url.path), let data = try? Data(contentsOf: legacy),
           let old = try? JSONDecoder().decode([ListSubmission].self, from: data) {
            writeSubmissions(old, to: url)
            try? fm.removeItem(at: legacy)
            return old
        }
        if !fm.fileExists(atPath: url.path) {
            // iCloud keeps not-yet-downloaded files as hidden ".name.icloud" placeholders
            let placeholder = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                return nil
            }
            return []
        }
        guard let data = try? Data(contentsOf: url) else {
            try? fm.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        do {
            return try JSONDecoder().decode([ListSubmission].self, from: data)
        } catch {
            // Corrupt (e.g. a botched iCloud merge): set it aside and start fresh rather
            // than refusing every future write
            SentrySDK.capture(error: error)
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("list-submissions-corrupt-\(Int(Date().timeIntervalSince1970)).bak")
            try? fm.moveItem(at: url, to: aside)
            return []
        }
    }

    private func writeSubmissions(_ submissions: [ListSubmission], to url: URL) {
        do {
            try JSONEncoder().encode(submissions).write(to: url, options: .atomic)
        } catch {
            SentrySDK.capture(error: error)
        }
    }

    /// Export the trip's matched segments as a .list file, return the file URL.
    func exportListFile(for trip: RoadTrip) async throws -> URL {
        let dir = await tripsDirectory()
        let content = ListFileGenerator.generate(from: trip.matchedSegments, tripName: trip.name)
        let fileURL = dir.appendingPathComponent("\(trip.id.uuidString).list")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        SentrySDK.logger.info("Trip exported to .list", attributes: [
            "segmentCount": trip.matchedSegments.count,
            "bytes": content.utf8.count,
            "tripType": trip.tripType == .rail ? "rail" : "road",
        ])
        return fileURL
    }
}

// MARK: - Trip Log Analysis

/// One .list update the user sent: manually ("Mark as submitted") or as an app PR.
struct ListSubmission: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    /// "list" or "rlist"
    let fileExtension: String
    var hopKeys: [String]
    var lines: [String]
    var pr: ListUpdatePR?
}

/// A contiguous stretch of one route that a recorded trip traveled, classified against
/// what the traveler's .list file already has (per the TM database).
struct TripLogRange: Identifiable, Sendable {
    enum Status: String, Sendable {
        case new        // traveled, not in the .list
        case submitted  // user marked it as sent in a .list update, DB not caught up yet
        case logged     // DB already reports it clinched
    }

    let root: String
    let region: String
    let route: String
    let startWaypoint: String
    let endWaypoint: String
    let status: Status
    let hopKeys: [String]
    let coordinates: [CLLocationCoordinate2D]
    /// IDs of the trips that traveled this stretch
    let tripIDs: Set<UUID>
    /// This route's waypoint labels in order (see `ListLine.routeLabels`)
    var routeLabels: [String] = []

    var id: String { "\(root)|\(startWaypoint)|\(endWaypoint)|\(status.rawValue)" }
    var line: ListLine { ListLine(region: region, route: route, waypoint1: startWaypoint, waypoint2: endWaypoint, routeLabels: routeLabels) }
}

struct TripLogAnalysis: Sendable {
    let ranges: [TripLogRange]
    /// Matched segments that couldn't be located on current route data (route
    /// renumbered/relocated since the trip, or metadata missing)
    let unresolvedCount: Int

    var newRanges: [TripLogRange] { ranges.filter { $0.status == .new } }
    var submittedRanges: [TripLogRange] { ranges.filter { $0.status == .submitted } }
    var loggedRanges: [TripLogRange] { ranges.filter { $0.status == .logged } }
}

/// Compares recorded trips against the traveler's clinched segments so only the
/// not-yet-logged parts get turned into .list lines.
enum TripLogAnalyzer {

    /// All trips must share a trip type (roads and rail live in different list files).
    /// `submittedKeys` should come from `TripStorageService.submittedHopKeys` — the
    /// submissions of every trip, not just the ones analyzed.
    static func analyze(trips: [RoadTrip], username: String, submittedKeys: Set<String>) async throws -> TripLogAnalysis {
        let api: TravelMappingAPI = trips.first?.tripType == .rail ? .rail : .shared
        let roots = Array(Set(trips.flatMap { $0.matchedSegments.map(\.root) })).sorted()
        guard !roots.isEmpty else { return TripLogAnalysis(ranges: [], unresolvedCount: 0) }

        // Fetch every hop of the traveled routes with this traveler's clinch flags
        var hopsByRoot: [String: [TravelMappingAPI.MapSegment]] = [:]
        var listNames: [String: String] = [:]
        try await withThrowingTaskGroup(of: (segments: [TravelMappingAPI.MapSegment], routes: [TravelMappingAPI.RouteMetadata]).self) { group in
            // Batch per region (root prefix) so a new trip only changes the cache keys of
            // the regions it touches; the TM database updates daily, so cache for 24h.
            let byRegion = Dictionary(grouping: roots) { String($0.split(separator: ".").first ?? "") }
            for regionRoots in byRegion.values {
                for start in stride(from: 0, to: regionRoots.count, by: 40) {
                    let batch = Array(regionRoots[start..<min(start + 40, regionRoots.count)])
                    group.addTask { try await api.getRegionSegments(roots: batch, traveler: username, cacheTTL: 24 * 3600) }
                }
            }
            for try await result in group {
                for seg in result.segments { hopsByRoot[seg.root, default: []].append(seg) }
                for route in result.routes where !route.listName.isEmpty { listNames[route.root] = route.listName }
            }
        }
        for root in hopsByRoot.keys { hopsByRoot[root]?.sort { $0.orderIndex < $1.orderIndex } }

        let submitted = submittedKeys

        struct Builder {
            var root: String
            var status: TripLogRange.Status
            var hops: [TravelMappingAPI.MapSegment]
            var tripIDs: Set<UUID>
        }
        var builders: [Builder] = []
        var seenHops = Set<String>()
        var unresolved = 0

        for trip in trips.sorted(by: { $0.startDate < $1.startDate }) {
            for matched in trip.matchedSegments.sorted(by: { $0.entryTime < $1.entryTime }) {
                guard let hops = hopsByRoot[matched.root],
                      let path = path(in: hops, from: matched.startWaypoint, to: matched.endWaypoint) else {
                    unresolved += 1
                    continue
                }
                for hop in path {
                    guard seenHops.insert(hop.id).inserted else {
                        if let i = builders.firstIndex(where: { $0.hops.contains { $0.id == hop.id } }) {
                            builders[i].tripIDs.insert(trip.id)
                        }
                        continue
                    }
                    let status: TripLogRange.Status = hop.isClinched ? .logged
                        : submitted.contains(hop.id) ? .submitted : .new

                    // Extend the latest range when this hop continues it in either direction
                    if var last = builders.last, last.root == hop.root, last.status == status {
                        if last.hops.last?.endName == hop.startName {
                            last.hops.append(hop)
                        } else if last.hops.first?.startName == hop.endName {
                            last.hops.insert(hop, at: 0)
                        } else {
                            builders.append(Builder(root: hop.root, status: status, hops: [hop], tripIDs: [trip.id]))
                            continue
                        }
                        last.tripIDs.insert(trip.id)
                        builders[builders.count - 1] = last
                    } else {
                        builders.append(Builder(root: hop.root, status: status, hops: [hop], tripIDs: [trip.id]))
                    }
                }
            }
        }

        // Routes driven against their waypoint order arrive as fragments in reverse; join
        // any same-route, same-status ranges that touch end to end.
        var joined: [Builder] = []
        for b in builders {
            if let i = joined.firstIndex(where: { $0.root == b.root && $0.status == b.status &&
                ($0.hops.last?.endName == b.hops.first?.startName || b.hops.last?.endName == $0.hops.first?.startName) }) {
                if joined[i].hops.last?.endName == b.hops.first?.startName {
                    joined[i].hops += b.hops
                } else {
                    joined[i].hops = b.hops + joined[i].hops
                }
                joined[i].tripIDs.formUnion(b.tripIDs)
            } else {
                joined.append(b)
            }
        }
        builders = joined

        // Fall back to the name stored at record time when the API omitted route metadata
        for trip in trips {
            for seg in trip.matchedSegments where listNames[seg.root] == nil && seg.listName.contains(" ") {
                listNames[seg.root] = seg.listName
            }
        }

        let ranges: [TripLogRange] = builders.compactMap { b in
            guard let listName = listNames[b.root], let routeHops = hopsByRoot[b.root] else {
                unresolved += 1
                return nil
            }
            let hops = extendToVisibleWaypoints(b.hops, in: routeHops)
            guard let first = hops.first, let last = hops.last else { return nil }
            let parts = listName.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return TripLogRange(
                root: b.root,
                region: parts[0],
                route: parts[1],
                startWaypoint: first.startName,
                endWaypoint: last.endName,
                status: b.status,
                hopKeys: hops.map(\.id),
                coordinates: [first.start] + hops.map(\.end),
                tripIDs: b.tripIDs,
                routeLabels: Self.orderedLabels(routeHops)
            )
        }
        return TripLogAnalysis(ranges: ranges, unresolvedCount: unresolved)
    }

    /// Labels along the route in order. Where the route breaks (a hop that doesn't start
    /// where the last ended) both sides are kept, so the merger never treats the two
    /// pieces as touching. Hidden "+" shaping points are left out — they can't be in a .list.
    static func orderedLabels(_ routeHops: [TravelMappingAPI.MapSegment]) -> [String] {
        var labels: [String] = []
        for hop in routeHops {
            if labels.last != hop.startName { labels.append(hop.startName) }
            labels.append(hop.endName)
        }
        return labels.filter { !$0.hasPrefix("+") }
    }

    /// Hidden shaping points ("+X04") can't appear in a .list, so a range that starts or
    /// ends on one grows outward to the nearest visible waypoint.
    private static func extendToVisibleWaypoints(_ hops: [TravelMappingAPI.MapSegment], in routeHops: [TravelMappingAPI.MapSegment]) -> [TravelMappingAPI.MapSegment] {
        guard let firstID = hops.first?.id, let lastID = hops.last?.id,
              let firstIndex = routeHops.firstIndex(where: { $0.id == firstID }),
              let lastIndex = routeHops.firstIndex(where: { $0.id == lastID }) else { return hops }
        var lo = firstIndex
        var hi = lastIndex
        while routeHops[lo].startName.hasPrefix("+"), lo > 0,
              routeHops[lo - 1].endName == routeHops[lo].startName {
            lo -= 1
        }
        while routeHops[hi].endName.hasPrefix("+"), hi < routeHops.count - 1,
              routeHops[hi + 1].startName == routeHops[hi].endName {
            hi += 1
        }
        return Array(routeHops[lo..<firstIndex]) + hops + Array(routeHops[(lastIndex + 1)..<(hi + 1)])
    }

    /// Hops between two waypoint labels, in route order, whichever way they were driven.
    private static func path(in hops: [TravelMappingAPI.MapSegment], from a: String, to b: String) -> [TravelMappingAPI.MapSegment]? {
        func span(_ from: String, _ to: String) -> [TravelMappingAPI.MapSegment]? {
            guard let i = hops.firstIndex(where: { $0.startName == from }),
                  let j = hops[i...].firstIndex(where: { $0.endName == to }) else { return nil }
            let slice = Array(hops[i...j])
            // Reject spans that jump across a gap in the route (disconnected pieces)
            for (x, y) in zip(slice, slice.dropFirst()) where x.endName != y.startName { return nil }
            return slice
        }
        return span(a, b) ?? span(b, a)
    }
}

// MARK: - List checkup

/// A route's current waypoint labels in route order (hidden "+" points excluded).
struct RouteWaypoints: Sendable {
    let root: String
    let listName: String
    let labels: [String]
    let coordinates: [String: CLLocationCoordinate2D]
}

/// A .list entry split into its endpoints. Handles `R Rt W1 W2` and `R1 Rt1 W1 R2 Rt2 W2`.
struct ListEntry: Hashable, Sendable {
    var region1: String, route1: String, waypoint1: String
    var region2: String, route2: String, waypoint2: String
    let multiRegion: Bool

    init?(_ line: String) {
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if f.count == 4 {
            (region1, route1, waypoint1, region2, route2, waypoint2) = (f[0], f[1], f[2], f[0], f[1], f[3])
            multiRegion = false
        } else if f.count == 6 {
            (region1, route1, waypoint1, region2, route2, waypoint2) = (f[0], f[1], f[2], f[3], f[4], f[5])
            multiRegion = true
        } else {
            return nil
        }
    }

    var text: String {
        multiRegion
            ? "\(region1) \(route1) \(waypoint1) \(region2) \(route2) \(waypoint2)"
            : "\(region1) \(route1) \(waypoint1) \(waypoint2)"
    }

    var routeKey1: String { "\(region1.uppercased()) \(route1.uppercased())" }
    var routeKey2: String { "\(region2.uppercased()) \(route2.uppercased())" }
}

/// One flagged line with the fix the checkup proposes (if any).
struct CheckupFix: Identifiable, Sendable {
    enum Source: String, Sendable {
        case automatic = "Automatic"
        case ai = "AI suggestion"
        case manual = "You chose"
    }

    let issue: ListLogIssue
    var replacement: String?
    var source: Source?
    var note: String?
    /// Current waypoints for the routes in the line, keyed "REGION ROUTE"
    var routes: [String: RouteWaypoints] = [:]

    /// The line a fix should produce: the original, with a renamed route already applied
    var target: ListEntry?

    var id: String { issue.id }
    var canPickWaypoints: Bool {
        guard let target, !routes.isEmpty else { return false }
        return routes[target.routeKey1] != nil && routes[target.routeKey2] != nil
    }
}

/// Finds lines of the user's list that didn't count in TravelMapping's last nightly update
/// and proposes fixes. Everything here is deterministic and checked against current route
/// data; AI suggestions (opt-in, the user's own key) only fill gaps and are validated the
/// same way before they're shown.
enum ListCheckup {
    struct Result: Sendable {
        var fixes: [CheckupFix]
        let updates: [ListLogRouteUpdate]
        /// "psiegel18.list last updated: …" line, for context
        let fileUpdated: String?
    }

    static func logURL(username: String, category: RouteCategory) -> URL {
        let host = category == .rail ? "https://tmrail.teresco.org" : "https://travelmapping.net"
        return URL(string: "\(host)/logs/users/\(username).log")!
    }

    static func run(username: String, category: RouteCategory) async throws -> Result {
        var request = URLRequest(url: logURL(username: username, category: category))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        let parsed = ListLogParser.parse(text)
        let fileUpdated = text.components(separatedBy: .newlines).first { $0.contains(" last updated: ") }

        let api: TravelMappingAPI = category == .rail ? .rail : .shared
        var routeCache: [String: RouteWaypoints?] = [:]
        func route(_ region: String, _ name: String) async -> RouteWaypoints? {
            let key = "\(region.uppercased()) \(name.uppercased())"
            if let cached = routeCache[key] { return cached }
            let found = await routeWaypoints(api: api, region: region, route: name)
            routeCache[key] = found
            return found
        }

        var fixes: [CheckupFix] = []
        for issue in parsed.issues {
            var fix = CheckupFix(issue: issue)
            guard var entry = ListEntry(issue.line) else { fixes.append(fix); continue }
            fix.target = entry

            switch issue.kind {
            case .deprecatedRoute(let old, let canonical):
                if entry.route1.caseInsensitiveCompare(old) == .orderedSame { entry.route1 = canonical }
                if entry.route2.caseInsensitiveCompare(old) == .orderedSame { entry.route2 = canonical }
                fix.target = entry
                await attachRoutes(&fix, entry: entry, route: route)
                if labelsExist(entry, in: fix.routes) {
                    fix.replacement = entry.text
                    fix.source = .automatic
                    fix.note = "Route renamed from \(old) to \(canonical); both waypoints are on the renamed route."
                } else {
                    fix.note = "Renamed to \(canonical), and some waypoints changed too — pick new ones."
                }
            case .missingWaypoints(let labels):
                await attachRoutes(&fix, entry: entry, route: route)
                // A label that only differs by case is a safe automatic fix
                var repaired = entry
                var allFixed = true
                for label in labels {
                    let key = entry.waypoint1 == label ? entry.routeKey1 : entry.routeKey2
                    guard let match = fix.routes[key]?.labels.first(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) else {
                        allFixed = false
                        continue
                    }
                    if repaired.waypoint1 == label { repaired.waypoint1 = match }
                    if repaired.waypoint2 == label { repaired.waypoint2 = match }
                }
                if allFixed && repaired != entry {
                    fix.replacement = repaired.text
                    fix.source = .automatic
                    fix.note = "Waypoint label capitalization changed."
                }
            case .unknownRoute, .zeroDistance:
                break
            }
            fixes.append(fix)
        }
        return Result(fixes: fixes, updates: parsed.updates, fileUpdated: fileUpdated)
    }

    static func labelsExist(_ entry: ListEntry, in routes: [String: RouteWaypoints]) -> Bool {
        guard let r1 = routes[entry.routeKey1], let r2 = routes[entry.routeKey2] else { return false }
        return r1.labels.contains(entry.waypoint1) && r2.labels.contains(entry.waypoint2)
    }

    private static func attachRoutes(_ fix: inout CheckupFix, entry: ListEntry,
                                      route: (String, String) async -> RouteWaypoints?) async {
        if let r = await route(entry.region1, entry.route1) { fix.routes[entry.routeKey1] = r }
        if let r = await route(entry.region2, entry.route2) { fix.routes[entry.routeKey2] = r }
    }

    /// TM roots are usually region + route with the first number padded to 3 digits
    /// ("NY I-81" → ny.i081, "WI US41" → wi.us041). Fall back to scanning the region.
    private static func routeWaypoints(api: TravelMappingAPI, region: String, route: String) async -> RouteWaypoints? {
        let listName = "\(region) \(route)"
        let guess = region.lowercased() + "." + paddedRouteRoot(route)
        if let result = try? await api.getRegionSegments(roots: [guess], traveler: "null", cacheTTL: 24 * 3600),
           let waypoints = build(root: guess, listName: listName, segments: result.segments, routes: result.routes) {
            return waypoints
        }
        guard let result = try? await api.getRegionSegments(region: region.uppercased(), traveler: "null", cacheTTL: 24 * 3600),
              let meta = result.routes.first(where: { $0.listName.caseInsensitiveCompare(listName) == .orderedSame }) else {
            return nil
        }
        return build(root: meta.root, listName: meta.listName, segments: result.segments, routes: result.routes)
    }

    private static func paddedRouteRoot(_ route: String) -> String {
        let lower = route.lowercased().replacingOccurrences(of: "-", with: "")
        let prefix = lower.prefix { !$0.isNumber }
        let rest = lower.dropFirst(prefix.count)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return lower }
        let padded = String(repeating: "0", count: max(0, 3 - digits.count)) + digits
        return prefix + padded + rest.dropFirst(digits.count)
    }

    private static func build(root: String, listName: String, segments: [TravelMappingAPI.MapSegment],
                              routes: [TravelMappingAPI.RouteMetadata]) -> RouteWaypoints? {
        let hops = segments.filter { $0.root == root }.sorted { $0.orderIndex < $1.orderIndex }
        guard !hops.isEmpty else { return nil }
        var labels: [String] = []
        var coordinates: [String: CLLocationCoordinate2D] = [:]
        func add(_ label: String, _ coordinate: CLLocationCoordinate2D) {
            guard !label.hasPrefix("+"), coordinates[label] == nil else { return }
            labels.append(label)
            coordinates[label] = coordinate
        }
        for hop in hops {
            add(hop.startName, hop.start)
            add(hop.endName, hop.end)
        }
        let name = routes.first { $0.root == root }?.listName ?? listName
        return RouteWaypoints(root: root, listName: name, labels: labels, coordinates: coordinates)
    }

    // MARK: AI suggestions

    /// Asks the user's AI provider for fixes to lines the checkup couldn't fix itself.
    /// Returns validated suggestions keyed by fix ID; anything naming a waypoint that isn't
    /// on the route is dropped.
    @MainActor
    static func suggestFixes(_ fixes: [CheckupFix], updates: [ListLogRouteUpdate]) async throws -> [String: (line: String, reason: String)] {
        let candidates = fixes.filter { $0.replacement == nil && $0.canPickWaypoints }
        guard !candidates.isEmpty else { return [:] }

        let system = """
        You fix entries in TravelMapping .list files. An entry is "Region Route Waypoint1 Waypoint2" \
        (or "Region1 Route1 Waypoint1 Region2 Route2 Waypoint2" when it crosses a region border) and marks \
        the stretch of that route between the two waypoints as traveled. When TravelMapping relabels, \
        renumbers, or moves waypoints, old entries stop working.

        For each problem, propose a corrected entry that covers the same stretch of road the traveler \
        originally meant. Use only waypoint labels from that route's current waypoint list, exactly as \
        written there. Use the route change notes to map old labels to new ones (for example, sequential \
        exit numbers renumbered to mileage-based ones). Keep the regions and route names unless a note \
        says the route itself changed. If you can't tell what the traveler meant, use confidence "low" \
        and say why instead of guessing.

        Reply with JSON only, no other text:
        {"fixes":[{"id":"<problem id>","line":"<corrected entry>","confidence":"high|medium|low","reason":"<one short sentence>"}]}
        """

        var prompt = ""
        for (n, fix) in candidates.enumerated() {
            prompt += "Problem \(n + 1) (id: \(fix.id))\n"
            prompt += "TravelMapping says: \(fix.issue.message)\n"
            prompt += "Entry: \(fix.issue.line)\n"
            if let target = fix.target, target.text != fix.issue.line {
                prompt += "The route was renamed; the corrected entry must use: \(target.routeKey1)\(target.multiRegion ? " / \(target.routeKey2)" : "")\n"
            }
            let roots = Set(fix.routes.values.map(\.root))
            let notes = fix.issue.routeNotes + updates.filter { roots.contains($0.root) }.map { "\($0.date): \($0.description)" }
            if !notes.isEmpty { prompt += "Route change notes:\n" + notes.map { "- \($0)" }.joined(separator: "\n") + "\n" }
            for (key, route) in fix.routes.sorted(by: { $0.key < $1.key }) {
                let points = route.labels.map { label -> String in
                    guard let c = route.coordinates[label] else { return label }
                    return "\(label) (\(String(format: "%.4f", c.latitude)), \(String(format: "%.4f", c.longitude)))"
                }
                prompt += "Current waypoints for \(key) in route order: " + points.joined(separator: "; ") + "\n"
            }
            prompt += "\n"
        }

        let answer = try await AIService.shared.complete(
            system: system,
            prompt: prompt,
            feature: "List checkup",
            sentSummary: "\(candidates.count) flagged line\(candidates.count == 1 ? "" : "s") from your list file, TravelMapping's notes about them, and the public waypoint lists for \(Set(candidates.flatMap { $0.routes.keys }).count) route(s)"
        )

        struct Reply: Decodable {
            struct Fix: Decodable { let id: String; let line: String; let confidence: String?; let reason: String? }
            let fixes: [Fix]
        }
        guard let json = extractJSON(answer), let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)) else {
            throw AIService.AIError.emptyResponse
        }

        var result: [String: (line: String, reason: String)] = [:]
        for suggestion in reply.fixes {
            guard let fix = candidates.first(where: { $0.id == suggestion.id }),
                  let entry = ListEntry(suggestion.line),
                  let original = fix.target,
                  entry.multiRegion == original.multiRegion,
                  // Same routes as the original line, and every waypoint really exists
                  entry.routeKey1 == original.routeKey1, entry.routeKey2 == original.routeKey2,
                  labelsExist(entry, in: fix.routes),
                  entry != original else { continue }
            let confidence = suggestion.confidence.map { " (\($0) confidence)" } ?? ""
            result[fix.id] = (entry.text, (suggestion.reason ?? "Suggested by AI") + confidence)
        }
        return result
    }

    /// Pulls the JSON object out of a reply that may wrap it in ``` fences or prose
    private static func extractJSON(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }
}
