import AppIntents

struct StartRoadTripIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Road Trip"
    static var description = IntentDescription("Begin recording a new road trip with GPS tracking")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Trip Name")
    var tripName: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = tripName ?? "Trip on \(Date().formatted(date: .abbreviated, time: .omitted))"
        TripRecordingService.shared.startTrip(name: name)
        return .result(dialog: "Started recording \"\(name)\". Drive safe!")
    }
}

struct StopRoadTripIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Road Trip"
    static var description = IntentDescription("Stop recording the current road trip")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard TripRecordingService.shared.isRecording else {
            return .result(dialog: "No road trip is currently being recorded.")
        }

        let pointCount = TripRecordingService.shared.pointCount
        let matchedCount = TripRecordingService.shared.matchedCount
        TripRecordingService.shared.stopTrip()

        return .result(dialog: "Road trip stopped. Recorded \(pointCount) GPS points and matched \(matchedCount) route segments.")
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
