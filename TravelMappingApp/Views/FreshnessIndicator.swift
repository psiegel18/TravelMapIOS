import SwiftUI

struct FreshnessIndicator: View {
    let lastUpdated: Date?

    private func formatted(asOf now: Date) -> String {
        guard let date = lastUpdated else { return "No cache" }
        let seconds = now.timeIntervalSince(date)
        let minutes = Int(seconds / 60)
        let hours = Int(seconds / 3600)

        if minutes < 1 { return "Cached just now" }
        if minutes < 60 { return "Cached \(minutes) min ago" }
        if hours < 24 { return "Cached \(hours) hr\(hours == 1 ? "" : "s") ago" }
        return "Cached \(hours / 24) day\(hours / 24 == 1 ? "" : "s") ago"
    }

    var body: some View {
        // Re-render every minute so the age string stays accurate while visible.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption2)
                Text(formatted(asOf: context.date))
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
        }
    }
}
