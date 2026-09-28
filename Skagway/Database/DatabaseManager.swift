import Foundation
import GRDB

final class DatabaseManager {
    let dbPool: DatabasePool

    init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // Do not force journal_mode — causes "database is locked". The pool is closed on terminate
        // (`checkpointAndCloseLibrary`), which is when SQLite removes the WAL files.

        dbPool = try DatabasePool(path: path, configuration: config)
        try DatabaseMigration.migrate(dbPool)
    }
}
