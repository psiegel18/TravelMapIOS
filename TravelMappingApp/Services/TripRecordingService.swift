import Sentry
import Foundation
import CoreLocation
import Combine
import ActivityKit

/// Orchestrates road trip GPS recording, segment matching, and persistence.
@MainActor
class TripRecordingService: NSObject, ObservableObject {
    static let shared = TripRecordingService()

    // MARK: - Published State

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var currentTrip: RoadTrip?
    @Published var currentSegmentName: String?
    @Published var pointCount: Int = 0
    @Published var matchedCount: Int = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var currentAccuracy: Double = -1  // meters, -1 = unknown
    @Published var currentSpeed: Double = 0       // m/s
    @Published var totalDistance: Double = 0      // meters
    @Published var matchedCoordinates: [(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D)] = []

    // MARK: - Private

    private let locationManager = CLLocationManager()
    private let segmentMatcher = SegmentMatcher()
    private var timer: Timer?
    private var saveTimer: Timer?
    private var lastFetchLocation: CLLocationCoordinate2D?
    private var liveActivity: Activity<RoadTripAttributes>?

    // MARK: - Init

    @Published var orphanedTrip: RoadTrip?

    override init() {
        super.init()
        locationManager.delegate = self

        // Crash recovery: look for unfinished trips from a previous session
        Task { @MainActor in
            await checkForOrphanedTrip()
        }
    }

    /// Maximum age of an orphaned trip eligible for silent auto-resume.
    /// Older trips fall back to the keep/discard dialog so we don't surprise the user
    /// by re-arming GPS for a trip they forgot about days ago.
    private static let autoResumeMaxAge: TimeInterval = 12 * 60 * 60

    private func checkForOrphanedTrip() async {
        guard let trips = try? await TripStorageService.shared.listTrips() else { return }
        guard let orphan = trips.first(where: { $0.status == .recording }) else { return }

        let age = Date().timeIntervalSince(orphan.startDate)
        let status = locationManager.authorizationStatus
        let canResume = (status == .authorizedAlways || status == .authorizedWhenInUse)
            && age >= 0
            && age < Self.autoResumeMaxAge

        if canResume {
            resumeFromOrphan(orphan)
        } else {
            // Fall back to the existing keep/discard dialog
            orphanedTrip = orphan
        }
    }

    /// Restore an in-progress trip after the app was killed (or evicted by the OS) mid-recording.
    /// Rebinds in-memory state to what was already on disk, restarts location updates and timers,
    /// re-seeds the segment matcher, and reattaches the still-running Live Activity.
    private func resumeFromOrphan(_ trip: RoadTrip) {
        currentTripType = trip.tripType
        currentTrip = trip
        isRecording = true
        isPaused = false
        pointCount = trip.rawPoints.count
        matchedCount = trip.matchedSegments.count
        elapsedTime = Date().timeIntervalSince(trip.startDate)
        currentSegmentName = nil
        currentAccuracy = -1
        currentSpeed = 0
        totalDistance = Self.totalDistance(of: trip.rawPoints)
        matchedCoordinates = []

        segmentMatcher.restoreMatchedSegments(trip.matchedSegments)

        configureLocationManager(for: trip.tripType)
        locationManager.startUpdatingLocation()

        rebindOrStartLiveActivity(tripName: trip.name, startDate: trip.startDate)

        startTimers(tripStartDate: trip.startDate)

        SentrySDK.logger.info("Trip resumed from orphan", attributes: [
            "tripType": trip.tripType == .rail ? "rail" : "road",
            "tripName": trip.name,
            "elapsedAtResume": elapsedTime,
            "pointsAtResume": pointCount,
            "matchedAtResume": matchedCount,
        ])
        updateTripContext(isRecording: true, isPaused: false, tripType: trip.tripType)
    }

