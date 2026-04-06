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
                ProgressView("Loading \(region) routes...")
            } else if let error = errorMessage {
                ErrorView(message: error) {
                    await load()
                }
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        overviewCard
                        closestCard
                        longestClinchedCard
                        allRoutesCard
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(region)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private var overviewCard: some View {
        let total = routes.reduce(0.0) { $0 + $1.mileage }
        let clinched = routes.reduce(0.0) { $0 + $1.clinchedMileage }
        let percentage = total > 0 ? clinched / total * 100 : 0
        let clinchedCount = routes.filter(\.isClinched).count

        return VStack(spacing: 12) {
            Text("\(region) Overview")
                .font(.title3.bold())
            HStack(spacing: 24) {
                VStack {
                    Text(formatNumber(convert(clinched)))
                        .font(.title2.bold())
                    Text("\(unit) traveled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text(routes.count.formatted())
                        .font(.title2.bold())
                    Text("routes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text(clinchedCount.formatted())
                        .font(.title2.bold())
                    Text("clinched")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: clinched, total: max(total, 1))
                .tint(.blue)
            Text(String(format: "%.1f%% complete (%.0f / %.0f %@)", percentage, convert(clinched), convert(total), unit))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var closestCard: some View {
        let inProgress = routes
            .filter { $0.clinchedMileage > 0 && !$0.isClinched }
            .sorted { $0.remainingMileage < $1.remainingMileage }
            .prefix(10)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "target").foregroundStyle(.orange)
                Text("Closest to Clinched").font(.title3.bold())
            }
            if inProgress.isEmpty {
                Text("No routes in progress").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(inProgress)) { route in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(route.listName).font(.subheadline.bold())
                            Spacer()
                            Text("\(formatNumber(convert(route.remainingMileage))) \(unit) left")
                                .font(.caption.bold()).foregroundStyle(.orange)
                        }
                        ProgressView(value: route.clinchedMileage, total: route.mileage).tint(.orange)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var longestClinchedCard: some View {
        let clinched = routes.filter(\.isClinched).sorted { $0.mileage > $1.mileage }.prefix(5)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Longest Clinched").font(.title3.bold())
            }
            if clinched.isEmpty {
                Text("No clinched routes yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(clinched)) { route in
                    HStack {
                        Text(route.listName).font(.subheadline.bold())
                        Spacer()
                        Text("\(formatNumber(convert(route.mileage))) \(unit)")
                            .font(.caption.bold()).foregroundStyle(.green)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var allRoutesCard: some View {
        let sorted = routes.sorted { $0.clinchedMileage > $1.clinchedMileage }

        return VStack(alignment: .leading, spacing: 12) {
            Text("All Routes (\(routes.count))").font(.title3.bold())
            ForEach(sorted) { route in
                HStack {
                    Image(systemName: route.isClinched ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(route.isClinched ? .green : .secondary)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.listName).font(.subheadline)
                        Text(String(format: "%.1f%%", route.percentage))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(formatNumber(convert(route.clinchedMileage)))/\(formatNumber(convert(route.mileage))) \(unit)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
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
