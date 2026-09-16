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

    func testBakeStoryboardEvenlySamplesSixFramesFromWiderFilmstrip() {
        let cell = ThumbnailService.filmstripCellSize
        let size = NSSize(width: cell.width * 5, height: cell.height * 2)
        let filmstrip = NSImage(size: size)
        filmstrip.lockFocus()
        // Distinct colors per cell so we can confirm bake produced a full-size collage.
        for row in 0..<2 {
            for col in 0..<5 {
                let hue = CGFloat(row * 5 + col) / 10.0
                NSColor(calibratedHue: hue, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                NSRect(
                    x: CGFloat(col) * cell.width,
                    y: size.height - CGFloat(row + 1) * cell.height,
                    width: cell.width,
                    height: cell.height
                ).fill()
            }
        }
        filmstrip.unlockFocus()

        guard let baked = service.bakeStoryboard(fromFilmstrip: filmstrip) else {
            return XCTFail("Expected even-timeline bake from 2×5 filmstrip")
        }
        XCTAssertEqual(baked.size.width, ThumbnailService.storyboardCompositeSize.width, accuracy: 0.5)
        XCTAssertEqual(baked.size.height, ThumbnailService.storyboardCompositeSize.height, accuracy: 0.5)
        XCTAssertTrue(ThumbnailService.isValidStoryboardImage(baked))
    }

    func testBakeStoryboardRejectsTooFewFrames() {
        let cell = ThumbnailService.filmstripCellSize
        let size = NSSize(width: cell.width * 2, height: cell.height * 2)
        let filmstrip = NSImage(size: size)
        filmstrip.lockFocus()
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: size).fill()
        filmstrip.unlockFocus()

        XCTAssertNil(service.bakeStoryboard(fromFilmstrip: filmstrip))
    }

    func testLoadStoryboardRejectsLegacySmallComposite() throws {
        let path = "/Volumes/Media/Shows/clip.mp4"
        let url = service.storyboardURL(for: path)
        let legacy = NSImage(size: NSSize(width: 480, height: 180))
        legacy.lockFocus()
        NSColor.gray.setFill()
        NSRect(origin: .zero, size: legacy.size).fill()
        legacy.unlockFocus()
        guard let tiff = legacy.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else {
            return XCTFail("Failed to encode legacy storyboard")
        }
        try jpeg.write(to: url)

        XCTAssertNil(service.loadStoryboard(for: path))
    }

    func testStoryboardClickSecondsMapsTopLeftCell() {
        let seconds = ThumbnailService.storyboardClickSeconds(
            at: CGPoint(x: 10, y: 10),
            size: CGSize(width: 300, height: 200),
            duration: 70
        )
        // index 0 → 1/7 * 70 = 10
        XCTAssertEqual(seconds, 10, accuracy: 0.01)
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
