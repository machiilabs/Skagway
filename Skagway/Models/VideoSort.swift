import SwiftUI

enum VideoSort: String, CaseIterable, Identifiable {
    case name
    case dateAdded
    case duration
    case fileSize
    case rating
    case resolution
    case playCount

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name: return "Title"
        case .dateAdded: return "Date Added"
        case .duration: return "Duration"
        case .fileSize: return "File Size"
        case .rating: return "Rating"
        case .resolution: return "Resolution"
        case .playCount: return "Plays"
    }
    }

    func comparators(ascending: Bool) -> [KeyPathComparator<Video>] {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .name: return [KeyPathComparator(\Video.displayTitle, order: order)]
        case .duration: return [KeyPathComparator(\Video.sortableDuration, order: order)]
        case .fileSize: return [KeyPathComparator(\Video.fileSize, order: order)]
        case .rating: return [KeyPathComparator(\Video.rating, order: order)]
        case .resolution: return [
            KeyPathComparator(\Video.sortableResolutionHeight, order: order),
            KeyPathComparator(\Video.sortablePixelCount, order: order),
        ]
        case .playCount: return [KeyPathComparator(\Video.playCount, order: order)]
        case .dateAdded: return [KeyPathComparator(\Video.dateAdded, order: order)]
    }
    }

    static func from(keyPath: PartialKeyPath<Video>) -> VideoSort {
        if keyPath == \Video.displayTitle as PartialKeyPath<Video> { return .name }
        if keyPath == \Video.fileName as PartialKeyPath<Video> { return .name }
        if keyPath == \Video.sortableDuration as PartialKeyPath<Video> { return .duration }
        if keyPath == \Video.fileSize as PartialKeyPath<Video> { return .fileSize }
        if keyPath == \Video.rating as PartialKeyPath<Video> { return .rating }
        if keyPath == \Video.sortableResolutionHeight as PartialKeyPath<Video> { return .resolution }
        if keyPath == \Video.sortablePixelCount as PartialKeyPath<Video> { return .resolution }
        if keyPath == \Video.playCount as PartialKeyPath<Video> { return .playCount }
        if keyPath == \Video.sortablePlayCount as PartialKeyPath<Video> { return .playCount }
        if keyPath == \Video.dateAdded as PartialKeyPath<Video> { return .dateAdded }
        return .dateAdded
    }
}

enum ViewMode: String, CaseIterable {
    case grid, list, storyboard

    /// Poster grid and storyboard wall share LazyVGrid browsing (not the list table).
    var isWall: Bool {
        switch self {
        case .grid, .storyboard: return true
        case .list: return false
        }
    }
}

/// Storyboard View packing only (persisted separately from Grid/List).
enum StoryboardDensity: String, CaseIterable, Identifiable {
    case compact
    case comfortable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        }
    }
}

/// Media shown inside a Curated Wall card (poster still vs 2×3 storyboard collage).
enum WallCardMediaMode: String {
    case poster
    case storyboard
}

enum GridSize: String, CaseIterable {
    case small, medium, large

    var label: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }

    var cellWidth: CGFloat {
        switch self {
        case .small: return 140
        case .medium: return 220
        case .large: return 320
        }
    }

    var thumbnailHeight: CGFloat {
        switch self {
        case .small: return 80
        case .medium: return 140
        case .large: return 220
        }
    }

    var gridSpacing: CGFloat {
        switch self {
        case .small: return 10
        case .medium: return 14
        case .large: return 18
        }
    }

    func columns(for availableWidth: CGFloat) -> [GridItem] {
        let count = max(1, Int((availableWidth + gridSpacing) / (cellWidth + gridSpacing)))
        let itemWidth = (availableWidth - CGFloat(count - 1) * gridSpacing) / CGFloat(count)
        return Array(repeating: GridItem(.fixed(itemWidth), spacing: gridSpacing), count: count)
    }

    /// Approximate cell height for one row in the library grid (used for fast NSScrollView jumps).
    /// Tuned to match `VideoGridCell` (thumb + text + optional metadata + paddings); slight slack avoids underscrolling.
    var estimatedScrollCellHeight: CGFloat {
        switch self {
        case .small:
            return thumbnailHeight + 44 + 20
        case .medium:
            return thumbnailHeight + 72 + 36
        case .large:
            return thumbnailHeight + 96 + 40
        }
    }
}

enum SidebarFilter: Hashable {
    case all
    case recentlyAdded
    case recentlyPlayed
    case topRated
    case duplicates
    case corrupt
    case missing
    case recentlyConverted
    /// Videos matched by the last successful Import Metadata run (path set).
    case recentlyApplied
    /// Videos successfully imported by the most recent media-add scan (path set).
    case lastAdded
    case collection(VideoCollection)
}

struct LibraryCounts {
    var all: Int = 0
    var recentlyAdded: Int = 0
    var recentlyPlayed: Int = 0
    var topRated: Int = 0
    var duplicates: Int = 0
    var corrupt: Int = 0
    var missing: Int = 0
    var recentlyConverted: Int = 0
    var recentlyApplied: Int = 0
    var lastAdded: Int = 0
    var byRating: [Int: Int] = [:]
}
