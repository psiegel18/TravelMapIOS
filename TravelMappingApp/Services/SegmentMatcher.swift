import Foundation
import CoreLocation

/// Matches GPS coordinates to TravelMapping route segments using a spatial grid index.
class SegmentMatcher {

    // MARK: - Spatial Grid

    private struct GridCell: Hashable {
        let latBucket: Int
        let lngBucket: Int
    }

    private static let cellSize: Double = 0.01 // ~1.1 km

    private var segmentCache: [Int: TravelMappingAPI.MapSegment] = [:]
    private var spatialGrid: [GridCell: [Int]] = [:]  // cell -> segment IDs
    private var currentBBox: (minLat: Double, maxLat: Double, minLng: Double, maxLng: Double)?

    // MARK: - Tracking State

    private var currentSegmentID: Int?
    private var currentSegmentEntryTime: Date?
    private var consecutiveMatchCount: Int = 0
    private(set) var matchedSegments: [MatchedSegment] = []

    private static let matchThreshold: CLLocationDistance = 100  // meters
    private static let minConsecutiveMatches = 3
    private static let bboxPadding: Double = 0.5  // ~35 miles
    private static let refetchThreshold: Double = 0.125 // ~25% of bbox

    // MARK: - Public API

    /// Process a GPS point and return the matched segment (if any).
    func processPoint(_ point: GPSPoint) -> TravelMappingAPI.MapSegment? {
        guard point.horizontalAccuracy < 200 else { return nil } // filter bad fixes

        let cell = gridCell(for: point.coordinate)
        let neighborCells = neighbors(of: cell)

        var bestSegment: TravelMappingAPI.MapSegment?
        var bestDistance: CLLocationDistance = .greatestFiniteMagnitude

        for neighborCell in neighborCells {
            guard let segmentIDs = spatialGrid[neighborCell] else { continue }
            for segID in segmentIDs {
                guard let seg = segmentCache[segID] else { continue }
                let dist = perpendicularDistance(
                    point: point.coordinate,
                    segStart: seg.start,
                    segEnd: seg.end
                )
                if dist < bestDistance {
                    bestDistance = dist
                    bestSegment = seg
                }
            }
        }

        guard bestDistance < Self.matchThreshold, let matched = bestSegment else {
            // No match — if we were tracking a segment, finalize it
            if currentSegmentID != nil {
                finalizeCurrentSegment(at: point.timestamp)
            }
            consecutiveMatchCount = 0
            return nil
        }

        // Same segment as before
        if matched.id == currentSegmentID {
            consecutiveMatchCount += 1
            return matched
        }

        // New segment — require consecutive matches to avoid jitter
        if consecutiveMatchCount < Self.minConsecutiveMatches - 1 {
            consecutiveMatchCount += 1
            return segmentCache[currentSegmentID ?? -1]
        }

        // Commit to new segment
        if currentSegmentID != nil {
            finalizeCurrentSegment(at: point.timestamp)
        }

        currentSegmentID = matched.id
        currentSegmentEntryTime = point.timestamp
        consecutiveMatchCount = 1

        return matched
    }

    /// Check if we need to fetch new segment data from the API.
    func needsRefetch(for coordinate: CLLocationCoordinate2D) -> Bool {
        guard let bbox = currentBBox else { return true }

        let latMargin = (bbox.maxLat - bbox.minLat) * Self.refetchThreshold
        let lngMargin = (bbox.maxLng - bbox.minLng) * Self.refetchThreshold

        return coordinate.latitude < bbox.minLat + latMargin ||
               coordinate.latitude > bbox.maxLat - latMargin ||
               coordinate.longitude < bbox.minLng + lngMargin ||
               coordinate.longitude > bbox.maxLng - lngMargin
    }

    /// Compute the bounding box to fetch for a given center point.
    func boundingBox(for coordinate: CLLocationCoordinate2D) -> (minLat: Double, maxLat: Double, minLng: Double, maxLng: Double) {
        let pad = Self.bboxPadding
        return (
            coordinate.latitude - pad,
            coordinate.latitude + pad,
            coordinate.longitude - pad,
            coordinate.longitude + pad
        )
    }

