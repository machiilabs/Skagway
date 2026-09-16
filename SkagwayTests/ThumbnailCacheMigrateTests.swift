import XCTest
import AppKit
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

    /// Regression: warming NSCache before detail files finished moving left the auto-frame in
    /// memory until process restart (disk was already correct — matches Paul’s quit/relaunch fix).
    func testMigrateDetailMemoryMatchesDiskAfterReplace() throws {
        let oldPath = "/Volumes/Media/Shows/a.mp4"
        let newPath = "/Volumes/Media 2/Shows/a.mp4"
        let oldDetail = service.detailPreviewURL(for: oldPath, longEdge: 720)
        let newDetail = service.detailPreviewURL(for: newPath, longEdge: 720)

        let customJPEG = try Self.solidJPEG(red: 10, green: 200, blue: 30)
        let autoJPEG = try Self.solidJPEG(red: 200, green: 20, blue: 20)
        try customJPEG.write(to: oldDetail)
        try autoJPEG.write(to: newDetail)
        // Seed memory with the destination auto-frame (pre-migrate UI load).
        XCTAssertNotNil(service.loadDetailPreview(for: newPath, longEdge: 720))

        service.migrateCacheKeys([(from: oldPath, to: newPath)], onProgress: nil)

        let disk = try Data(contentsOf: newDetail)
        XCTAssertEqual(disk, customJPEG)
        let fromCache = service.loadDetailPreview(for: newPath, longEdge: 720)
        let fromDisk = NSImage(contentsOf: newDetail)
        XCTAssertNotNil(fromCache)
        XCTAssertNotNil(fromDisk)
        XCTAssertEqual(fromCache!.tiffRepresentation, fromDisk!.tiffRepresentation)
    }

    func testRemappedThumbnailPathBustsUIVersion() {
        let oldPath = "/old/Lib/a.mp4"
        let newPath = "/new/Lib/a.mp4"
        let oldThumb = service.thumbnailURL(for: oldPath).path
        let versioned = "\(oldThumb)#1234.5"
        let remapped = service.remappedThumbnailPath(versioned, newFilePath: newPath)
        let newBare = service.thumbnailURL(for: newPath).path
        XCTAssertNotNil(remapped)
        XCTAssertTrue(remapped!.hasPrefix(newBare + "#"))
        XCTAssertFalse(remapped!.hasSuffix("#1234.5"), "must mint a fresh #version for card .task(id:) reload")
        XCTAssertNil(service.remappedThumbnailPath(nil, newFilePath: newPath))
    }

    private static func solidJPEG(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = rep.bitmapData else {
            throw NSError(domain: "ThumbnailCacheMigrateTests", code: 1)
        }
        for i in 0..<4 {
            let o = i * 4
            data[o] = red
            data[o + 1] = green
            data[o + 2] = blue
            data[o + 3] = 255
        }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 1.0]) else {
            throw NSError(domain: "ThumbnailCacheMigrateTests", code: 2)
        }
        return jpeg
    }
}
