import SwiftUI

// MARK: - Image Renderer

@MainActor
func renderShareImage(view: some View) -> UIImage? {
    // Force light mode so card is always visible
    let wrapped = view.environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: wrapped)
    renderer.scale = UIScreen.main.scale
    return renderer.uiImage
}

// MARK: - Share Sheet (presented via UIKit for reliability)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIViewController {
        let wrapper = UIViewController()
        DispatchQueue.main.async {
            let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
            activityVC.popoverPresentationController?.sourceView = wrapper.view
            wrapper.present(activityVC, animated: true)
        }
        return wrapper
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