    private static func totalDistance(of points: [GPSPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var total: Double = 0
        var prev = CLLocation(latitude: points[0].latitude, longitude: points[0].longitude)
        for i in 1..<points.count {
            let next = CLLocation(latitude: points[i].latitude, longitude: points[i].longitude)
            total += next.distance(from: prev)
            prev = next
        }
        return total
    }

    /// Finalize a trip that was interrupted by a crash or force-quit
    func finalizeOrphanedTrip() async {
        guard var trip = orphanedTrip else { return }
        trip.status = .completed
        trip.endDate = trip.rawPoints.last.map { $0.timestamp } ?? Date()
        try? await TripStorageService.shared.save(trip)
        orphanedTrip = nil
    }

    /// Discard an orphaned trip
    func discardOrphanedTrip() async {
        guard let trip = orphanedTrip else { return }
        try? await TripStorageService.shared.delete(id: trip.id)
        orphanedTrip = nil
    }

    // MARK: - Public API

    private(set) var currentTripType: TripType = .road

    func startTrip(name: String? = nil, tripType: TripType = .road) {
        guard !isRecording else { return }

        currentTripType = tripType
        // System permission dialog blocks the main thread — pause hang tracking so Sentry
        // doesn't report it as a false-positive app hang. Resume after the dialog has
        // had time to be shown and dismissed.
        SentrySDK.pauseAppHangTracking()
        locationManager.requestAlwaysAuthorization()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            SentrySDK.resumeAppHangTracking()
        }
        configureLocationManager(for: tripType)

        var trip = RoadTrip(name: name, tripType: tripType)
        trip.status = .recording
        currentTrip = trip
        isRecording = true
        isPaused = false
        pointCount = 0
        matchedCount = 0
        elapsedTime = 0
        currentSegmentName = nil
        currentAccuracy = -1
        currentSpeed = 0
        totalDistance = 0

        locationManager.startUpdatingLocation()
        startLiveActivity(tripName: trip.name, startDate: trip.startDate)
        Haptics.success()
        SentrySDK.logger.info("Trip started", attributes: [
            "tripType": tripType == .rail ? "rail" : "road",
            "tripName": trip.name,
        ])
        updateTripContext(isRecording: true, isPaused: false, tripType: tripType)

        startTimers(tripStartDate: trip.startDate)
    }

    private func configureLocationManager(for tripType: TripType) {
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 50
        locationManager.activityType = tripType == .rail ? .otherNavigation : .automotiveNavigation
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.showsBackgroundLocationIndicator = true
    }

