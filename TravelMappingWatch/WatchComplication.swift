// =============================================================================
// INERT / DEAD CODE — this complication never runs.
//
// `TravelMappingComplication` is compiled into the watch *app* target, but watchOS
// complications must live in a watch *widget-extension* target with a `WidgetBundle`
// `@main` entry point — no such target exists in this project, so this widget is
// never registered and never appears in the complication picker.
//
// To make it functional you would need to:
//   1. Add a new watchOS Widget Extension target to the Xcode project and move this
//      file into it (target membership changes via pbxproj edits are unreliable here,
//      so do it in Xcode).
//   2. Add a `WidgetBundle` `@main` struct in that target that returns
//      `TravelMappingComplication()`.
//   3. Add the app group (`group.com.psiegel18.TravelMapping`) to the extension's
//      entitlements and switch the `UserDefaults.standard` read below to
//      `UserDefaults(suiteName:)` — the extension runs in its own sandbox, so
//      `UserDefaults.standard` here would NOT see the watch app's "watchUsername".
//
// Kept in the repo (rather than deleted) because removing/adding target membership
// is out of scope for automated edits.
// =============================================================================

import WidgetKit
import SwiftUI

struct WatchStatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchStatsEntry {
        WatchStatsEntry(date: Date(), routeCount: 597)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchStatsEntry) -> Void) {
        completion(WatchStatsEntry(date: Date(), routeCount: 597))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchStatsEntry>) -> Void) {
        Task {
            let count = await fetchRouteCount()
            let entry = WatchStatsEntry(date: Date(), routeCount: count)
            let nextUpdate = Calendar.current.date(byAdding: .hour, value: 6, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
        }
    }

    private func fetchRouteCount() async -> Int {
        let username = UserDefaults.standard.string(forKey: "watchUsername") ?? "psiegel18"
        do {
            let url = URL(string: "https://travelmapping.net/lib/getTravelerRoutes.php?dbname=TravelMapping")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "params={\"traveler\":\"\(username)\"}".data(using: .utf8)

            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let routes = json["routes"] as? [String] {
                return routes.count
            }
        } catch {}
        return 0
    }
}

struct WatchStatsEntry: TimelineEntry {
    let date: Date
    let routeCount: Int
}

struct TravelMappingComplication: Widget {
    let kind = "TravelMappingComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchStatsProvider()) { entry in
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 2) {
                    Image(systemName: "road.lanes")
                        .font(.caption)
                    Text("\(entry.routeCount)")
                        .font(.headline.bold())
                }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Travel Stats")
        .description("Shows your route count")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}
