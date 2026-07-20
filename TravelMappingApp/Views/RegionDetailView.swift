import SwiftUI

struct RegionDetailView: View {
    let region: String
    let username: String
    @State private var routes: [StatisticsView.RouteInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @AppStorage("useMiles") private var useMiles = true

    private var unit: String { useMiles ? "mi" : "km" }
    private func convert(_ miles: Double) -> Double { useMiles ? miles : miles * 1.60934 }

    /// Full region name ("Illinois" for "IL") when the static catalog knows it.
    private var regionFullName: String? { GetStartedView.regionName(for: region) }

    private var numFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f
    }

    private func formatNumber(_ n: Double) -> String {
        numFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    var body: some View {
        Group {
            if isLoading {
                loadingState
            } else if let error = errorMessage {
                ErrorView(message: error) {
                    await load()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerView
                        overviewCard
                        almostThereCard
                        longestClinchedCard
                        allRoutesCard
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(regionFullName ?? region)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    // MARK: Header — full region name + code (audit §7)

    private var headerView: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(regionFullName ?? region)
                .font(.system(size: 30, weight: .heavy))
            if regionFullName != nil {
                Text(region)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TMDesign.tertiaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Loading — skeleton rows so layout doesn't jump (audit §11)

    private var loadingState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Loading \(regionFullName ?? region) routes…")
                    .font(.system(size: 13))
                    .foregroundStyle(TMDesign.tertiaryText)
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { _ in
                        TMSkeletonRow()
                    }
                }
                .padding(16)
                .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding()
        }
        .accessibilityLabel("Loading \(regionFullName ?? region) routes")
    }

    // MARK: Overview — completion ring card (audit §7)

    private var overviewCard: some View {
        let total = routes.reduce(0.0) { $0 + $1.mileage }
        let clinched = routes.reduce(0.0) { $0 + $1.clinchedMileage }
        let fraction = total > 0 ? clinched / total : 0
        let clinchedCount = routes.filter(\.isClinched).count

        return HStack(spacing: 20) {
            TMCompletionRing(
                fraction: fraction,
                diameter: 100,
                lineWidth: 13,
                percentFont: 24
            )

            VStack(spacing: 0) {
                overviewRow(label: "Traveled", value: "\(formatNumber(convert(clinched))) \(unit)")
                Rectangle().fill(TMDesign.hairline).frame(height: 1)
                overviewRow(label: "Routes", value: routes.count.formatted())
                Rectangle().fill(TMDesign.hairline).frame(height: 1)
                overviewRow(label: "Clinched", value: clinchedCount.formatted(), valueColor: TMDesign.clinched)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func overviewRow(label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(TMDesign.secondaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: "Almost there" amber callout (audit §7)

    @ViewBuilder
    private var almostThereCard: some View {
        let almost = routes
            .filter { $0.clinchedMileage > 0 && !$0.isClinched }
            .sorted { $0.remainingMileage < $1.remainingMileage }
            .prefix(3)

        if !almost.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .font(.system(size: 15, weight: .bold))
                    Text("Almost there — \(almost.count.formatted()) to clinch")
                        .font(.system(size: 15, weight: .heavy))
                        .monospacedDigit()
                }
                .foregroundStyle(TMDesign.amberChipFG)
                .accessibilityAddTraits(.isHeader)

                ForEach(Array(almost)) { route in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(route.listName)
                                .font(.system(size: 15, weight: .bold))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(formatNumber(convert(route.remainingMileage))) \(unit) left")
                                .font(.system(size: 13, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(TMDesign.amberChipFG)
                        }
                        MiniBar(
                            fraction: route.mileage > 0 ? route.clinchedMileage / route.mileage : 0,
                            height: 6,
                            track: Color(tmLight: 0xF1E2CB, dark: 0x4A3617),
                            fill: TMDesign.frontier
                        )
                    }
                    .padding(10)
                    .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TMDesign.amberChipBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: Longest clinched

    @ViewBuilder
    private var longestClinchedCard: some View {
        let clinched = routes.filter(\.isClinched).sorted { $0.mileage > $1.mileage }.prefix(5)

        if !clinched.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TMDesign.clinched)
                    Text("Longest clinched")
                        .font(.system(size: 16, weight: .bold))
                }
                .accessibilityAddTraits(.isHeader)

                ForEach(Array(clinched)) { route in
                    HStack {
                        Text(route.listName)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(formatNumber(convert(route.mileage))) \(unit)")
                            .font(.system(size: 15, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(TMDesign.clinched)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: All routes — status by shape, not just color (audit §7)

    private var allRoutesCard: some View {
        let sorted = routes.sorted { $0.clinchedMileage > $1.clinchedMileage }

        return VStack(alignment: .leading, spacing: 0) {
            TMDesign.sectionHeader("All routes · \(routes.count.formatted())")
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)

            ForEach(Array(sorted.enumerated()), id: \.element.id) { index, route in
                routeRow(route)
                if index < sorted.count - 1 {
                    Rectangle().fill(TMDesign.hairline).frame(height: 1)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func routeRow(_ route: StatisticsView.RouteInfo) -> some View {
        HStack(spacing: 12) {
            if route.isClinched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(TMDesign.clinched)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .strokeBorder(
                        route.percentage > 50 ? TMDesign.frontier : TMDesign.chevron,
                        lineWidth: 2
                    )
                    .frame(width: 17, height: 17)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(route.listName)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                if route.isClinched {
                    Text("\(formatNumber(convert(route.mileage))) \(unit)")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(TMDesign.tertiaryText)
                } else {
                    MiniBar(
                        fraction: route.mileage > 0 ? route.clinchedMileage / route.mileage : 0,
                        height: 5,
                        track: TMDesign.progressTrack,
                        fill: route.percentage > 50 ? TMDesign.frontier : TMDesign.accent
                    )
                    .frame(maxWidth: 120)
                    Text("\(formatNumber(convert(route.clinchedMileage))) of \(formatNumber(convert(route.mileage))) \(unit)")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(TMDesign.tertiaryText)
                }
            }

            Spacer(minLength: 8)

            if route.isClinched {
                Text("Clinched")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(TMDesign.clinched)
            } else {
                Text("\(Int(route.percentage.rounded()))%")
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(TMDesign.secondaryText)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            route.isClinched
                ? "\(route.listName), clinched, \(formatNumber(convert(route.mileage))) \(unit)"
                : "\(route.listName), \(Int(route.percentage.rounded())) percent clinched, \(formatNumber(convert(route.clinchedMileage))) of \(formatNumber(convert(route.mileage))) \(unit)"
        )
    }

    // MARK: Small capsule progress bar

    private struct MiniBar: View {
        let fraction: Double
        var height: CGFloat = 6
        var track: Color = TMDesign.progressTrack
        var fill: Color = TMDesign.accent

        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule()
                        .fill(fill)
                        .frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await TravelMappingAPI.shared.getRegionSegments(
                region: region,
                traveler: username
            )
            routes = result.routes.map { r in
                StatisticsView.RouteInfo(
                    id: r.root,
                    root: r.root,
                    listName: r.listName,
                    mileage: r.mileage,
                    clinchedMileage: r.clinchedMileage
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
