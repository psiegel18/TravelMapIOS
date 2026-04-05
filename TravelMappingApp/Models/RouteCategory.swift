import Foundation

enum RouteCategory: String, CaseIterable, Identifiable {
    case road = "Roads"
    case rail = "Rail & Transit"
    case ferry = "Ferries"
    case scenic = "Scenic Routes"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .road: return "list"
        case .rail: return "rlist"
        case .ferry: return "flist"
        case .scenic: return "slist"
        }
    }

    var directoryName: String {
        switch self {
        case .road: return "list_files"
        case .rail: return "rlist_files"
        case .ferry: return "flist_files"
        case .scenic: return "slist_files"
        }
    }

    var systemImage: String {
        switch self {
        case .road: return "car.fill"
        case .rail: return "tram.fill"
        case .ferry: return "ferry.fill"
        case .scenic: return "leaf.fill"
        }
    }
}