    private func startTimers(tripStartDate: Date) {
        timer?.invalidate()
        saveTimer?.invalidate()

        // Elapsed time timer + Watch sync
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let trip = self.currentTrip else { return }
                self.elapsedTime = Date().timeIntervalSince(tripStartDate)
                WatchSyncService.shared.sendTripUpdate(
                    tripName: trip.name,
                    elapsedTime: self.elapsedTime,
                    speed: self.currentSpeed,
                    distance: self.totalDistance,
                    matchedCount: self.matchedCount,
                    pointCount: self.pointCount,
                    currentSegment: self.currentSegmentName,
                    isPaused: self.isPaused,
                    tripType: self.currentTripType == .rail ? "rail" : "road"
                )
                // Refresh trip_state context every 10 seconds so mid-trip Sentry events
                // show a reasonably fresh pointCount/matchedCount rather than 0 from start.
                if Int(self.elapsedTime) % 10 == 0 {
                    self.updateTripContext(isRecording: true, isPaused: self.isPaused, tripType: self.currentTripType)
                }
            }
        }

        // Auto-save every 60 seconds
        saveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.saveCurrentTrip()
            }
        }
    }

    func pauseTrip() {
        guard isRecording, !isPaused else { return }
        locationManager.stopUpdatingLocation()
        isPaused = true
        currentSegmentName = "Paused"
        Haptics.light()
        SentrySDK.logger.info("Trip paused", attributes: ["elapsedTime": elapsedTime])
        updateTripContext(isRecording: true, isPaused: true, tripType: currentTripType)
    }

    func resumeTrip() {
        guard isRecording, isPaused else { return }
        locationManager.startUpdatingLocation()
        isPaused = false
        Haptics.light()
        SentrySDK.logger.info("Trip resumed", attributes: ["elapsedTime": elapsedTime])
        updateTripContext(isRecording: true, isPaused: false, tripType: currentTripType)
    }

    private func updateTripContext(isRecording: Bool, isPaused: Bool, tripType: TripType) {
        SentrySDK.configureScope { [weak self] scope in
            guard let self else { return }
            scope.setContext(value: [
                "isRecording": isRecording,
                "isPaused": isPaused,
                "tripType": tripType == .rail ? "rail" : "road",
                "elapsedTime": self.elapsedTime,
                "pointCount": self.pointCount,
                "matchedCount": self.matchedCount,
            ], key: "trip_state")
            scope.setTag(value: isRecording ? "true" : "false", key: "trip_active")
        }
    }

    func stopTrip() {
        guard isRecording, var trip = currentTrip else { return }

        locationManager.stopUpdatingLocation()
        timer?.invalidate()
        saveTimer?.invalidate()
        timer = nil
        saveTimer = nil
        WatchSyncService.shared.clearTripStatus()

        // Finalize matching
        trip.matchedSegments = segmentMatcher.finalizeTrip()
        trip.endDate = Date()
        trip.status = .completed
        trip.rawPoints = currentTrip?.rawPoints ?? []

        currentTrip = trip
        isRecording = false
        matchedCount = trip.matchedSegments.count

        stopLiveActivity()
        Haptics.success()
        SentrySDK.logger.info("Trip stopped", attributes: [
            "tripType": trip.tripType == .rail ? "rail" : "road",
            "duration": elapsedTime,
            "totalDistance": totalDistance,
            "pointCount": pointCount,
            "matchedSegments": trip.matchedSegments.count,
        ])
        SentrySDK.configureScope { scope in
            scope.setContext(value: ["isRecording": false], key: "trip_state")
            scope.setTag(value: "false", key: "trip_active")
        }

        // Save final state
        Task {
            try? await TripStorageService.shared.save(trip)
            _ = try? await TripStorageService.shared.exportListFile(for: trip)
        }
    }

    var elapsedFormatted: String {
        let hours = Int(elapsedTime) / 3600
        let minutes = (Int(elapsedTime) % 3600) / 60
        let seconds = Int(elapsedTime) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Live Activity

    private func startLiveActivity(tripName: String, startDate: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = RoadTripAttributes(tripName: tripName, startDate: startDate)
        let state = RoadTripAttributes.ContentState(
            elapsedTime: 0,
            currentRoad: "",
            matchedSegments: 0,
            gpsPoints: 0
        )

        do {
            liveActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            SentrySDK.capture(error: error)
        }
    }

    /// On resume, locate the Live Activity that the previous app session started so we can
    /// keep updating it (and end it when the user stops). If the system has already cleared it,
    /// start a fresh one.
    private func rebindOrStartLiveActivity(tripName: String, startDate: Date) {
        let activities = Activity<RoadTripAttributes>.activities
        let match = activities.first {
            $0.attributes.tripName == tripName
                && abs($0.attributes.startDate.timeIntervalSince(startDate)) < 1
        } ?? activities.first
        if let match {
            liveActivity = match
        } else {
            startLiveActivity(tripName: tripName, startDate: startDate)
        }
    }

    private func updateLiveActivity() {
        guard let activity = liveActivity else { return }

        let state = RoadTripAttributes.ContentState(
            elapsedTime: elapsedTime,
            currentRoad: currentSegmentName ?? "",
            matchedSegments: matchedCount,
            gpsPoints: pointCount
        )

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    private func stopLiveActivity() {
        guard let activity = liveActivity else { return }

        let finalState = RoadTripAttributes.ContentState(
            elapsedTime: elapsedTime,
            currentRoad: "Trip ended",
            matchedSegments: matchedCount,
            gpsPoints: pointCount
        )

        Task {
            await activity.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .after(.now + 300))
        }
        liveActivity = nil
    }

    // MARK: - Private

    private func saveCurrentTrip() {
        guard let trip = currentTrip else { return }
        Task {
            try? await TripStorageService.shared.save(trip)
        }
    }

    private func fetchSegmentsIfNeeded(near coordinate: CLLocationCoordinate2D) {
        guard segmentMatcher.needsRefetch(for: coordinate) else { return }

        // Avoid re-fetching for same area
        if let last = lastFetchLocation {
            let dist = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            if dist < 5000 { return } // less than 5km since last fetch
        }

        lastFetchLocation = coordinate
        let bbox = segmentMatcher.boundingBox(for: coordinate)

        Task {
            do {
                let api = currentTripType == .rail ? TravelMappingAPI.rail : TravelMappingAPI.shared
                let result = try await api.getVisibleSegments(
                    traveler: "",
                    minLat: bbox.minLat,
                    maxLat: bbox.maxLat,
                    minLng: bbox.minLng,
                    maxLng: bbox.maxLng
                )
                segmentMatcher.updateCache(segments: result.segments, bbox: bbox)
            } catch {
                SentrySDK.capture(error: error)
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension TripRecordingService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations {
                guard location.horizontalAccuracy < 200 else { continue }
                guard !isPaused else { continue }

                // Update live stats
                currentAccuracy = location.horizontalAccuracy
                currentSpeed = max(0, location.speed)

                // Compute distance from last point
                if let last = currentTrip?.rawPoints.last {
                    let lastLoc = CLLocation(latitude: last.latitude, longitude: last.longitude)
                    totalDistance += location.distance(from: lastLoc)
                }

                let gpsPoint = GPSPoint(from: location)
                currentTrip?.rawPoints.append(gpsPoint)
                pointCount = currentTrip?.rawPoints.count ?? 0

                // Fetch segments if needed
                fetchSegmentsIfNeeded(near: location.coordinate)

                // Match point to segment
                if let matched = segmentMatcher.processPoint(gpsPoint) {
                    currentSegmentName = "\(matched.root) (\(matched.startName) → \(matched.endName))"
                    matchedCount = segmentMatcher.matchedSegments.count
                    matchedCoordinates = segmentMatcher.matchedSegmentCoordinates
                }

                // Update Live Activity every 10 points
                if pointCount % 10 == 0 {
                    updateLiveActivity()
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Skip expected/transient CL errors: denied permission, temporary location unknown, region monitoring denied.
        if let clError = error as? CLError,
           [.denied, .locationUnknown, .regionMonitoringDenied].contains(clError.code) {
            return
        }
        SentrySDK.capture(error: error)
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            currentSegmentName = "Paused (stationary)"
        }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            currentSegmentName = "Resumed tracking"
        }
    }
}
