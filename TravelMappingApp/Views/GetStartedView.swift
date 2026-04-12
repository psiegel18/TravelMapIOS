import SwiftUI
import MessageUI
import MapKit
import Sentry

struct GetStartedView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var desiredUsername = ""
    @State private var listContent = ""
    @State private var showMailComposer = false
    @State private var showMailUnavailable = false
    @State private var showRegionPicker = false
    @State private var pickedRegion: String?  // nil = no picker, non-nil = show segment picker

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

                    TextField("Enter your desired username", text: $desiredUsername)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.top, 4)
                }

                stepCard(
                    number: 2,
                    title: "Learn the .list Format",
                    icon: "doc.text",
                    color: .green
                ) {
                    Text("Your file is a plain text file named:")
                    Text(desiredUsername.isEmpty ? "yourusername.list" : "\(desiredUsername).list")
                        .font(.system(.subheadline, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))

                    Text("Each line represents one road segment you've traveled:")
                        .padding(.top, 4)

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

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Comments:")
                            .font(.caption.bold())
                        Text("Text after # is ignored, useful for notes:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("IL I-70 52 MO/IL  # Illinois section")
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }

                    Text("Concurrent highways are automatically credited \u{2014} you only need to list one of them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                stepCard(
                    number: 3,
                    title: "Build Your .list File",
                    icon: "sparkles",
                    color: .purple
                ) {
                    Text("Pick a region, select the segments you've traveled on the map, and tap Done to add them to your file.")

                    Button {
                        Haptics.light()
                        showRegionPicker = true
                    } label: {
                        Label("Pick Segments on Map", systemImage: "map.fill")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.purple, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Text("You can also use the Travelers tab to browse existing users' maps with the segment selector, or record a Road Trip to auto-generate entries from GPS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                stepCard(
                    number: 4,
                    title: "Review & Submit",
                    icon: "envelope.fill",
                    color: .red
                ) {
                    Text("Paste or type your .list content below, make any final edits, then send it as an email.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        Haptics.light()
                        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
                            if listContent.isEmpty {
                                listContent = clipboard
                            } else {
                                listContent += "\n" + clipboard
                            }
                        }
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    TextEditor(text: $listContent)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 150)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topLeading) {
                            if listContent.isEmpty {
                                Text("# \(desiredUsername.isEmpty ? "yourusername" : desiredUsername).list\n# Paste your segments here\nIL I-70 52 MO/IL")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(12)
                                    .allowsHitTesting(false)
                            }
                        }

                    if !listContent.isEmpty {
                        let lineCount = listContent.components(separatedBy: .newlines)
                            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
                            .count
                        Text("\(lineCount) segment\(lineCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text("First-time users submit via email. Updates are processed nightly around 9\u{2013}11 PM US/Eastern.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    Button {
                        Haptics.light()
                        if MFMailComposeViewController.canSendMail() {
                            showMailComposer = true
                        } else {
                            showMailUnavailable = true
                        }
                    } label: {
                        Label("Compose Submission Email", systemImage: "envelope.fill")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.blue, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(desiredUsername.trimmingCharacters(in: .whitespaces).isEmpty || listContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(desiredUsername.trimmingCharacters(in: .whitespaces).isEmpty || listContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                }

                stepCard(
                    number: 5,
                    title: "Future Updates via GitHub",
                    icon: "chevron.left.forwardslash.chevron.right",
                    color: .indigo
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

                VStack(alignment: .leading, spacing: 6) {
                    Label("Tips", systemImage: "lightbulb.fill")
                        .font(.headline)
                        .foregroundStyle(.yellow)
                    bullet("Each line must have exactly 4 fields (single region) or 6 fields (multi-region)")
                    bullet("Use blank lines and # comments to organize by region or trip date")
                    bullet("New submissions replace previous files entirely \u{2014} always include all traveled highways when updating")
                    bullet("Check your stats page after processing to verify waypoints were recognized")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding()
            .frame(maxWidth: sizeClass == .regular ? 900 : 700)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Get Started")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showMailComposer) {
            MailComposeView(
                username: desiredUsername,
                listContent: listContent,
                isPresented: $showMailComposer
            )
            .ignoresSafeArea()
        }
        .alert("Mail Not Available", isPresented: $showMailUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No mail account is configured on this device. Please email your .list file to travmap@teresco.org from another device.")
        }
        .sheet(isPresented: $showRegionPicker) {
            regionPickerSheet
        }
        .fullScreenCover(isPresented: Binding(
            get: { pickedRegion != nil },
            set: { if !$0 { pickedRegion = nil } }
        )) {
            if let region = pickedRegion {
                NavigationStack {
                    SegmentPickerMapView(region: region) { listText in
                        if listContent.isEmpty {
                            listContent = listText
                        } else {
                            listContent += "\n" + listText
                        }
                    }
                }
            }
        }
    }

    private var regionPickerSheet: some View {
        RegionPickerView { region in
            showRegionPicker = false
            // Delay slightly so the sheet dismisses before the cover presents
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pickedRegion = region
            }
        } onCancel: {
            showRegionPicker = false
        }
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
            Text("\u{2022}")
                .foregroundStyle(.secondary)
            Text(text)
        }
        .font(.caption)
    }
}

// MARK: - Region Picker

private struct RegionPickerView: View {
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    struct RegionItem: Identifiable {
        let id: String // region code
        let code: String
        let displayName: String // "FL — Florida" or just "ALB"
        let searchText: String // "FL Florida" for matching
    }

    struct SectionGroup: Identifiable {
        let id: String
        let title: String
        let regions: [RegionItem]
    }

    @State private var sections: [SectionGroup] = []
    @State private var searchText = ""

    private var filtered: [SectionGroup] {
        if searchText.isEmpty { return sections }
        let q = searchText.lowercased()
        return sections.compactMap { section in
            let matching = section.regions.filter { $0.searchText.lowercased().contains(q) }
            return matching.isEmpty ? nil : SectionGroup(id: section.id, title: section.title, regions: matching)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if sections.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading regions...")
                        Spacer()
                    }
                } else {
                    ForEach(filtered) { section in
                        Section(section.title) {
                            ForEach(section.regions) { region in
                                Button { onSelect(region.code) } label: {
                                    Text(region.displayName)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search (e.g. Florida, NY, Germany)")
            .navigationTitle("Choose a Region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
            .task { await loadRegions() }
        }
    }

    private func loadRegions() async {
        // Try getAllRoutes for continent/country/region grouping
        if let catalog = try? await TravelMappingAPI.shared.getAllRoutes() {
            let catalogRegions = catalog.regions ?? []
            let countries = catalog.countries ?? []
            let continents = catalog.continents ?? []
            let count = catalogRegions.count

            if count > 0, countries.count == count, continents.count == count {
                // Build unique regions with their country and continent
                struct RegionInfo: Hashable {
                    let code: String
                    let country: String
                    let continent: String
                }
                var seen = Set<String>()
                var infos: [RegionInfo] = []
                for i in 0..<count {
                    let code = catalogRegions[i]
                    if seen.insert(code).inserted {
                        infos.append(RegionInfo(code: code, country: countries[i], continent: continents[i]))
                    }
                }

                // Group: multi-region countries get their own section,
                // single-region countries grouped by continent
                let byCountry = Dictionary(grouping: infos) { $0.country }
                var builtSections: [String: [RegionItem]] = [:] // sectionTitle -> items

                let usTerritories: Set<String> = ["AS", "GU", "MP", "PR", "VI"]

                for (country, regionInfos) in byCountry {
                    let continent = regionInfos.first?.continent ?? "Other"
                    let countryFullName = Self.countryName(for: country) ?? country
                    if regionInfos.count > 1 {
                        // Multi-region country — split US into states vs territories
                        if country == "USA" {
                            let states = regionInfos.filter { !usTerritories.contains($0.code) }
                            let territories = regionInfos.filter { usTerritories.contains($0.code) }
                            if !states.isEmpty {
                                builtSections["United States"] = states.map { info in
                                    let name = Self.regionName(for: info.code)
                                    let display = name != nil ? "\(info.code) \u{2014} \(name!)" : info.code
                                    let search = "\(info.code) \(name ?? "") USA United States \(continent)"
                                    return RegionItem(id: info.code, code: info.code, displayName: display, searchText: search)
                                }.sorted { $0.code < $1.code }
                            }
                            if !territories.isEmpty {
                                builtSections["US Territories"] = territories.map { info in
                                    let name = Self.regionName(for: info.code)
                                    let display = name != nil ? "\(info.code) \u{2014} \(name!)" : info.code
                                    let search = "\(info.code) \(name ?? "") USA United States territory \(continent)"
                                    return RegionItem(id: info.code, code: info.code, displayName: display, searchText: search)
                                }.sorted { $0.code < $1.code }
                            }
                        } else {
                            let items = regionInfos.map { info in
                                let name = Self.regionName(for: info.code)
                                let display = name != nil ? "\(info.code) \u{2014} \(name!)" : info.code
                                let search = "\(info.code) \(name ?? "") \(country) \(countryFullName) \(continent)"
                                return RegionItem(id: info.code, code: info.code, displayName: display, searchText: search)
                            }.sorted { $0.code < $1.code }
                            builtSections[countryFullName] = items
                        }
                    } else {
                        // Single-region country — group by continent
                        let code = regionInfos[0].code
                        let display = "\(code) \u{2014} \(countryFullName)"
                        let search = "\(code) \(countryFullName) \(country) \(continent)"
                        let item = RegionItem(id: code, code: code, displayName: display, searchText: search)
                        builtSections[continent, default: []].append(item)
                    }
                }

                sections = builtSections.sorted { $0.key < $1.key }.map {
                    SectionGroup(id: $0.key, title: $0.key, regions: $0.value.sorted { $0.code < $1.code })
                }
                if !sections.isEmpty { return }
            }
        }

        // Fallback: flat list from stats CSV
        if let snapshot = try? await TMStatsService.shared.loadRegionStats(forceRefresh: false) {
            let items = snapshot.regionTotals.keys.sorted().map { code in
                let name = Self.regionName(for: code)
                let display = name != nil ? "\(code) \u{2014} \(name!)" : code
                return RegionItem(id: code, code: code, displayName: display, searchText: "\(code) \(name ?? "")")
            }
            if !items.isEmpty {
                sections = [SectionGroup(id: "all", title: "All Regions", regions: items)]
            }
        }
    }

    static func regionName(for code: String) -> String? { regionNames[code] }
    static func countryName(for code: String) -> String? { countryNames[code] }

    private static let regionNames: [String: String] = [
        // US Territories
        "AS": "American Samoa", "GU": "Guam", "MP": "Northern Mariana Islands",
        "PR": "Puerto Rico", "VI": "US Virgin Islands",
        // US States
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas",
        "CA": "California", "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware",
        "DC": "District of Columbia", "FL": "Florida", "GA": "Georgia", "HI": "Hawaii",
        "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa",
        "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine",
        "MD": "Maryland", "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota",
        "MS": "Mississippi", "MO": "Missouri", "MT": "Montana", "NE": "Nebraska",
        "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico",
        "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio",
        "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island",
        "SC": "South Carolina", "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas",
        "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington",
        "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
        // Canadian Provinces
        "AB": "Alberta", "BC": "British Columbia", "MB": "Manitoba",
        "NB": "New Brunswick", "NL": "Newfoundland and Labrador",
        "NS": "Nova Scotia", "NT": "Northwest Territories", "NU": "Nunavut",
        "ON": "Ontario", "PE": "Prince Edward Island", "QC": "Quebec",
        "SK": "Saskatchewan", "YT": "Yukon",
        // Mexican States
        "AGU": "Aguascalientes", "BCN": "Baja California", "BCS": "Baja California Sur",
        "CAM": "Campeche", "CHP": "Chiapas", "CHH": "Chihuahua", "COA": "Coahuila",
        "COL": "Colima", "DIF": "Mexico City", "DUR": "Durango", "GUA": "Guanajuato",
        "GRO": "Guerrero", "HID": "Hidalgo", "JAL": "Jalisco", "MEX": "State of Mexico",
        "MIC": "Michoac\u{e1}n", "MOR": "Morelos", "NAY": "Nayarit", "NLE": "Nuevo Le\u{f3}n",
        "OAX": "Oaxaca", "PUE": "Puebla", "QUE": "Quer\u{e9}taro", "ROO": "Quintana Roo",
        "SLP": "San Luis Potos\u{ed}", "SIN": "Sinaloa", "SON": "Sonora", "TAB": "Tabasco",
        "TAM": "Tamaulipas", "TLA": "Tlaxcala", "VER": "Veracruz", "YUC": "Yucat\u{e1}n",
        "ZAC": "Zacatecas",
    ]

    private static let countryNames: [String: String] = [
        // North America
        "USA": "United States", "CAN": "Canada", "MEX": "Mexico",
        // Europe
        "ALB": "Albania", "AND": "Andorra", "ARM": "Armenia", "AUT": "Austria",
        "AZE": "Azerbaijan", "BEL": "Belgium", "BGR": "Bulgaria", "BIH": "Bosnia and Herzegovina",
        "BLR": "Belarus", "CHE": "Switzerland", "CYP": "Cyprus", "CZE": "Czechia",
        "DEU": "Germany", "DNK": "Denmark", "ESP": "Spain", "EST": "Estonia",
        "FIN": "Finland", "FRA": "France", "GBR": "United Kingdom", "GEO": "Georgia",
        "GRC": "Greece", "HRV": "Croatia", "HUN": "Hungary", "IRL": "Ireland",
        "ISL": "Iceland", "ITA": "Italy", "KOS": "Kosovo", "LTU": "Lithuania",
        "LUX": "Luxembourg", "LVA": "Latvia", "MDA": "Moldova", "MKD": "North Macedonia",
        "MNE": "Montenegro", "NLD": "Netherlands", "NOR": "Norway", "POL": "Poland",
        "PRT": "Portugal", "ROU": "Romania", "RUS": "Russia", "SMR": "San Marino",
        "SRB": "Serbia", "SVK": "Slovakia", "SVN": "Slovenia", "SWE": "Sweden",
        "TUR": "Turkey", "UKR": "Ukraine",
        // Asia
        "CHN": "China", "IDN": "Indonesia", "IND": "India", "IRN": "Iran",
        "IRQ": "Iraq", "ISR": "Israel", "JOR": "Jordan", "JPN": "Japan",
        "KAZ": "Kazakhstan", "KGZ": "Kyrgyzstan", "KOR": "South Korea",
        "LBN": "Lebanon", "MYS": "Malaysia", "OMN": "Oman", "PAK": "Pakistan",
        "PHL": "Philippines", "SAU": "Saudi Arabia", "SGP": "Singapore",
        "THA": "Thailand", "TWN": "Taiwan", "UZB": "Uzbekistan", "VNM": "Vietnam",
        // South America
        "ARG": "Argentina", "BOL": "Bolivia", "BRA": "Brazil", "CHL": "Chile",
        "COL": "Colombia", "ECU": "Ecuador", "GUY": "Guyana", "PER": "Peru",
        "PRY": "Paraguay", "SUR": "Suriname", "URY": "Uruguay", "VEN": "Venezuela",
        // Central America & Caribbean
        "BLZ": "Belize", "CRI": "Costa Rica", "CUB": "Cuba", "DOM": "Dominican Republic",
        "GTM": "Guatemala", "HND": "Honduras", "HTI": "Haiti", "JAM": "Jamaica",
        "NIC": "Nicaragua", "PAN": "Panama", "PRI": "Puerto Rico", "SLV": "El Salvador",
        "TTO": "Trinidad and Tobago",
        // Africa
        "DZA": "Algeria", "EGY": "Egypt", "ETH": "Ethiopia", "GHA": "Ghana",
        "KEN": "Kenya", "MAR": "Morocco", "NGA": "Nigeria", "TUN": "Tunisia",
        "TZA": "Tanzania", "UGA": "Uganda", "ZAF": "South Africa", "ZMB": "Zambia",
        "ZWE": "Zimbabwe",
        // Oceania
        "AUS": "Australia", "NZL": "New Zealand",
        // Other
        "ABW": "Aruba", "AFG": "Afghanistan", "ALA": "Aland Islands",
    ]
}

// MARK: - Mail Composer

private struct MailComposeView: UIViewControllerRepresentable {
    let username: String
    let listContent: String
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(["travmap@teresco.org"])

        let name = username.isEmpty ? "newuser" : username
        vc.setSubject("New user list file - \(name)")

        let body = """
        Hi,

        I'd like to create a new Travel Mapping account.

        Username: \(name)

        My .list file is attached.

        Thanks!
        """
        vc.setMessageBody(body, isHTML: false)

        // Attach the .list content as a file
        let fileContent = listContent.isEmpty
            ? "# \(name).list\n# Generated by TravelMapping iOS App\n"
            : listContent
        if let data = fileContent.data(using: .utf8) {
            vc.addAttachmentData(data, mimeType: "text/plain", fileName: "\(name).list")
        }

        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let parent: MailComposeView
        init(_ parent: MailComposeView) { self.parent = parent }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            parent.isPresented = false
        }
    }
}

// MARK: - Segment Picker Map

private struct SegmentPickerMapView: View {
    let region: String
    let onComplete: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var segments: [TravelMappingAPI.MapSegment] = []
    @State private var routeMetadata: [TravelMappingAPI.RouteMetadata] = []
    @State private var selectedIDs: Set<Int> = []
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var isLoading = true

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer

            VStack {
                HStack {
                    Spacer()
                    zoomControls.padding(.trailing, 8)
                }
                Spacer()
            }
            .padding(.top, 8)

            if !isLoading {
                selectionBar
            }
        }
        .navigationTitle("Select Segments \u{2014} \(region)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done (\(selectedIDs.count))") {
                    let selected = segments.filter { selectedIDs.contains($0.id) }
                    let text = ListFileGenerator.generateFromMapSegments(selected, routeMetadata: routeMetadata)
                    onComplete(text)
                    dismiss()
                }
                .bold()
                .disabled(selectedIDs.isEmpty)
            }
        }
        .task { await loadSegments() }
        .overlay {
            if isLoading {
                ProgressView("Loading \(region)...")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $mapPosition) {
                ForEach(mergedPolylines) { poly in
                    MapPolyline(coordinates: poly.coordinates)
                        .stroke(.gray.opacity(0.5), lineWidth: 2)
                }
                ForEach(selectedPolylines) { poly in
                    MapPolyline(coordinates: poly.coordinates)
                        .stroke(.white, lineWidth: 7)
                }
                ForEach(selectedPolylines) { poly in
                    MapPolyline(coordinates: poly.coordinates)
                        .stroke(.yellow, lineWidth: 5)
                }
            }
            .mapStyle(.standard)
            .onMapCameraChange { context in visibleRegion = context.region }
            .mapControls { MapCompass(); MapScaleView() }
            .onTapGesture { screenPoint in
                if let coord = proxy.convert(screenPoint, from: .local) {
                    handleTap(at: coord)
                }
            }
        }
    }

    @State private var showPreview = false

    private var selectedListText: String {
        guard !selectedIDs.isEmpty else { return "" }
        let selected = segments.filter { selectedIDs.contains($0.id) }
        return ListFileGenerator.generateFromMapSegments(selected, routeMetadata: routeMetadata)
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            if showPreview && !selectedIDs.isEmpty {
                ScrollView {
                    Text(selectedListText)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 120)
                .background(.ultraThinMaterial)
            }

            HStack {
                Text("\(selectedIDs.count) segment\(selectedIDs.count == 1 ? "" : "s") selected")
                    .font(.subheadline.bold())
                Spacer()
                if !selectedIDs.isEmpty {
                    Button {
                        withAnimation { showPreview.toggle() }
                    } label: {
                        Image(systemName: showPreview ? "eye.slash" : "eye")
                            .font(.subheadline)
                    }
                    Button("Clear") {
                        Haptics.light()
                        selectedIDs.removeAll()
                        showPreview = false
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private var zoomControls: some View {
        VStack(spacing: 0) {
            Button { Haptics.light(); adjustZoom(factor: 0.5) } label: {
                Image(systemName: "plus").font(.title3).frame(width: 44, height: 44)
            }
            Divider().frame(width: 44)
            Button { Haptics.light(); adjustZoom(factor: 2.0) } label: {
                Image(systemName: "minus").font(.title3).frame(width: 44, height: 44)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func adjustZoom(factor: Double) {
        guard let current = visibleRegion else { return }
        let latDelta = min(max(current.span.latitudeDelta * factor, 0.001), 180)
        let lngDelta = min(max(current.span.longitudeDelta * factor, 0.001), 360)
        withAnimation {
            mapPosition = .region(MKCoordinateRegion(
                center: current.center,
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta)
            ))
        }
    }

    // MARK: Tap

    private func handleTap(at coordinate: CLLocationCoordinate2D) {
        var bestSeg: TravelMappingAPI.MapSegment?
        var bestDist: Double = .greatestFiniteMagnitude
        for seg in segments {
            let dist = distanceToSegment(point: coordinate, start: seg.start, end: seg.end)
            if dist < bestDist { bestDist = dist; bestSeg = seg }
        }
        guard let seg = bestSeg, bestDist < 200 else { return }
        if selectedIDs.contains(seg.id) {
            selectedIDs.remove(seg.id); Haptics.light()
        } else {
            selectedIDs.insert(seg.id); Haptics.selection()
        }
    }

    private func distanceToSegment(point: CLLocationCoordinate2D, start: CLLocationCoordinate2D, end: CLLocationCoordinate2D) -> Double {
        let cosLat = cos(point.latitude * .pi / 180)
        let px = (point.longitude - start.longitude) * cosLat
        let py = point.latitude - start.latitude
        let dx = (end.longitude - start.longitude) * cosLat
        let dy = end.latitude - start.latitude
        let segLenSq = dx * dx + dy * dy
        guard segLenSq > 0 else { return sqrt(px * px + py * py) * 111_320 }
        let t = max(0, min(1, (px * dx + py * dy) / segLenSq))
        let closestX = start.longitude * cosLat + t * dx
        let closestY = start.latitude + t * dy
        let distX = point.longitude * cosLat - closestX
        let distY = point.latitude - closestY
        return sqrt(distX * distX + distY * distY) * 111_320
    }

    // MARK: Polylines

    private struct MergedPolyline: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let root: String
    }

    private var mergedPolylines: [MergedPolyline] { merge(segments) }
    private var selectedPolylines: [MergedPolyline] { merge(segments.filter { selectedIDs.contains($0.id) }, startID: 100_000) }

    private func merge(_ segs: [TravelMappingAPI.MapSegment], startID: Int = 0) -> [MergedPolyline] {
        let sorted = segs.sorted { $0.root < $1.root || ($0.root == $1.root && $0.id < $1.id) }
        var result: [MergedPolyline] = []
        var coords: [CLLocationCoordinate2D] = []
        var root = ""
        var polyID = startID
        for seg in sorted {
            if seg.root == root, let last = coords.last, dist(last, seg.start) < 500 {
                coords.append(seg.end)
                if coords.count >= 15 {
                    result.append(MergedPolyline(id: polyID, coordinates: coords, root: root)); polyID += 1
                    coords = [seg.end]
                }
            } else {
                if coords.count >= 2 { result.append(MergedPolyline(id: polyID, coordinates: coords, root: root)); polyID += 1 }
                coords = [seg.start, seg.end]; root = seg.root
            }
        }
        if coords.count >= 2 { result.append(MergedPolyline(id: polyID, coordinates: coords, root: root)) }
        return result
    }

    private func dist(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = (a.latitude - b.latitude) * 111_320
        let dLng = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return sqrt(dLat * dLat + dLng * dLng)
    }

    // MARK: Data

    private func loadSegments() async {
        isLoading = true
        do {
            let result = try await TravelMappingAPI.shared.getRegionSegments(region: region, traveler: "null")
            segments = result.segments
            routeMetadata = result.routes
            let lats = result.segments.flatMap { [$0.start.latitude, $0.end.latitude] }
            let lngs = result.segments.flatMap { [$0.start.longitude, $0.end.longitude] }
            if let minLat = lats.min(), let maxLat = lats.max(),
               let minLng = lngs.min(), let maxLng = lngs.max() {
                mapPosition = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2),
                    span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.2, 0.05), longitudeDelta: max((maxLng - minLng) * 1.2, 0.05))
                ))
            }
        } catch {
            SentrySDK.capture(error: error)
        }
        isLoading = false
    }
}