    /// Update the segment cache with new data from the API.
    func updateCache(segments: [TravelMappingAPI.MapSegment], bbox: (minLat: Double, maxLat: Double, minLng: Double, maxLng: Double)) {
        currentBBox = bbox

        for seg in segments {
            if segmentCache[seg.id] == nil {
                segmentCache[seg.id] = seg
                indexSegment(seg)
            }
        }
    }

    /// Finalize tracking — flush any in-progress segment.
    func finalizeTrip() -> [MatchedSegment] {
        if currentSegmentID != nil {
            finalizeCurrentSegment(at: Date())
        }
        return matchedSegments
    }

    // MARK: - Private

    private func finalizeCurrentSegment(at exitTime: Date) {
        guard let segID = currentSegmentID,
              let seg = segmentCache[segID],
              let entryTime = currentSegmentEntryTime else { return }

        let matched = MatchedSegment(
            id: UUID(),
            root: seg.root,
            listName: seg.root, // will be resolved later
            startWaypoint: seg.startName,
            endWaypoint: seg.endName,
            entryTime: entryTime,
            exitTime: exitTime,
            direction: .forward, // simplified — could detect from GPS course
            confidence: 0.8
        )

        // Avoid duplicate consecutive segments
        if let last = matchedSegments.last,
           last.root == matched.root &&
           last.startWaypoint == matched.startWaypoint &&
           last.endWaypoint == matched.endWaypoint {
            // Update exit time of existing
            matchedSegments[matchedSegments.count - 1].exitTime = exitTime
        } else {
            matchedSegments.append(matched)
        }

        currentSegmentID = nil
        currentSegmentEntryTime = nil
    }

    private func gridCell(for coord: CLLocationCoordinate2D) -> GridCell {
        GridCell(
            latBucket: Int(floor(coord.latitude / Self.cellSize)),
            lngBucket: Int(floor(coord.longitude / Self.cellSize))
        )
    }

    private func neighbors(of cell: GridCell) -> [GridCell] {
        var cells: [GridCell] = []
        for dLat in -1...1 {
            for dLng in -1...1 {
                cells.append(GridCell(latBucket: cell.latBucket + dLat, lngBucket: cell.lngBucket + dLng))
            }
        }
        return cells
    }

    private func indexSegment(_ seg: TravelMappingAPI.MapSegment) {
        // Add segment to all grid cells it touches
        let startCell = gridCell(for: seg.start)
        let endCell = gridCell(for: seg.end)

        let minLat = min(startCell.latBucket, endCell.latBucket)
        let maxLat = max(startCell.latBucket, endCell.latBucket)
        let minLng = min(startCell.lngBucket, endCell.lngBucket)
        let maxLng = max(startCell.lngBucket, endCell.lngBucket)

        for lat in minLat...maxLat {
            for lng in minLng...maxLng {
                let cell = GridCell(latBucket: lat, lngBucket: lng)
                spatialGrid[cell, default: []].append(seg.id)
            }
        }
    }

    /// Perpendicular distance from a point to a line segment, in meters.
    private func perpendicularDistance(
        point: CLLocationCoordinate2D,
        segStart: CLLocationCoordinate2D,
        segEnd: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        // Use equirectangular projection (fast, accurate for short distances)
        let cosLat = cos(point.latitude * .pi / 180)

        let px = (point.longitude - segStart.longitude) * cosLat
        let py = point.latitude - segStart.latitude
        let dx = (segEnd.longitude - segStart.longitude) * cosLat
        let dy = segEnd.latitude - segStart.latitude

        let segLenSq = dx * dx + dy * dy
        guard segLenSq > 0 else {
            // Degenerate segment (start == end)
            let dLat = point.latitude - segStart.latitude
            let dLng = (point.longitude - segStart.longitude) * cosLat
            return sqrt(dLat * dLat + dLng * dLng) * 111_320
        }

        // Project point onto segment line, clamped to [0,1]
        let t = max(0, min(1, (px * dx + py * dy) / segLenSq))

        let closestX = segStart.longitude * cosLat + t * dx
        let closestY = segStart.latitude + t * dy

        let distX = point.longitude * cosLat - closestX
        let distY = point.latitude - closestY

        return sqrt(distX * distX + distY * distY) * 111_320 // degrees to meters
    }
}
