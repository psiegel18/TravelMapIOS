import Foundation
import Sentry

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
        try data.write(to: fileURL)
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
            .filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return dateA > dateB
            }

        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(RoadTrip.self, from: data)
        }
    }

    func delete(id: UUID) async throws {
        let dir = await tripsDirectory()
        let jsonURL = dir.appendingPathComponent("\(id.uuidString).json")
        let listURL = dir.appendingPathComponent("\(id.uuidString).list")
        try? FileManager.default.removeItem(at: jsonURL)
        try? FileManager.default.removeItem(at: listURL)
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
