import AppIntents

struct StartRoadTripIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Road Trip"
    static var description = IntentDescription("Begin recording a new road trip with GPS tracking")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Trip Name")
    var tripName: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = TripRecordingService.shared
        // startTrip() no-ops while recording — don't claim we started a new trip
        guard !service.isRecording else {
            let currentName = service.currentTrip?.name ?? "a road trip"
            return .result(dialog: "Already recording \"\(currentName)\". Stop it before starting a new trip.")
        }

        let name = tripName ?? "Trip on \(Date().formatted(date: .abbreviated, time: .omitted))"
        service.startTrip(name: name)
        return .result(dialog: "Started recording \"\(name)\". Drive safe!")
    }
}

struct StopRoadTripIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Road Trip"
    static var description = IntentDescription("Stop recording the current road trip")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = TripRecordingService.shared

        if !service.isRecording {
            // Cold launch: the async orphan scan may not have finished yet, so check
            // disk directly — otherwise we'd reply "nothing recording" while the
            // orphaned trip then silently auto-resumes.
            var orphan = service.orphanedTrip
            if orphan == nil {
                orphan = (try? await TripStorageService.shared.listTrips())?.first(where: { $0.status == .recording })
            }
            // Re-check: the orphan scan may have auto-resumed the trip while we read disk;
            // if so, fall through to the normal stop path below.
            if !service.isRecording, let orphan {
                service.orphanedTrip = orphan
                await service.finalizeOrphanedTrip()
                return .result(dialog: "Road trip stopped. Recorded \(orphan.rawPoints.count.formatted()) GPS points and matched \(orphan.matchedSegments.count.formatted()) route segments.")
            }
        }

        guard service.isRecording else {
            return .result(dialog: "No road trip is currently being recorded.")
        }

        let pointCount = service.pointCount
        let matchedCount = service.matchedCount
        service.stopTrip()

        return .result(dialog: "Road trip stopped. Recorded \(pointCount.formatted()) GPS points and matched \(matchedCount.formatted()) route segments.")
    }
}

struct TravelMappingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRoadTripIntent(),
            phrases: [
                "Start a road trip in \(.applicationName)",
                "Begin tracking in \(.applicationName)",
                "Record a road trip with \(.applicationName)"
            ],
            shortTitle: "Start Road Trip",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: StopRoadTripIntent(),
            phrases: [
                "Stop road trip in \(.applicationName)",
                "End tracking in \(.applicationName)",
                "Stop recording in \(.applicationName)"
            ],
            shortTitle: "Stop Road Trip",
            systemImageName: "stop.circle"
        )
    }
}
