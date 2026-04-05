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
    let totalMiles: Double

    var percentage: Double {
        totalMiles > 0 ? clinchedMiles / totalMiles * 100 : 0
    }

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

            HStack(spacing: 24) {
                VStack {
                    Text("\(regions)")
                        .font(.title.bold())
                    Text("Regions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text("\(routes)")
                        .font(.title.bold())
                    Text("Routes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text(String(format: "%.0f mi", clinchedMiles))
                        .font(.title.bold())
                    Text("Traveled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if totalMiles > 0 {
                VStack(spacing: 4) {
                    ProgressView(value: clinchedMiles, total: totalMiles)
                        .tint(.blue)
                    Text(String(format: "%.1f%% of %.0f miles", percentage, totalMiles))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
    let renderer = ImageRenderer(content: view)
    renderer.scale = UIScreen.main.scale
    return renderer.uiImage
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
