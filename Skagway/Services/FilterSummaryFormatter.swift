import Foundation

/// Human-readable summaries for Advanced Filter and smart collection rule trees.
enum FilterSummaryFormatter {
    /// Max leaf conditions shown before appending "(+N more)" on collection synopses.
    static let collectionSynopsisMaxConditions = 3

    /// Builds a filter summary. When `maxConditions` is set, flattens leaf rules and caps the
    /// count (collection synopses). When `nil`, preserves nested group structure (Advanced Filter).
    static func filterGroupSummary(
        _ group: FilterGroup,
        customFields: [UUID: CustomMetadataFieldDefinition],
        maxConditions: Int? = nil
    ) -> String? {
        guard !group.isEmpty else { return nil }
        let text: String
        if let maxConditions {
            text = describeFilterGroupCapped(group, customFields: customFields, maxConditions: maxConditions)
        } else {
            text = describeFilterGroup(group, customFields: customFields)
        }
        return text.isEmpty ? nil : text
    }

    /// Closed-drawer pill label: `"Name: first rule"` or `"Name: first rule ..."` when more rules exist.
    static func labeledCollectionPillText(
        collectionName: String,
        group: FilterGroup,
        customFields: [UUID: CustomMetadataFieldDefinition],
        maxLength: Int = 48
    ) -> String? {
        let conditions = flattenConditions(in: group)
        guard let first = conditions.first else { return nil }
        let firstDesc = describeCondition(first, customFields: customFields)
        let hasMore = conditions.count > 1
        return truncatedCollectionLabel(
            name: collectionName,
            condition: firstDesc,
            hasMore: hasMore,
            maxLength: maxLength
        )
    }

    private static func truncatedCollectionLabel(
        name: String,
        condition: String,
        hasMore: Bool,
        maxLength: Int
    ) -> String {
        let suffix = hasMore ? " ..." : ""
        let prefix = "\(name): "
        let full = prefix + condition + suffix
        if full.count <= maxLength { return full }

        let budget = maxLength - prefix.count - suffix.count
        guard budget > 1 else { return name }
        if condition.count <= budget { return prefix + condition + suffix }

        let trimmed = String(condition.prefix(budget - 1)) + "…"
        return prefix + trimmed + suffix
    }

    private static func flattenConditions(in group: FilterGroup) -> [FilterCondition] {
        group.nodes.flatMap { node -> [FilterCondition] in
            switch node {
            case .condition(let condition):
                return [condition]
            case .group(let inner):
                return flattenConditions(in: inner)
            }
        }
    }

    private static func describeFilterGroupCapped(
        _ group: FilterGroup,
        customFields: [UUID: CustomMetadataFieldDefinition],
        maxConditions: Int
    ) -> String {
        let all = flattenConditions(in: group)
        guard !all.isEmpty else { return "" }
        let shown = all.prefix(maxConditions)
        let parts = shown.map { describeCondition($0, customFields: customFields) }
        var result = parts.joined(separator: " · ")
        let remaining = all.count - shown.count
        if remaining > 0 {
            result += " (+\(remaining) more)"
        }
        return result
    }

    private static func describeFilterGroup(
        _ group: FilterGroup,
        customFields: [UUID: CustomMetadataFieldDefinition]
    ) -> String {
        let parts: [String] = group.nodes.compactMap { node in
            switch node {
            case .condition(let c):
                return describeCondition(c, customFields: customFields)
            case .group(let inner):
                let innerParts = inner.nodes.compactMap { child -> String? in
                    guard case .condition(let c) = child else { return nil }
                    return describeCondition(c, customFields: customFields)
                }
                guard !innerParts.isEmpty else { return nil }
                let joiner = inner.mode == .all ? " AND " : " OR "
                let joined = innerParts.joined(separator: joiner)
                if group.nodes.count > 1 || inner.mode == .any {
                    return "(\(joined))"
                }
                return joined
            }
        }
        let joiner = group.mode == .all ? " · " : " OR "
        return parts.joined(separator: joiner)
    }

    private static func describeCondition(
        _ c: FilterCondition,
        customFields: [UUID: CustomMetadataFieldDefinition]
    ) -> String {
        let field = c.field.label(customFields: customFields)
        if case .builtin(.quality) = c.field {
            let buckets = ResolutionBucket.decode(c.value)
            let list = ResolutionBucket.allCases.map(\.rawValue).filter { buckets.contains($0) }.joined(separator: ", ")
            let verb = c.comparison == .notEquals ? "is none of" : "is"
            return list.isEmpty ? field : "\(field) \(verb) \(list)"
        }
        let op = c.comparison.label
        if !c.comparison.usesValue {
            return "\(field) \(op)"
        }
        if c.comparison.usesSecondValue, let v2 = c.value2 {
            return "\(field) \(op) \(c.value) and \(v2)"
        }
        return "\(field) \(op) \(c.value)"
    }
}
