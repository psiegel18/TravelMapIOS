import UIKit
import LinkPresentation

/// Provides LPLinkMetadata so shared URLs appear as rich cards in Messages, Mail, etc.
final class RichLinkActivityItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String
    let subtitle: String?
    let thumbnail: UIImage?

    init(url: URL, title: String, subtitle: String? = nil, thumbnail: UIImage? = nil) {
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.thumbnail = thumbnail
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        url
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = title

        if let thumbnail {
            metadata.imageProvider = NSItemProvider(object: thumbnail)
        }

        // Use app icon
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
            ?? Bundle.main.url(forResource: "AppIcon60x60@2x", withExtension: "png") {
            metadata.iconProvider = NSItemProvider(contentsOf: iconURL)
        }

        return metadata
    }
}
