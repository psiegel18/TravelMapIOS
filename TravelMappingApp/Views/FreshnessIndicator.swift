import SwiftUI

struct FreshnessIndicator: View {
    let lastUpdated: Date?
    var prefix: String = "Updated"

    private var formatted: String {
        guard let date = lastUpdated else { return "Never" }
        let interval = Date().timeIntervalSince(date)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(fromTimeInterval: -interval)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.caption2)
            Text("\(prefix) \(formatted)")
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
    }
}
