import Foundation

/// Compiles active Quick Filter controls into a single Advanced `FilterGroup` (top-level ALL).
enum QuickFilterCompiler {
    struct Input: Equatable {
        var sidebarFilter: SidebarFilter?
        /// Pre-built smart collection rules when `sidebarFilter` is a smart collection.
        var collectionGroup: FilterGroup?
        var tags: [Tag]
        var selectedTagIds: Set<Int64>
        var tagFilterMode: MatchMode
        var selectedRatingStars: Set<Int>
        var ratingFilterOrHigher: Bool
        var minDurationSeconds: Double?
        var maxDurationSeconds: Double?
        var selectedQualityBuckets: Set<String>
        var topRatedMinRating: Int
    }

    /// Builds a top-level ALL group from mappable Quick Filter state, or nil when nothing applies.
    static func compile(_ input: Input) -> FilterGroup? {
        var nodes: [FilterNode] = []

        nodes.append(contentsOf: sidebarNodes(from: input))

        if let tagGroup = tagGroup(from: input) {
            nodes.append(.group(tagGroup))
        }

        if let rating = ratingCondition(from: input) {
            nodes.append(.condition(rating))
        }

        nodes.append(contentsOf: durationConditions(from: input))

        if let quality = qualityCondition(from: input) {
            nodes.append(.condition(quality))
        }

        guard !nodes.isEmpty else { return nil }
        return FilterGroup(mode: .all, nodes: nodes)
    }

    // MARK: - Sidebar

    private static func sidebarNodes(from input: Input) -> [FilterNode] {
        guard let filter = input.sidebarFilter else { return [] }
        switch filter {
        case .all:
            return []
        case .collection(let collection):
            guard let id = collection.id else { return [] }
            if collection.isAlbum {
                return [membershipNode(.album(id))]
            }
            if collection.isSmart {
                guard let group = input.collectionGroup, !group.isEmpty else { return [] }
                return collectionNodes(from: group)
            }
            return []
        default:
            guard let kind = SmartLibraryKind(sidebarFilter: filter) else { return [] }
            return [membershipNode(.smartLibrary(kind))]
        }
    }

    private static func membershipNode(_ target: MembershipTarget) -> FilterNode {
        .condition(FilterCondition(
            field: .builtin(.membership),
            comparison: .isMemberOf,
            value: target.storageToken
        ))
    }

    /// Flattens smart-collection rules into sibling nodes under the compiled top-level ALL group.
    private static func collectionNodes(from group: FilterGroup) -> [FilterNode] {
        group.nodes.flatMap { node -> [FilterNode] in
            switch node {
            case .condition:
                return [node]
            case .group(let inner):
                if inner.nodes.count == 1, case .condition = inner.nodes[0] {
                    return inner.nodes
                }
                return [.group(inner)]
            }
        }
    }

    // MARK: - Tags

    private static func tagGroup(from input: Input) -> FilterGroup? {
        guard !input.selectedTagIds.isEmpty else { return nil }
        let namesById = Dictionary(uniqueKeysWithValues: input.tags.compactMap { tag -> (Int64, String)? in
            guard let id = tag.id else { return nil }
            return (id, tag.name)
        })
        let conditions: [FilterNode] = input.selectedTagIds.sorted().compactMap { id in
            guard let name = namesById[id] else { return nil }
            return .condition(FilterCondition(
                field: .builtin(.tag),
                comparison: .equals,
                value: name
            ))
        }
        guard !conditions.isEmpty else { return nil }
        return FilterGroup(mode: input.tagFilterMode, nodes: conditions)
    }

    // MARK: - Rating

    private static func ratingCondition(from input: Input) -> FilterCondition? {
        guard let floor = input.selectedRatingStars.min() else { return nil }
        if floor == 0 {
            return FilterCondition(field: .builtin(.rating), comparison: .equals, value: "0")
        }
        if input.ratingFilterOrHigher, floor < 5 {
            return FilterCondition(
                field: .builtin(.rating),
                comparison: .greaterThanOrEqual,
                value: String(floor)
            )
        }
        return FilterCondition(field: .builtin(.rating), comparison: .equals, value: String(floor))
    }

    // MARK: - Duration

    private static func durationConditions(from input: Input) -> [FilterNode] {
        let minMinutes = input.minDurationSeconds.map { $0 / 60.0 }
        let maxMinutes = input.maxDurationSeconds.map { $0 / 60.0 }

        switch (minMinutes, maxMinutes) {
        case let (min?, max?):
            return [.condition(FilterCondition(
                field: .builtin(.duration),
                comparison: .between,
                value: formatMinutes(min),
                value2: formatMinutes(max)
            ))]
        case let (min?, nil):
            return [.condition(FilterCondition(
                field: .builtin(.duration),
                comparison: .greaterThanOrEqual,
                value: formatMinutes(min)
            ))]
        case let (nil, max?):
            return [.condition(FilterCondition(
                field: .builtin(.duration),
                comparison: .lessThanOrEqual,
                value: formatMinutes(max)
            ))]
        case (nil, nil):
            return []
        }
    }

    private static func formatMinutes(_ minutes: Double) -> String {
        if minutes.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(minutes))
        }
        return String(minutes)
    }

    // MARK: - Quality

    private static func qualityCondition(from input: Input) -> FilterCondition? {
        guard !input.selectedQualityBuckets.isEmpty else { return nil }
        let ordered = ResolutionBucket.allCases
            .map(\.rawValue)
            .filter { input.selectedQualityBuckets.contains($0) }
        guard !ordered.isEmpty else { return nil }
        return FilterCondition(
            field: .builtin(.quality),
            comparison: .equals,
            value: ResolutionBucket.encode(Set(ordered))
        )
    }
}
