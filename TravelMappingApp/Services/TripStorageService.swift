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
            SentrySDK.capture(error: error)
            return nil
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

    var id: String { "\(root)|\(startWaypoint)|\(endWaypoint)|\(status.rawValue)" }
    var line: ListLine { ListLine(region: region, route: route, waypoint1: startWaypoint, waypoint2: endWaypoint) }
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
                tripIDs: b.tripIDs
            )
        }
        return TripLogAnalysis(ranges: ranges, unresolvedCount: unresolved)
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
