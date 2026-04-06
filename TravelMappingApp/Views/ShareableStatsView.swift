import SwiftUI

// MARK: - Shareable Item

struct ShareItem: Identifiable {
    let id = UUID()
    let image: UIImage?
}

// MARK: - Share Card

struct ShareableStatsCard: View {
    let username: String
    let regions: Int
    let routes: Int
    let clinchedMiles: Double
    let useMiles: Bool

    private var displayValue: Int {
        Int(useMiles ? clinchedMiles : clinchedMiles * 1.60934)
    }
    private var unit: String { useMiles ? "mi" : "km" }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "road.lanes")
                    .font(.title)
                    .foregroundStyle(.blue)
                Text("Travel Mapping")
                    .font(.title2.bold())
            }

            Text(username)
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                VStack {
                    Text(regions.formatted())
                        .font(.title2.bold())
                    Text("Regions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                VStack {
                    Text(routes.formatted())
                        .font(.title2.bold())
                    Text("Routes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                VStack {
                    Text(displayValue.formatted())
                        .font(.title2.bold())
                    Text("\(unit) Traveled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            Text("travelmapping.net")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .background(Color(.systemBackground))
        .frame(width: 340)
    }
}

// MARK: - Image Renderer

@MainActor
func renderShareImage(view: some View) -> UIImage? {
    // Force light mode so card is always visible
    let wrapped = view.environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: wrapped)
    renderer.scale = UIScreen.main.scale
    return renderer.uiImage
}

// MARK: - Share Preview (shows card before sharing)

struct SharePreviewView: View {
    let image: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Share Preview")
                    .font(.headline)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Could not generate preview")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(image == nil)

                Spacer()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let image {
                    ShareSheet(items: [image])
                }
            }
        }
    }
}

// MARK: - Share Sheet (presented via UIKit for reliability)

struct ShareSheetView: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIViewController {
        let wrapper = UIViewController()
        DispatchQueue.main.async {
            let activityVC = UIActivityViewController(activityItems: [image], applicationActivities: nil)
            activityVC.popoverPresentationController?.sourceView = wrapper.view
            wrapper.present(activityVC, animated: true)
        }
        return wrapper
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

// Keep old name for backward compat
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
