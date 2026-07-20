import SwiftUI

/// Cache-freshness indicator (design audit §11 — "freshness, made human").
/// The TM database merges once a day, so a cache from today IS current data.
/// - `.compact` (default): a small capsule chip that fits toolbar slots —
///   green "Up to date" when the cache is from today, neutral "Synced N hrs ago" otherwise.
/// - `.panel`: the audit's full two-line green panel for inline placement.
struct FreshnessIndicator: View {
    enum Style {
        case compact
        case panel
    }

    let lastUpdated: Date?
    var style: Style = .compact

    init(lastUpdated: Date?, style: Style = .compact) {
        self.lastUpdated = lastUpdated
        self.style = style
    }

    private func isFromToday(asOf now: Date) -> Bool {
        guard let date = lastUpdated else { return false }
        return Calendar.current.isDate(date, inSameDayAs: now)
    }

    /// "just now" / "12 min ago" / "3 hrs ago" / "2 days ago"
    private func age(asOf now: Date) -> String {
        guard let date = lastUpdated else { return "never" }
        let seconds = now.timeIntervalSince(date)
        let minutes = Int(seconds / 60)
        let hours = Int(seconds / 3600)

        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if hours < 24 { return "\(hours) hr\(hours == 1 ? "" : "s") ago" }
        return "\(hours / 24) day\(hours / 24 == 1 ? "" : "s") ago"
    }

    var body: some View {
        // Re-render every minute so the age string stays accurate while visible.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            switch style {
            case .compact:
                compactView(asOf: context.date)
            case .panel:
                panelView(asOf: context.date)
            }
        }
    }

    // MARK: Compact chip (toolbar-safe)

    @ViewBuilder
    private func compactView(asOf now: Date) -> some View {
        let fresh = isFromToday(asOf: now)
        HStack(spacing: 5) {
            if fresh {
                Circle()
                    .fill(TMDesign.clinched)
                    .frame(width: 8, height: 8)
                Text("Up to date")
                    .font(.system(size: 13, weight: .bold))
            } else {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold))
                Text(lastUpdated == nil ? "No cache" : "Synced \(age(asOf: now))")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(fresh ? TMDesign.greenChipFG : TMDesign.neutralChipFG)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(fresh ? TMDesign.greenChipBG : TMDesign.neutralChipBG, in: Capsule())
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(asOf: now))
    }

    // MARK: Two-line panel (audit §11)

    @ViewBuilder
    private func panelView(asOf now: Date) -> some View {
        let fresh = isFromToday(asOf: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if fresh {
                    Circle()
                        .fill(TMDesign.clinched)
                        .frame(width: 8, height: 8)
                } else {
                    Image(systemName: "clock")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(fresh
                     ? "Up to date · site refreshed today"
                     : (lastUpdated == nil ? "No cached data yet" : "Synced \(age(asOf: now))"))
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(fresh ? TMDesign.greenChipFG : TMDesign.neutralChipFG)
            }
            Text(fresh
                 ? "Pull to refresh · synced \(age(asOf: now))"
                 : "Pull to refresh for the latest")
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(TMDesign.secondaryText)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            fresh ? TMDesign.greenChipBG : TMDesign.neutralChipBG,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(asOf: now))
    }

    private func accessibilityText(asOf now: Date) -> String {
        guard lastUpdated != nil else { return "No cached data yet" }
        if isFromToday(asOf: now) {
            return "Up to date. Site refreshed today, synced \(age(asOf: now)). Pull to refresh."
        }
        return "Synced \(age(asOf: now)). Pull to refresh for the latest."
    }
}
