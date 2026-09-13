import Foundation
import GRDB

enum MatchMode: String, Codable, CaseIterable {
    case all
    case any
}

/// Smart = rule-based (classic Collection). Album = explicit video membership.
enum CollectionKind: String, Codable, CaseIterable, Hashable {
    case smart
    case album
}

struct VideoCollection: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var name: String
    var dateCreated: Date
    var matchMode: MatchMode
    var kind: CollectionKind

    init(
        id: Int64? = nil,
        name: String,
        dateCreated: Date,
        matchMode: MatchMode = .all,
        kind: CollectionKind = .smart
    ) {
        self.id = id
        self.name = name
        self.dateCreated = dateCreated
        self.matchMode = matchMode
        self.kind = kind
    }

    var listId: String { "collection-\(id ?? 0)" }
    var isAlbum: Bool { kind == .album }
    var isSmart: Bool { kind == .smart }

    private enum CodingKeys: String, CodingKey {
        case id, name, dateCreated, matchMode, kind
    }
}

extension VideoCollection: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "collection"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Join row for Album membership (manual collections).
struct CollectionVideo: Codable, Equatable {
    var videoId: Int64
    var collectionId: Int64
    var dateAdded: Date
    /// Playlist order within the album (0-based). Independent of library sort.
    var sortIndex: Int
}

extension CollectionVideo: FetchableRecord, PersistableRecord {
    static let databaseTableName = "collection_video"
}

// MARK: - Collection Rule Group

/// A cluster of rules within a collection. Rules inside a group combine with `matchMode`; groups
/// themselves combine with the parent `VideoCollection.matchMode` — the "OR of AND-groups" (and
/// vice versa) two-level scheme that lets a collection express mixed AND/OR logic.
struct CollectionRuleGroup: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var collectionId: Int64
    var orderIndex: Int
    var matchMode: MatchMode

    private enum CodingKeys: String, CodingKey {
        case id, collectionId, orderIndex, matchMode
    }
}

extension CollectionRuleGroup: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "collection_rule_group"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Collection Rule

struct CollectionRule: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var collectionId: Int64
    var groupId: Int64
    /// Stored in the `attribute` TEXT column as a `FilterField` token — built-ins keep their exact
    /// `RuleAttribute` rawValue (so existing rows decode unchanged), custom fields use `custom:<uuid>`.
    var attribute: FilterField
    var comparison: RuleComparison
    var value: String
    /// Upper bound for the `.between` operator; nil for every other operator.
    var value2: String?

    init(id: Int64? = nil, collectionId: Int64, groupId: Int64, attribute: FilterField, comparison: RuleComparison, value: String, value2: String? = nil) {
        self.id = id
        self.collectionId = collectionId
        self.groupId = groupId
        self.attribute = attribute
        self.comparison = comparison
        self.value = value
        self.value2 = value2
    }

    private enum CodingKeys: String, CodingKey {
        case id, collectionId, groupId, attribute, comparison, value, value2
    }
}

extension CollectionRule: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "collection_rule"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Rule Attribute

enum RuleAttribute: String, Codable, CaseIterable, Identifiable {
    case name
    case fileExtension
    case path
    case parentFolder
    case volume
    case fileSize
    case duration
    case height
    case width
    /// Resolution bucket derived from `Video.resolutionLabel` (SD…8K+). Distinct from raw
    /// `height`/`width` pixel tests — the value is one or more bucket labels (comma-separated),
    /// matched with OR-within-set semantics via the Quality chip editor.
    case quality
    case codec
    case dateImported
    case dateCreated
    case playCount
    case rating
    case tag
    /// Smart library or album membership (value encodes target via `MembershipTarget`).
    case membership

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Title"
        case .fileExtension: "Extension"
        case .path: "Path"
        case .parentFolder: "Parent Folder"
        case .volume: "Volume"
        case .fileSize: "File Size"
        case .duration: "Duration"
        case .height: "Height"
        case .width: "Width"
        case .quality: "Quality"
        case .codec: "Video Codec"
        case .dateImported: "Date Imported"
        case .dateCreated: "Date Created"
        case .playCount: "Plays"
        case .rating: "Rating"
        case .tag: "Tag"
        case .membership: "Membership"
        }
    }

    var supportedComparisons: [RuleComparison] {
        switch self {
        case .name, .fileExtension, .path, .parentFolder, .volume, .codec, .tag:
            return [.equals, .notEquals, .contains, .startsWith, .endsWith, .matches]
        case .fileSize, .duration, .height, .width, .playCount, .rating:
            return [.equals, .notEquals, .lessThan, .greaterThan, .lessThanOrEqual, .greaterThanOrEqual, .between]
        case .dateImported, .dateCreated:
            return [.equals, .lessThan, .greaterThan, .between]
        case .quality:
            // Chip multi-select: "is any of" / "is none of" the selected buckets.
            return [.equals, .notEquals]
        case .membership:
            return [.isMemberOf, .isNotMemberOf]
        }
    }

    var isNumeric: Bool {
        switch self {
        case .fileSize, .duration, .height, .width, .playCount, .rating:
            return true
        default:
            return false
        }
    }

    var valuePlaceholder: String {
        switch self {
        case .name: "Title or file name"
        case .fileExtension: "mp4, mkv, etc."
        case .path: "/path/to/folder"
        case .parentFolder: "Folder name"
        case .volume: "Volume name"
        case .fileSize: "Size in MB"
        case .duration: "Duration in minutes"
        case .height: "Pixels"
        case .width: "Pixels"
        case .quality: "1080p, 4K, …"
        case .codec: "h264, hevc, etc."
        case .dateImported: "YYYY-MM-DD"
        case .dateCreated: "YYYY-MM-DD"
        case .playCount: "Count"
        case .rating: "1-5"
        case .tag: "Tag name"
        case .membership: "Smart library or album"
        }
    }
}

// MARK: - Rule Comparison

enum RuleComparison: String, Codable, CaseIterable, Identifiable {
    case equals
    case notEquals
    case contains
    case startsWith
    case endsWith
    case matches
    case lessThan
    case greaterThan
    case lessThanOrEqual
    case greaterThanOrEqual
    /// Inclusive range using both `value` (lower) and `value2` (upper). Added in the Phase 2
    /// filter-engine unification; older stored rules never use it.
    case between
    /// Custom metadata: no stored value, or whitespace-only / unset boolean.
    case isEmpty
    /// Custom metadata: has a stored, non-blank value.
    case isNotEmpty
    /// Membership: video belongs to the chosen smart library, collection, or album.
    case isMemberOf
    /// Membership: video does not belong to the chosen target.
    case isNotMemberOf

    var id: String { rawValue }

    var label: String {
        switch self {
        case .equals: "equals"
        case .notEquals: "does not equal"
        case .contains: "contains"
        case .startsWith: "starts with"
        case .endsWith: "ends with"
        case .matches: "matches"
        case .lessThan: "is less than"
        case .greaterThan: "is greater than"
        case .lessThanOrEqual: "is at most"
        case .greaterThanOrEqual: "is at least"
        case .between: "is between"
        case .isEmpty: "is empty"
        case .isNotEmpty: "is not empty"
        case .isMemberOf: "is member of"
        case .isNotMemberOf: "is not member of"
        }
    }

    /// Whether this operator consumes a second value (`FilterCondition.value2`).
    var usesSecondValue: Bool { self == .between }

    /// Whether this operator needs `FilterCondition.value` (and a value editor in the UI).
    var usesValue: Bool {
        switch self {
        case .isEmpty, .isNotEmpty: return false
        default: return true
        }
    }
}
