import Foundation
import GRDB

struct ExcludedFolderRepository {
    let dbPool: DatabasePool

    func fetchAll() async throws -> [ExcludedFolder] {
        try await dbPool.read { db in
            try ExcludedFolder.order(Column("name").asc).fetchAll(db)
        }
    }

    func fetchPaths() async throws -> [String] {
        try await dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT folderPath FROM excluded_folder")
        }
    }

    @discardableResult
    func insert(_ folder: ExcludedFolder) async throws -> ExcludedFolder {
        try await dbPool.write { db in
            var row = folder
            try row.insert(db)
            return row
        }
    }

    func delete(_ folder: ExcludedFolder) async throws {
        _ = try await dbPool.write { db in
            try folder.delete(db)
        }
    }

    func exists(folderPath: String) async throws -> Bool {
        let normalized = ExcludedFolderMatcher.normalize(folderPath)
        return try await dbPool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT COUNT(*) > 0 FROM excluded_folder WHERE folderPath = ? COLLATE NOCASE",
                arguments: [normalized]
            ) ?? false
        }
    }

    /// Remap exclude folders whose folderPath sits under `oldRoot` (Location Relink).
    func remapPathsUnder(oldRoot: String, newRoot: String) async throws -> Int {
        let folders = try await fetchAll()
        var count = 0
        try await dbPool.write { db in
            for folder in folders {
                guard let remapped = LocationRelink.remapFolderPath(
                    folder.folderPath,
                    oldRoot: oldRoot,
                    newRoot: newRoot
                ), remapped != folder.folderPath
                else { continue }
                guard let id = folder.id else { continue }
                let name = URL(fileURLWithPath: remapped).lastPathComponent
                try db.execute(
                    sql: "UPDATE excluded_folder SET folderPath = ?, name = ? WHERE id = ?",
                    arguments: [remapped, name, id]
                )
                count += 1
            }
        }
        return count
    }
}
