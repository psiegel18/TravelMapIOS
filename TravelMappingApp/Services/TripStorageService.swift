import Foundation

actor TripStorageService {
    static let shared = TripStorageService()

    private let tripsDir: URL
    let isUsingICloud: Bool

    init() {
        // Try iCloud Drive container first
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents")
            .appendingPathComponent("Trips", isDirectory: true) {
            tripsDir = iCloudURL
            isUsingICloud = true
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            tripsDir = docs.appendingPathComponent("Trips", isDirectory: true)
            isUsingICloud = false
        }
        try? FileManager.default.createDirectory(at: tripsDir, withIntermediateDirectories: true)
    }

    func save(_ trip: RoadTrip) throws {
        let data = try JSONEncoder().encode(trip)
        let fileURL = tripsDir.appendingPathComponent("\(trip.id.uuidString).json")
        try data.write(to: fileURL)
    }

    func load(id: UUID) throws -> RoadTrip {
        let fileURL = tripsDir.appendingPathComponent("\(id.uuidString).json")
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(RoadTrip.self, from: data)
    }

    func listTrips() throws -> [RoadTrip] {
        let files = try FileManager.default.contentsOfDirectory(at: tripsDir, includingPropertiesForKeys: [.contentModificationDateKey])
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

    func delete(id: UUID) throws {
        let jsonURL = tripsDir.appendingPathComponent("\(id.uuidString).json")
        let listURL = tripsDir.appendingPathComponent("\(id.uuidString).list")
        try? FileManager.default.removeItem(at: jsonURL)
        try? FileManager.default.removeItem(at: listURL)
    }

    /// Export the trip's matched segments as a .list file, return the file URL.
    func exportListFile(for trip: RoadTrip) throws -> URL {
        let content = ListFileGenerator.generate(from: trip.matchedSegments, tripName: trip.name)
        let fileURL = tripsDir.appendingPathComponent("\(trip.id.uuidString).list")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
