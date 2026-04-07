import SwiftUI

struct GetStartedView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                stepCard(
                    number: 1,
                    title: "Choose a Username",
                    icon: "person.crop.circle.badge.plus",
                    color: .blue
                ) {
                    Text("Pick an alphanumeric name:")
                    bullet("Use only letters A-Z / a-z")
                    bullet("Numbers 0-9 are allowed")
                    bullet("Underscores (_) are allowed")
                    bullet("Max 48 characters")
                    bullet("Avoid diacritical marks or non-English characters")
                }

                stepCard(
                    number: 2,
                    title: "Create a .list File",
                    icon: "doc.text",
                    color: .green
                ) {
                    Text("Create a plain text file named:")
                    Text("yourusername.list")
                        .font(.system(.subheadline, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    Text("Example: `psiegel18.list`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                stepCard(
                    number: 3,
                    title: "List Your Traveled Segments",
                    icon: "road.lanes",
                    color: .orange
                ) {
                    Text("Each line represents one road segment you've driven.")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Single region:")
                            .font(.caption.bold())
                        Text("Region Route Waypoint1 Waypoint2")
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        Text("Example: IL I-70 52 MO/IL")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Multi-region:")
                            .font(.caption.bold())
                        Text("R1 Route1 WP1 R2 Route2 WP2")
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        Text("Example: IL I-70 52 MO I-70 249")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text("💡 Tip: Use the **.list Tool** on travelmapping.net's showroute page — it builds these lines for you.")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .padding(.top, 4)
                }

                stepCard(
                    number: 4,
                    title: "Use This App to Help!",
                    icon: "sparkles",
                    color: .purple
                ) {
                    Text("You can use this app to generate .list entries:")
                    bullet("Open any user's map")
                    bullet("Tap the pencil icon to enter Select Mode")
                    bullet("Tap segments on the map that you've driven or ridden")
                    bullet("Copy or share the generated .list text")
                    bullet("Record a Road Trip or Train Trip to auto-generate entries from GPS!")
                    bullet("Use the Route Planner tab to preview TM segments along a planned route")
                }

                stepCard(
                    number: 5,
                    title: "Submit Your File (First Time)",
                    icon: "envelope.fill",
                    color: .red
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("⚠️ First-time users must submit via email.")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        Text("Once your file is accepted and added to the repo, you can use GitHub PRs for all future updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Email your .list file to:", systemImage: "envelope")
                            .font(.caption.bold())
                        Link("travmap@teresco.org",
                             destination: URL(string: "mailto:travmap@teresco.org?subject=New%20user%20list%20file")!)
                            .font(.caption)
                    }
                    .padding(.top, 4)
                }

                stepCard(
                    number: 6,
                    title: "Future Updates via GitHub",
                    icon: "chevron.left.forwardslash.chevron.right",
                    color: .purple
                ) {
                    Text("After your initial file is accepted, you can update it with pull requests:")
                        .font(.caption)

                    bullet("Fork the TravelMapping/UserData repo")
                    bullet("Edit list_files/yourusername.list")
                    bullet("Open a pull request with your changes")
                    bullet("Updates typically merged within a day")

                    Link(destination: URL(string: "https://github.com/TravelMapping/UserData")!) {
                        HStack(spacing: 4) {
                            Text("TravelMapping/UserData repo")
                            Image(systemName: "arrow.up.forward")
                        }
                        .font(.caption)
                    }
                    .padding(.top, 4)
                }

                VStack(spacing: 8) {
                    Link(destination: URL(string: "https://travelmapping.net/participate.php")!) {
                        HStack {
                            Text("Full Documentation")
                            Image(systemName: "arrow.up.forward")
                        }
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            }
            .padding()
            .frame(maxWidth: sizeClass == .regular ? 900 : 700)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Get Started")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New to Travel Mapping?")
                .font(.title.bold())
            Text("Follow these steps to create your account and start tracking your travels.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func stepCard<Content: View>(
        number: Int,
        title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Text("\(number)")
                        .font(.headline.bold())
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(color)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .font(.subheadline)
            .padding(.leading, 52)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
        }
        .font(.caption)
    }
}
