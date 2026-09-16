import XCTest
@testable import Skagway

final class ThumbnailCacheMigrateTests: XCTestCase {
    private var cacheDir: URL!
    private var service: ThumbnailService!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkagwayThumbMigrate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        service = ThumbnailService(cacheDirectory: cacheDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDir)
        service = nil
        cacheDir = nil
        super.tearDown()
    }

    func testMigrateCacheKeysReplacesDestinationWithCustomPoster() throws {
        let oldPath = "/Volumes/Media/Shows/clip.mp4"
        let newPath = "/Volumes/Media 2/Shows/clip.mp4"
        let oldURL = service.thumbnailURL(for: oldPath)
        let newURL = service.thumbnailURL(for: newPath)
        XCTAssertNotEqual(oldURL.path, newURL.path)

        let customMarker = Data("CUSTOM-POSTER".utf8)
        let autoMarker = Data("AUTO-FRAME".utf8)
        try customMarker.write(to: oldURL)
        try autoMarker.write(to: newURL)

        service.migrateCacheKeys([(from: oldPath, to: newPath)], onProgress: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        let migrated = try Data(contentsOf: newURL)
        XCTAssertEqual(migrated, customMarker)
    }

    func testMigrateCacheKeysMovesDetailPreviewWhenDestinationExists() throws {
        let oldPath = "/Volumes/Media/clip.mp4"
        let newPath = "/Volumes/NewMedia/clip.mp4"
        let oldDetail = service.detailPreviewURL(for: oldPath, longEdge: 720)
        let newDetail = service.detailPreviewURL(for: newPath, longEdge: 720)

        let custom = Data("CUSTOM-DETAIL".utf8)
        let auto = Data("AUTO-DETAIL".utf8)
        try custom.write(to: oldDetail)
        try auto.write(to: newDetail)

        service.migrateCacheKeys([(from: oldPath, to: newPath)], onProgress: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDetail.path))
        let migrated = try Data(contentsOf: newDetail)
        XCTAssertEqual(migrated, custom)
    }

    func testRemappedThumbnailPathPreservesVersionSuffix() {
        let oldPath = "/old/Lib/a.mp4"
        let newPath = "/new/Lib/a.mp4"
        let oldThumb = service.thumbnailURL(for: oldPath).path
        let versioned = "\(oldThumb)#1234.5"
        let remapped = service.remappedThumbnailPath(versioned, newFilePath: newPath)
        XCTAssertEqual(remapped, "\(service.thumbnailURL(for: newPath).path)#1234.5")
        XCTAssertNil(service.remappedThumbnailPath(nil, newFilePath: newPath))
    }
}
