import SwiftUI

/// Friendly error display with retry button
struct ErrorView: View {
    let title: String
    let message: String
    let retryAction: (() async -> Void)?

    @State private var isRetrying = false

    init(title: String = "Couldn't Load Data", message: String, retryAction: (() async -> Void)? = nil) {
        self.title = title
        self.message = Self.friendly(message)
        self.retryAction = retryAction
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if let retry = retryAction {
                Button {
                    Haptics.light()
                    isRetrying = true
                    Task {
                        await retry()
                        isRetrying = false
                    }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.blue, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(isRetrying)
                .opacity(isRetrying ? 0.5 : 1)
            }
        }
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
        return raw
    }
}

#Preview {
    ErrorView(
        message: "The request timed out.",
        retryAction: { try? await Task.sleep(nanoseconds: 1_000_000_000) }
    )
}
