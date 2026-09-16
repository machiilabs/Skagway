import Foundation
import GRDB

struct VideoRepository {
    let dbPool: DatabasePool

    func fetchAll() async throws -> [Video] {
        try await dbPool.read { db in
            try Video.order(Column("dateAdded").desc).fetchAll(db)
        }
    }

    func search(_ query: String) async throws -> [Video] {
        try await dbPool.read { db in
            if query.isEmpty { return try Video.fetchAll(db) }
            let terms = query
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !terms.isEmpty else { return try Video.fetchAll(db) }
            // Contains (*term*), AND logic, case-insensitive across title, file names, tags,
            // and custom metadata values. Each term may match a different field.
            let termClause = """
                (
                    LOWER(video.title) LIKE ? ESCAPE '\\'
                    OR LOWER(video.fileName) LIKE ? ESCAPE '\\'
                    OR LOWER(video.originalFileName) LIKE ? ESCAPE '\\'
                    OR EXISTS (
                        SELECT 1 FROM video_tag vt
                        JOIN tag t ON t.id = vt.tagId
                        WHERE vt.videoId = video.id AND LOWER(t.name) LIKE ? ESCAPE '\\'
                    )
                    OR EXISTS (
                        SELECT 1 FROM video_custom_metadata cm
                        WHERE cm.videoId = video.id AND LOWER(cm.value) LIKE ? ESCAPE '\\'
                    )
                )
                """
            let conditions = Array(repeating: termClause, count: terms.count).joined(separator: " AND ")
            let args = terms.flatMap { term -> [String] in
                let pattern = "%\(Self.escapeLike(term))%".lowercased()
                return Array(repeating: pattern, count: 5)
            }
            let sql = """
                SELECT video.* FROM video
                WHERE \(conditions)
                ORDER BY video.dateAdded DESC
                """
            return try Video.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// Escapes % _ \ for use in SQLite LIKE patterns with ESCAPE '\\'
    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    func fetchByMinRating(_ rating: Int) async throws -> [Video] {
        try await dbPool.read { db in
            try Video
                .filter(Column("rating") >= rating)
                .order(Column("rating").desc)
                .fetchAll(db)
        }
    }

    @discardableResult
    func insert(_ video: Video) async throws -> Video {
        try await dbPool.write { db in
            var v = video
            try v.insert(db)
            return v
        }
    }

    func update(_ video: Video) async throws {
        try await dbPool.write { db in
            try video.update(db)
        }
    }

    func delete(_ video: Video) async throws {
        _ = try await dbPool.write { db in
            try video.delete(db)
        }
    }

    func updateRating(videoId: Int64, rating: Int) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE video SET rating = ? WHERE id = ?",
                arguments: [rating, videoId]
            )
        }
    }

    func updateRating(videoIds: [Int64], rating: Int) async throws {
        try await dbPool.write { db in
            for id in videoIds {
                try db.execute(
                    sql: "UPDATE video SET rating = ? WHERE id = ?",
                    arguments: [rating, id]
                )
            }
        }
    }

    func updateThumbnailPath(videoId: Int64, path: String) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE video SET thumbnailPath = ? WHERE id = ?",
                arguments: [path, videoId]
            )
        }
    }

    /// Bulk thumbnail-path remaps (e.g. after Repair Links cache-key migration).
    func updateThumbnailPaths(updates: [(videoId: Int64, path: String)]) async throws {
        guard !updates.isEmpty else { return }
        try await dbPool.write { db in
            for (id, path) in updates {
                try db.execute(
                    sql: "UPDATE video SET thumbnailPath = ? WHERE id = ?",
                    arguments: [path, id]
                )
            }
        }
    }

    func updateSubtitlePresence(videoId: Int64, presence: SubtitlePresence) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE video SET hasSubtitles = ? WHERE id = ?",
                arguments: [presence.rawValue, videoId]
            )
        }
    }

    /// Bulk update of subtitle presence in a single transaction. A no-op for an empty array.
    func updateSubtitlePresence(updates: [(videoId: Int64, presence: SubtitlePresence)]) async throws {
        guard !updates.isEmpty else { return }
        try await dbPool.write { db in
            for (id, presence) in updates {
                try db.execute(
                    sql: "UPDATE video SET hasSubtitles = ? WHERE id = ?",
                    arguments: [presence.rawValue, id]
                )
            }
        }
    }

    /// Bulk write of computed content fingerprints in one transaction (used by the backfill).
    /// Each tuple is `(videoId, fingerprint)`. No-op for an empty array.
    func updateContentFingerprint(updates: [(videoId: Int64, fingerprint: String)]) async throws {
        guard !updates.isEmpty else { return }
        try await dbPool.write { db in
            for (id, fp) in updates {
                try db.execute(
                    sql: "UPDATE video SET contentFingerprint = ? WHERE id = ?",
                    arguments: [fp, id]
                )
            }
        }
    }

    /// Clear the stored fingerprint for a video (e.g. after a re-encode replaces the file) so the
    /// backfill recomputes it from the new content.
    func clearContentFingerprint(videoId: Int64) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE video SET contentFingerprint = NULL WHERE id = ?",
                arguments: [videoId]
            )
        }
    }

    // MARK: - "Not a duplicate" pairs

    func fetchNotDuplicatePairs() async throws -> [VideoNotDuplicatePair] {
        try await dbPool.read { db in
            try VideoNotDuplicatePair.fetchAll(db)
        }
    }

    /// Insert confirmed-distinct pairs (idempotent — existing rows are ignored). Pairs are
    /// normalized by `VideoNotDuplicatePair.init`, so order doesn't matter.
    func insertNotDuplicatePairs(_ pairs: [VideoNotDuplicatePair]) async throws {
        guard !pairs.isEmpty else { return }
        try await dbPool.write { db in
            for pair in pairs {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO video_not_duplicate (videoIdA, videoIdB) VALUES (?, ?)",
                    arguments: [pair.videoIdA, pair.videoIdB]
                )
            }
        }
    }

    func deleteAllNotDuplicatePairs() async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM video_not_duplicate")
        }
    }

    func recordPlay(videoId: Int64) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE video SET lastPlayed = ?, playCount = playCount + 1 WHERE id = ?",
                arguments: [Date(), videoId]
            )
        }
    }

    func videoExists(filePath: String) async throws -> Bool {
        try await dbPool.read { db in
            try Video.filter(Column("filePath") == filePath).fetchCount(db) > 0
        }
    }

    func renameVideo(videoId: Int64, newFilePath: String, newFileName: String, previousFileName: String) async throws {
        try await dbPool.write { db in
            // Keep title in sync when it still matched the old on-disk name (default after import).
            try db.execute(
                sql: """
                    UPDATE video SET
                        filePath = ?,
                        fileName = ?,
                        title = CASE WHEN title = ? OR title = '' THEN ? ELSE title END
                    WHERE id = ?
                    """,
                arguments: [newFilePath, newFileName, previousFileName, newFileName, videoId]
            )
        }
    }

    /// Batch path remap for Location Relink. One library transaction; file names stay the same
    /// (only the directory prefix changes). Does not touch titles, ratings, tags, or collections.
    func relinkFilePaths(
        mappings: [(videoId: Int64, newFilePath: String)]
    ) async throws {
        guard !mappings.isEmpty else { return }
        try await dbPool.write { db in
            for item in mappings {
                try db.execute(
                    sql: "UPDATE video SET filePath = ? WHERE id = ?",
                    arguments: [item.newFilePath, item.videoId]
                )
            }
        }
    }

    /// Bulk set of play counts (Import Metadata). Does not touch `lastPlayed`.
    func updatePlayCount(updates: [(videoId: Int64, playCount: Int)]) async throws {
        guard !updates.isEmpty else { return }
        try await dbPool.write { db in
            for (id, count) in updates {
                try db.execute(
                    sql: "UPDATE video SET playCount = ? WHERE id = ?",
                    arguments: [count, id]
                )
            }
        }
    }

    func updateTitle(videoId: Int64, title: String) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE video SET title = ? WHERE id = ?",
                arguments: [title, videoId]
            )
        }
    }

    func fetchAllFilePaths() async throws -> Set<String> {
        try await dbPool.read { db in
            let paths = try String.fetchAll(db, sql: "SELECT filePath FROM video")
            return Set(paths)
        }
    }

    /// All custom metadata rows for the given videos (chunked for large `IN` lists).
    func fetchCustomMetadata(forVideoIds videoIds: [Int64]) async throws -> [Int64: [String: String]] {
        let unique = Array(Set(videoIds))
        guard !unique.isEmpty else { return [:] }
        return try await dbPool.read { db in
            var result: [Int64: [String: String]] = [:]
            let chunkSize = 500
            var i = 0
            while i < unique.count {
                let end = min(i + chunkSize, unique.count)
                let chunk = Array(unique[i..<end])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let sql = """
                    SELECT videoId, fieldId, value FROM video_custom_metadata
                    WHERE videoId IN (\(placeholders))
                    """
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(chunk))
                for row in rows {
                    let vid: Int64 = row["videoId"]
                    let fieldId: String = row["fieldId"]
                    let value: String = row["value"]
                    var inner = result[vid] ?? [:]
                    inner[fieldId] = value
                    result[vid] = inner
                }
                i = end
            }
            return result
        }
    }

    /// `fieldId` is the custom field definition UUID string.
    func fetchCustomMetadata(forVideoId videoId: Int64) async throws -> [String: String] {
        try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT fieldId, value FROM video_custom_metadata WHERE videoId = ?",
                arguments: [videoId]
            )
            var out: [String: String] = [:]
            for row in rows {
                out[row["fieldId"]] = row["value"]
            }
            return out
        }
    }

    func upsertCustomMetadata(videoId: Int64, fieldId: UUID, value: String) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO video_custom_metadata (videoId, fieldId, value)
                VALUES (?, ?, ?)
                ON CONFLICT(videoId, fieldId) DO UPDATE SET value = excluded.value
                """,
                arguments: [videoId, fieldId.uuidString, value]
            )
        }
    }

    func upsertCustomMetadata(videoIds: [Int64], fieldId: UUID, value: String) async throws {
        guard !videoIds.isEmpty else { return }
        try await dbPool.write { db in
            for videoId in videoIds {
                try db.execute(
                    sql: """
                    INSERT INTO video_custom_metadata (videoId, fieldId, value)
                    VALUES (?, ?, ?)
                    ON CONFLICT(videoId, fieldId) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [videoId, fieldId.uuidString, value]
                )
            }
        }
    }

    /// Removes all stored values for the given custom field definition IDs.
    func deleteCustomMetadata(fieldIds: Set<UUID>) throws {
        guard !fieldIds.isEmpty else { return }
        try dbPool.write { db in
            for fieldId in fieldIds {
                try db.execute(
                    sql: "DELETE FROM video_custom_metadata WHERE fieldId = ?",
                    arguments: [fieldId.uuidString]
                )
            }
        }
    }
}
