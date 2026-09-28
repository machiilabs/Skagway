import XCTest
import GRDB
@testable import Skagway

/// Quitting / switching libraries must close the pool, not delete `-wal` / `-shm` out from under
/// open connections ("vnode unlinked while in use" on every quit before this fix).
final class LibraryCloseTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("skagway-close-\(UUID().uuidString).machii")
    }

    override func tearDown() {
        DatabaseExportImport.activeDbPool = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        url = nil
        super.tearDown()
    }

    func testCloseFlushesWALRemovesSidecarsAndKeepsData() throws {
        let pool = try DatabasePool(path: url.path)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE t (v TEXT)")
            try db.execute(sql: "INSERT INTO t (v) VALUES ('kept')")
        }
        // Readers open their own connections, like the running app.
        _ = try pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM t") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))

        DatabaseExportImport.activeDbPool = pool
        DatabaseExportImport.checkpointAndCloseLibrary()

        XCTAssertNil(DatabaseExportImport.activeDbPool)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))

        let reopened = try DatabaseQueue(path: url.path)
        let value = try reopened.read { db in try String.fetchOne(db, sql: "SELECT v FROM t") }
        XCTAssertEqual(value, "kept")
    }

    func testSecondCallAfterCloseIsHarmless() throws {
        let pool = try DatabasePool(path: url.path)
        try pool.write { db in try db.execute(sql: "CREATE TABLE t (v TEXT)") }
        DatabaseExportImport.activeDbPool = pool
        DatabaseExportImport.checkpointAndCloseLibrary()
        DatabaseExportImport.checkpointAndCloseLibrary()
        XCTAssertNil(DatabaseExportImport.activeDbPool)
    }
}
