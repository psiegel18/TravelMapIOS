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
