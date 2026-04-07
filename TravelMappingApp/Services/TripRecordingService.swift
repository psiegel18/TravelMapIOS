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

    private func checkForOrphanedTrip() async {
        guard let trips = try? await TripStorageService.shared.listTrips() else { return }
        if let orphan = trips.first(where: { $0.status == .recording }) {
            orphanedTrip = orphan
        }
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
        locationManager.requestAlwaysAuthorization()
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 50
        locationManager.activityType = tripType == .rail ? .otherNavigation : .automotiveNavigation
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.showsBackgroundLocationIndicator = true

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

        // Elapsed time timer + Watch sync
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsedTime = Date().timeIntervalSince(trip.startDate)
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
    }

    func resumeTrip() {
        guard isRecording, isPaused else { return }
        locationManager.startUpdatingLocation()
        isPaused = false
        Haptics.light()
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
            print("Failed to start Live Activity: \(error)")
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
                print("Failed to fetch segments: \(error)")
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
        print("Location error: \(error)")
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
