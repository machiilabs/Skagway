import Foundation
import GRDB

struct DataSourceRepository {
    let dbPool: DatabasePool

    func fetchAll() async throws -> [DataSource] {
        try await dbPool.read { db in
            try DataSource.order(Column("name").asc).fetchAll(db)
        }
    }

    @discardableResult
    func insert(_ dataSource: DataSource) async throws -> DataSource {
        try await dbPool.write { db in
            var ds = dataSource
            try ds.insert(db)
            return ds
        }
    }

    func delete(_ dataSource: DataSource) async throws {
        _ = try await dbPool.write { db in
            try dataSource.delete(db)
        }
    }

    func exists(folderPath: String) async throws -> Bool {
        try await dbPool.read { db in
            try DataSource.filter(Column("folderPath") == folderPath).fetchCount(db) > 0
        }
    }

    /// Remap Data Source roots whose folderPath sits under `oldRoot` (Location Relink).
    func remapPathsUnder(oldRoot: String, newRoot: String) async throws -> Int {
        let sources = try await fetchAll()
        var count = 0
        try await dbPool.write { db in
            for source in sources {
                guard let remapped = LocationRelink.remapFolderPath(
                    source.folderPath,
                    oldRoot: oldRoot,
                    newRoot: newRoot
                ), remapped != source.folderPath
                else { continue }
                guard let id = source.id else { continue }
                let name = URL(fileURLWithPath: remapped).lastPathComponent
                try db.execute(
                    sql: "UPDATE data_source SET folderPath = ?, name = ? WHERE id = ?",
                    arguments: [remapped, name, id]
                )
                count += 1
            }
        }
        return count
    }
}
