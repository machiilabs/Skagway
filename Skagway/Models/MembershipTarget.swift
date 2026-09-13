import Foundation

/// Built-in smart libraries exposed through the Membership filter attribute.
enum SmartLibraryKind: String, CaseIterable, Codable, Identifiable {
    case recentlyAdded
    case recentlyPlayed
    case topRated
    case duplicates
    case corrupt
    case missing
    case recentlyConverted
    case recentlyApplied
    case lastAdded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .recentlyPlayed: "Recently Played"
        case .topRated: "Top Rated"
        case .duplicates: "Duplicates"
        case .corrupt: "Corrupt"
        case .missing: "Missing"
        case .recentlyConverted: "Recently Converted"
        case .recentlyApplied: "Last Metadata Import"
        case .lastAdded: "Last Added"
        }
    }

    init?(sidebarFilter: SidebarFilter) {
        switch sidebarFilter {
        case .recentlyAdded: self = .recentlyAdded
        case .recentlyPlayed: self = .recentlyPlayed
        case .topRated: self = .topRated
        case .duplicates: self = .duplicates
        case .corrupt: self = .corrupt
        case .missing: self = .missing
        case .recentlyConverted: self = .recentlyConverted
        case .recentlyApplied: self = .recentlyApplied
        case .lastAdded: self = .lastAdded
        default: return nil
        }
    }
}

/// Smart library or album referenced by a Membership rule value (not saved smart collections).
enum MembershipTarget: Equatable, Hashable {
    case smartLibrary(SmartLibraryKind)
    case album(Int64)

    var storageToken: String {
        switch self {
        case .smartLibrary(let kind):
            return "smartLibrary:\(kind.rawValue)"
        case .album(let id):
            return "album:\(id)"
        }
    }

    init?(storageToken: String) {
        let parts = storageToken.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "smartLibrary":
            guard let kind = SmartLibraryKind(rawValue: parts[1]) else { return nil }
            self = .smartLibrary(kind)
        case "album":
            guard let id = Int64(parts[1]) else { return nil }
            self = .album(id)
        default:
            return nil
        }
    }

    func displayLabel(collections: [VideoCollection]) -> String {
        switch self {
        case .smartLibrary(let kind):
            return kind.label
        case .album(let id):
            return collections.first { $0.id == id }?.name ?? "(deleted)"
        }
    }
}
