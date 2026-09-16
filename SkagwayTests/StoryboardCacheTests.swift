import XCTest
import AppKit
@testable import Skagway

final class StoryboardCacheTests: XCTestCase {
    private var cacheDir: URL!
    private var service: ThumbnailService!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkagwayStoryboard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        service = ThumbnailService(cacheDirectory: cacheDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDir)
        service = nil
        cacheDir = nil
        super.tearDown()
    }

    func testStoryboardURLUsesHashSuffix() {
        let path = "/Volumes/Media/clip.mp4"
        let url = service.storyboardURL(for: path)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("_storyboard.jpg"))
        XCTAssertEqual(url.deletingLastPathComponent().path, cacheDir.path)
    }

    func testFilmstripGridRecoversTwoByThree() {
        let size = NSSize(
            width: ThumbnailService.filmstripCellSize.width * 3,
            height: ThumbnailService.filmstripCellSize.height * 2
        )
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        let grid = ThumbnailService.filmstripGrid(in: image)
        XCTAssertEqual(grid?.rows, 2)
        XCTAssertEqual(grid?.columns, 3)
    }

    func testBakeStoryboardFromTwoByFiveFilmstrip() {
        let cell = ThumbnailService.filmstripCellSize
        let size = NSSize(width: cell.width * 5, height: cell.height * 2)
        let filmstrip = NSImage(size: size)
        filmstrip.lockFocus()
        // Paint first three columns green, last two red — bake should keep green block.
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: cell.width * 3, height: size.height).fill()
        NSColor.red.setFill()
        NSRect(x: cell.width * 3, y: 0, width: cell.width * 2, height: size.height).fill()
        filmstrip.unlockFocus()

        guard let baked = service.bakeStoryboard(fromFilmstrip: filmstrip) else {
            return XCTFail("Expected bake from 2×5 filmstrip")
        }
        XCTAssertEqual(baked.size.width, ThumbnailService.storyboardCompositeSize.width, accuracy: 0.5)
        XCTAssertEqual(baked.size.height, ThumbnailService.storyboardCompositeSize.height, accuracy: 0.5)
    }

    func testBakeStoryboardRejectsTooNarrowFilmstrip() {
        let cell = ThumbnailService.filmstripCellSize
        let size = NSSize(width: cell.width * 2, height: cell.height * 2)
        let filmstrip = NSImage(size: size)
        filmstrip.lockFocus()
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: size).fill()
        filmstrip.unlockFocus()

        XCTAssertNil(service.bakeStoryboard(fromFilmstrip: filmstrip))
    }

    func testMigrateMovesStoryboardFile() throws {
        let oldPath = "/Volumes/Media/Shows/clip.mp4"
        let newPath = "/Volumes/Media 2/Shows/clip.mp4"
        let oldURL = service.storyboardURL(for: oldPath)
        let newURL = service.storyboardURL(for: newPath)
        let marker = Data("STORYBOARD".utf8)
        try marker.write(to: oldURL)

        service.migrateCacheKeys([(from: oldPath, to: newPath)], onProgress: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(try Data(contentsOf: newURL), marker)
    }
}
