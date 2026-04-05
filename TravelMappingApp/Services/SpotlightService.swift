import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

@MainActor
class SpotlightService {
    static let shared = SpotlightService()

    /// Index all users so they appear in Spotlight search.
    func indexUsers(_ users: [DataService.UserSummary]) {
        var items: [CSSearchableItem] = []

        for user in users {
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = user.username
            attributes.contentDescription = "Travel Mapping user"
            attributes.keywords = ["travelmapping", "travel", "mapping", user.username]

            var categories: [String] = []
            if user.hasRoads { categories.append("Roads") }
            if user.hasRail { categories.append("Rail") }
            if user.hasFerry { categories.append("Ferry") }
            if user.hasScenic { categories.append("Scenic") }
            if !categories.isEmpty {
                attributes.contentDescription = categories.joined(separator: ", ")
            }

            let item = CSSearchableItem(
                uniqueIdentifier: "user.\(user.username)",
                domainIdentifier: "com.psiegel18.TravelMapping.users",
                attributeSet: attributes
            )
            items.append(item)
        }

        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error = error {
                print("Spotlight indexing failed: \(error)")
            }
        }
    }

    func clearIndex() {
        CSSearchableIndex.default().deleteAllSearchableItems()
    }
}
