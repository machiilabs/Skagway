import Foundation
import GRDB

struct CollectionRepository {
    let dbPool: DatabasePool

    // MARK: - Collections CRUD

    func fetchAll() async throws -> [VideoCollection] {
        try await dbPool.read { db in
            try VideoCollection.order(Column("name").collating(.caseInsensitiveCompare).asc).fetchAll(db)
        }
    }

    @discardableResult
    func insert(_ collection: VideoCollection) async throws -> VideoCollection {
        try await dbPool.write { db in
            var c = collection
            try c.insert(db)
            return c
        }
    }

    func update(_ collection: VideoCollection) async throws {
        try await dbPool.write { db in
            try collection.update(db)
        }
    }

    func delete(_ collection: VideoCollection) async throws {
        _ = try await dbPool.write { db in
            try collection.delete(db)
        }
    }

    // MARK: - Rule Groups CRUD

    func fetchRuleGroups(for collectionId: Int64) async throws -> [CollectionRuleGroup] {
        try await dbPool.read { db in
            try CollectionRuleGroup
                .filter(Column("collectionId") == collectionId)
                .order(Column("orderIndex").asc)
                .fetchAll(db)
        }
    }

    func fetchRules(for collectionId: Int64) async throws -> [CollectionRule] {
        try await dbPool.read { db in
            try CollectionRule
                .filter(Column("collectionId") == collectionId)
                .fetchAll(db)
        }
    }

    func fetchAllRuleGroupsGrouped() async throws -> [Int64: [CollectionRuleGroup]] {
        try await dbPool.read { db in
            let groups = try CollectionRuleGroup.order(Column("orderIndex").asc).fetchAll(db)
            return Dictionary(grouping: groups, by: \.collectionId)
        }
    }

    func fetchAllRulesGrouped() async throws -> [Int64: [CollectionRule]] {
        try await dbPool.read { db in
            let rules = try CollectionRule.fetchAll(db)
            return Dictionary(grouping: rules, by: \.collectionId)
        }
    }

    /// Replaces every rule group (and its rules) for a collection in one transaction. Deleting the
    /// old groups cascades to delete their rules (`collection_rule.groupId` FK `onDelete: .cascade`).
    func replaceRuleGroups(
        for collectionId: Int64,
        with groups: [(mode: MatchMode, rules: [CollectionRule])]
    ) async throws {
        try await dbPool.write { db in
            try CollectionRuleGroup
                .filter(Column("collectionId") == collectionId)
                .deleteAll(db)

            for (index, group) in groups.enumerated() {
                var g = CollectionRuleGroup(collectionId: collectionId, orderIndex: index, matchMode: group.mode)
                try g.insert(db)
                guard let groupId = g.id else { continue }
                for rule in group.rules {
                    var r = rule
                    r.collectionId = collectionId
                    r.groupId = groupId
                    try r.insert(db)
                }
            }
        }
    }

    /// Insert or update a collection and replace its rule groups in one transaction.
    @discardableResult
    func saveSmartCollection(
        _ collection: VideoCollection,
        groups: [(mode: MatchMode, rules: [CollectionRule])]
    ) async throws -> VideoCollection {
        try await dbPool.write { db in
            var c = collection
            if c.id == nil {
                try c.insert(db)
            } else {
                try c.update(db)
            }
            guard let collectionId = c.id else {
                throw DatabaseError(message: "Collection insert did not produce an id")
            }

            try CollectionRuleGroup
                .filter(Column("collectionId") == collectionId)
                .deleteAll(db)

            for (index, group) in groups.enumerated() {
                var g = CollectionRuleGroup(collectionId: collectionId, orderIndex: index, matchMode: group.mode)
                try g.insert(db)
                guard let groupId = g.id else { continue }
                for rule in group.rules {
                    var r = rule
                    r.collectionId = collectionId
                    r.groupId = groupId
                    try r.insert(db)
                }
            }
            return c
        }
    }

    // MARK: - Album membership (manual collections)

    /// All album memberships: collectionId → video database ids in playlist order.
    func fetchAllAlbumMemberships() async throws -> [Int64: [Int64]] {
        try await dbPool.read { db in
            let rows = try CollectionVideo
                .order(Column("collectionId").asc, Column("sortIndex").asc, Column("videoId").asc)
                .fetchAll(db)
            var map: [Int64: [Int64]] = [:]
            for row in rows {
                map[row.collectionId, default: []].append(row.videoId)
            }
            return map
        }
    }

