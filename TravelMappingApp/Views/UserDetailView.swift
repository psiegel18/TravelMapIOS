import SwiftUI

struct UserDetailView: View {
    let username: String
    let dataService: DataService
    @State private var profile: UserProfile?
    @State private var isLoading = true
    @State private var selectedTab = 0

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading \(username)...")
            } else if let profile {
                VStack(spacing: 0) {
                    Picker("View", selection: $selectedTab) {
                        Label("List", systemImage: "list.bullet").tag(0)
                        Label("Map", systemImage: "map").tag(1)
                        Label("Stats", systemImage: "chart.bar").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    // Use ZStack to keep views alive and avoid zero-size layout
                    ZStack {
                        listTab(profile: profile)
                            .opacity(selectedTab == 0 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 0)

                        if selectedTab == 1 {
                            TravelMapView(
                                username: username,
                                dataService: dataService
                            )
                        }

                        StatisticsView(profile: profile)
                            .opacity(selectedTab == 2 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 2)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "doc.questionmark",
                    description: Text("No travel data found for \(username)")
                )
            }
        }
        .navigationTitle(username)
        .task {
            profile = await dataService.loadUserProfile(username: username)
            isLoading = false
        }
    }

    @ViewBuilder
    private func listTab(profile: UserProfile) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                statsHeader(profile: profile)
                categoryBreakdown(profile: profile)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func statsHeader(profile: UserProfile) -> some View {
        let regions = profile.allRegions
        let routes = profile.allRoutes

        VStack(spacing: 16) {
            HStack(spacing: 24) {
                StatBox(value: "\(regions.count)", label: "Regions", icon: "globe")
                StatBox(value: "\(routes.count)", label: "Routes", icon: "road.lanes")
                StatBox(value: "\(profile.totalSegments)", label: "Segments", icon: "point.topleft.down.to.point.bottomright.curvepath")
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func categoryBreakdown(profile: UserProfile) -> some View {
        ForEach(RouteCategory.allCases) { category in
            let regionGroups = profile.segmentsByRegion(for: category)
            if !regionGroups.isEmpty {
                CategorySectionView(
                    category: category,
                    regionGroups: regionGroups
                )
            }
        }
    }
}

struct StatBox: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
            Text(value)
                .font(.title.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CategorySectionView: View {
    let category: RouteCategory
    let regionGroups: [(region: String, segments: [TravelSegment])]
    @State private var isExpanded = true

    var totalSegments: Int {
        regionGroups.reduce(0) { $0 + $1.segments.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: category.systemImage)
                        .foregroundStyle(.blue)
                    Text(category.rawValue)
                        .font(.title3.bold())
                    Text("(\(totalSegments) segments)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(regionGroups, id: \.region) { group in
                    RegionGroupView(region: group.region, segments: group.segments)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct RegionGroupView: View {
    let region: String
    let segments: [TravelSegment]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(region)
                        .font(.headline)
                    Text("\(segments.count) segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(segments) { segment in
                    SegmentRowView(segment: segment)
                }
            }
        }
        .padding(.leading, 8)
    }
}

struct SegmentRowView: View {
    let segment: TravelSegment

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(segment.route)
                    .font(.subheadline.bold())
                Text("\(segment.waypoint1) → \(segment.waypoint2)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let r2 = segment.region2, r2 != segment.region1 {
                Spacer()
                Text("→ \(r2)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, 12)
    }
}
