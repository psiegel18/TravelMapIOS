import SwiftUI

/// Friendly error display with retry button (design audit §11 — warmer card).
struct ErrorView: View {
    let title: String
    let message: String
    let retryAction: (() async -> Void)?

    @State private var isRetrying = false

    init(title: String = "Couldn't Load Data", message: String, retryAction: (() async -> Void)? = nil) {
        let friendly = Self.friendly(message)
        self.message = friendly
        // Give the offline case its audit copy when the caller used the default title.
        if title == "Couldn't Load Data", friendly.lowercased().contains("offline") {
            self.title = "You're offline"
        } else {
            self.title = title
        }
        self.retryAction = retryAction
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(TMDesign.redChipBG)
                    .frame(width: 72, height: 72)
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TMDesign.redChipFG)
            }
            .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 18, weight: .heavy))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(TMDesign.secondaryText)
                .multilineTextAlignment(.center)

            if let retry = retryAction {
                Button {
                    Haptics.light()
                    isRetrying = true
                    Task {
                        await retry()
                        isRetrying = false
                    }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TMDesign.accent)
                        .padding(.horizontal, 22)
                        .frame(minHeight: 44)
                        .background(
                            Capsule().strokeBorder(TMDesign.accent, lineWidth: 1.5)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isRetrying)
                .opacity(isRetrying ? 0.5 : 1)
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(TMDesign.cardBG, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Convert technical errors to friendly messages
    static func friendly(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") {
            return "The server took too long to respond. Please check your connection and try again."
        }
        if lower.contains("offline") || lower.contains("network connection") || lower.contains("internet") {
            return "You appear to be offline. Connect to the internet and try again."
        }
        if lower.contains("cannot find host") || lower.contains("host") {
            return "Couldn't reach travelmapping.net. The site may be down, or check your connection."
        }
        if lower.contains("404") || lower.contains("not found") {
            return "The requested data couldn't be found on the server."
        }
        if lower.contains("403") || lower.contains("rate limit") {
            return "Rate limit reached. Please wait a few minutes and try again."
        }
        if lower.contains("ssl") || lower.contains("tls") || lower.contains("certificate") {
            return "A secure connection could not be established."
        }
        if lower.contains("couldn't be read") || lower.contains("is missing") || lower.contains("not valid json") {
            return "The server returned an unexpected response. Please try again."
        }
        return raw
    }
}

#Preview {
    ErrorView(
        message: "The request timed out.",
        retryAction: { try? await Task.sleep(nanoseconds: 1_000_000_000) }
    )
}