    func addVideos(_ videoIds: [Int64], toAlbum collectionId: Int64) async throws {
        guard !videoIds.isEmpty else { return }
        let now = Date()
        try await dbPool.write { db in
            let existing = try Int64.fetchAll(
                db,
                sql: "SELECT videoId FROM collection_video WHERE collectionId = ?",
                arguments: [collectionId]
            )
            let existingSet = Set(existing)
            let maxIndex = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sortIndex), -1) FROM collection_video WHERE collectionId = ?",
                arguments: [collectionId]
            ) ?? -1
            var nextIndex = maxIndex + 1
            for videoId in videoIds where !existingSet.contains(videoId) {
                var row = CollectionVideo(
                    videoId: videoId,
                    collectionId: collectionId,
                    dateAdded: now,
                    sortIndex: nextIndex
                )
                try row.insert(db, onConflict: .ignore)
                nextIndex += 1
            }
        }
    }

    func removeVideos(_ videoIds: [Int64], fromAlbum collectionId: Int64) async throws {
        guard !videoIds.isEmpty else { return }
        try await dbPool.write { db in
            try CollectionVideo
                .filter(Column("collectionId") == collectionId)
                .filter(videoIds.contains(Column("videoId")))
                .deleteAll(db)
        }
    }

    /// Replaces album membership with exactly `videoIds` (used when creating from selection).
    /// `videoIds` order becomes the playlist order.
    func replaceAlbumMembership(for collectionId: Int64, videoIds: [Int64]) async throws {
        let now = Date()
        try await dbPool.write { db in
            try CollectionVideo
                .filter(Column("collectionId") == collectionId)
                .deleteAll(db)
            for (index, videoId) in videoIds.enumerated() {
                var row = CollectionVideo(
                    videoId: videoId,
                    collectionId: collectionId,
                    dateAdded: now,
                    sortIndex: index
                )
                try row.insert(db)
            }
        }
    }

    /// Writes playlist order for an existing album. `videoIds` must be the full membership list.
    func replaceAlbumOrder(for collectionId: Int64, videoIds: [Int64]) async throws {
        try await dbPool.write { db in
            for (index, videoId) in videoIds.enumerated() {
                try db.execute(
                    sql: """
                        UPDATE collection_video
                        SET sortIndex = ?
                        WHERE collectionId = ? AND videoId = ?
                        """,
                    arguments: [index, collectionId, videoId]
                )
            }
        }
    }
}

// MARK: - Rule Matching Engine

extension CollectionRepository {
    /// Builds the unified `FilterGroup` for a collection: an outer group in the collection's mode,
    /// whose nodes are one sub-group per rule group (in `orderIndex` order), each holding its rules
    /// as conditions. This single representation is what the shared `FilterMatcher` compiles, so
    /// Collections and (Phase 3) the live advanced filter run through the exact same engine.
    static func filterGroup(
        for collection: VideoCollection,
        groups: [CollectionRuleGroup],
        rulesByGroup: [Int64: [CollectionRule]]
    ) -> FilterGroup {
        let ordered = groups.sorted { $0.orderIndex < $1.orderIndex }
        let nodes: [FilterNode] = ordered.map { g in
            let conditions = (rulesByGroup[g.id ?? -1] ?? []).map { r in
                FilterNode.condition(FilterCondition(field: r.attribute, comparison: r.comparison, value: r.value, value2: r.value2))
            }
            return .group(FilterGroup(mode: g.matchMode, nodes: conditions))
        }
        return FilterGroup(mode: collection.matchMode, nodes: nodes)
    }

    /// Compiles a collection's already-fetched groups + rules into the shared `FilterMatcher`.
    /// `customFields` supplies definitions for any custom-field rules (empty is fine for the common
    /// built-in-only case).
    func compileMatcher(
        for collection: VideoCollection,
        groups: [CollectionRuleGroup],
        rulesByGroup: [Int64: [CollectionRule]],
        customFields: [UUID: CustomMetadataFieldDefinition] = [:],
        libraryContext: LibraryFilterContext? = nil,
        collectionRepo: CollectionRepository? = nil
    ) -> FilterMatcher {
        FilterMatcher(
            group: Self.filterGroup(for: collection, groups: groups, rulesByGroup: rulesByGroup),
            customFields: customFields,
            libraryContext: libraryContext,
            collectionRepo: collectionRepo ?? self
        )
    }
}
