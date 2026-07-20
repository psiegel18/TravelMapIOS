import SwiftUI

enum ShareContent: Identifiable {
    case stats(image: UIImage, username: String, subtitle: String)
    case map(image: UIImage, cardImage: UIImage, username: String)
    case trip(image: UIImage, tripID: UUID)

    var id: String {
        switch self {
        case .stats(_, let u, _): return "stats-\(u)"
        case .map(_, _, let u): return "map-\(u)"
        // Must be stable across accesses — a fresh UUID per access makes SwiftUI
        // think the sheet's item changed and tear it down mid-interaction.
        case .trip(_, let tripID): return "trip-\(tripID.uuidString)"
        }
    }

    var profileURL: URL? {
        switch self {
        case .stats(_, let username, _), .map(_, _, let username):
            return URL(string: "https://travelmapping.net/user/?u=\(username)")
        case .trip:
            return nil
        }
    }

    var cardImage: UIImage {
        switch self {
        case .stats(let img, _, _): return img
        case .map(_, let card, _): return card
        case .trip(let img, _): return img
        }
    }

    var linkTitle: String {
        switch self {
        case .stats(_, let u, _): return "\(u)'s Travel Stats"
        case .map(_, _, let u): return "\(u)'s Travel Map"
        case .trip: return "Road Trip"
        }
    }

    var linkSubtitle: String? {
        switch self {
        case .stats(_, _, let sub): return sub
        case .map: return "Tap to explore the interactive map"
        case .trip: return nil
        }
    }

    var hasLink: Bool {
        profileURL != nil
    }
}

struct SharePreviewSheet: View {
    let content: ShareContent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Card preview
                Image(uiImage: content.cardImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .padding(.horizontal)

                // Share buttons
                VStack(spacing: 12) {
                    if content.hasLink {
                        Button {
                            shareAsLink()
                        } label: {
                            Label("Share as Link", systemImage: "link")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(.blue, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }

                    ShareLink(
                        item: Image(uiImage: content.cardImage),
                        preview: SharePreview(content.linkTitle, image: Image(uiImage: content.cardImage))
                    ) {
                        Label("Share as Image", systemImage: "photo")
                            .font(.headline)
                            .foregroundStyle(content.hasLink ? .blue : .white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                content.hasLink ? Color.blue.opacity(0.1) : Color.blue,
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func shareAsLink() {
        guard let url = content.profileURL else { return }

        let thumbnail: UIImage?
        switch content {
        case .map(let mapImg, _, _): thumbnail = mapImg
        case .stats(let img, _, _): thumbnail = img
        case .trip: thumbnail = nil
        }

        let item = RichLinkActivityItem(
            url: url,
            title: content.linkTitle,
            subtitle: content.linkSubtitle,
            thumbnail: thumbnail
        )
        presentShareSheet(items: [item])
    }

    private func presentShareSheet(items: [Any]) {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = windowScenes.first { $0.activationState == .foregroundActive } ?? windowScenes.first
        guard let root = scene?.keyWindow?.rootViewController
                ?? scene?.windows.first?.rootViewController else { return }

        var topVC = root
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activityVC.popoverPresentationController?.sourceView = topVC.view
        activityVC.popoverPresentationController?.sourceRect = CGRect(
            x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0
        )
        activityVC.popoverPresentationController?.permittedArrowDirections = []
        topVC.present(activityVC, animated: true)
    }
}
