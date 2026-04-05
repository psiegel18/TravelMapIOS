import SwiftUI
import MapKit

struct RoutePlannerView: View {
    @State private var startQuery = ""
    @State private var endQuery = ""
    @State private var startCoordinate: CLLocationCoordinate2D?
    @State private var endCoordinate: CLLocationCoordinate2D?
    @State private var route: MKRoute?
    @State private var tmSegments: [TravelMappingAPI.MapSegment] = []
    @State private var isCalculating = false
    @State private var errorMessage: String?
    @AppStorage("primaryUser") private var primaryUser = ""

    var body: some View {
        VStack(spacing: 0) {
            // Input fields
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "circle.fill").foregroundStyle(.green).font(.caption)
                    TextField("Start location", text: $startQuery)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.next)
                }
                HStack {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(.red).font(.caption)
                    TextField("End location", text: $endQuery)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit {
                            Task { await calculateRoute() }
                        }
                }

                Button {
                    Haptics.light()
                    Task { await calculateRoute() }
                } label: {
                    if isCalculating {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Find Route", systemImage: "arrow.triangle.turn.up.right.diamond")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(startQuery.isEmpty || endQuery.isEmpty || isCalculating)
            }
            .padding()

            // Map
            Map {
                if let route {
                    MapPolyline(route.polyline)
                        .stroke(.gray, lineWidth: 4)
                }

                // TM segments that overlap with the route
                ForEach(tmSegments) { seg in
                    MapPolyline(coordinates: [seg.start, seg.end])
                        .stroke(seg.isClinched ? .green : .blue, lineWidth: 3)
                }

                if let start = startCoordinate {
                    Marker("Start", coordinate: start).tint(.green)
                }
                if let end = endCoordinate {
                    Marker("End", coordinate: end).tint(.red)
                }
            }

            // Results summary
            if route != nil || errorMessage != nil {
                VStack(spacing: 4) {
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let route {
                        HStack {
                            Label(String(format: "%.1f mi", route.distance / 1609.34), systemImage: "road.lanes")
                            Spacer()
                            Label(formatTime(route.expectedTravelTime), systemImage: "clock")
                            Spacer()
                            Label("\(tmSegments.count) TM segments", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                        .font(.caption)
                        if !primaryUser.isEmpty {
                            let clinched = tmSegments.filter(\.isClinched).count
                            Text("\(clinched)/\(tmSegments.count) already traveled")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .navigationTitle("Route Planner")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func calculateRoute() async {
        isCalculating = true
        errorMessage = nil
        route = nil
        tmSegments = []

        do {
            // Geocode start and end
            let startItems = try await MKLocalSearch(request: searchRequest(for: startQuery)).start()
            let endItems = try await MKLocalSearch(request: searchRequest(for: endQuery)).start()

            guard let start = startItems.mapItems.first?.placemark.coordinate,
                  let end = endItems.mapItems.first?.placemark.coordinate else {
                errorMessage = "Could not find one of the locations"
                isCalculating = false
                return
            }

            startCoordinate = start
            endCoordinate = end

            // Get directions
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
            request.transportType = .automobile

            let directions = MKDirections(request: request)
            let response = try await directions.calculate()
            route = response.routes.first

            // Find TM segments along the route using bounding box
            if route != nil {
                await findOverlappingSegments(start: start, end: end)
            }
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }

        isCalculating = false
    }

    private func searchRequest(for query: String) -> MKLocalSearch.Request {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        return request
    }

    private func findOverlappingSegments(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D) async {
        let minLat = min(start.latitude, end.latitude) - 0.1
        let maxLat = max(start.latitude, end.latitude) + 0.1
        let minLng = min(start.longitude, end.longitude) - 0.1
        let maxLng = max(start.longitude, end.longitude) + 0.1

        do {
            let result = try await TravelMappingAPI.shared.getVisibleSegments(
                traveler: primaryUser.isEmpty ? "" : primaryUser,
                minLat: minLat,
                maxLat: maxLat,
                minLng: minLng,
                maxLng: maxLng
            )

            // Filter segments that are near the route polyline
            guard let routePolyline = route?.polyline else { return }
            tmSegments = result.segments.filter { seg in
                isSegmentNearRoute(seg: seg, polyline: routePolyline)
            }
        } catch {
            // Ignore errors, just don't show TM segments
        }
    }

    private func isSegmentNearRoute(seg: TravelMappingAPI.MapSegment, polyline: MKPolyline) -> Bool {
        // Check if segment midpoint is within 500m of the route
        let midLat = (seg.start.latitude + seg.end.latitude) / 2
        let midLng = (seg.start.longitude + seg.end.longitude) / 2
        let mid = CLLocation(latitude: midLat, longitude: midLng)

        let pointCount = polyline.pointCount
        let points = polyline.points()

        for i in 0..<pointCount {
            let coord = points[i].coordinate
            let routePt = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            if routePt.distance(from: mid) < 500 {
                return true
            }
        }
        return false
    }
}
