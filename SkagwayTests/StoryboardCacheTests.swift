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

    func testStoryboardTimesURLUsesHashSuffix() {
        let path = "/Volumes/Media/clip.mp4"
        let url = service.storyboardTimesURL(for: path)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("_storyboard_times.json"))
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

        guard let baked = service.bakeStoryboard(fromFilmstrip: filmstrip, duration: 110) else {
            return XCTFail("Expected even-timeline bake from 2×5 filmstrip")
        }
        XCTAssertEqual(baked.image.size.width, ThumbnailService.storyboardCompositeSize.width, accuracy: 0.5)
        XCTAssertEqual(baked.image.size.height, ThumbnailService.storyboardCompositeSize.height, accuracy: 0.5)
        XCTAssertTrue(ThumbnailService.isValidStoryboardImage(baked.image))
        XCTAssertTrue(ThumbnailService.isValidStoryboardCellTimes(baked.cellTimes))
        // Default 2×5 filmstrip: cell 0 copies sourceIndex 1 → (1+1)/(10+1)*110 = 20
        XCTAssertEqual(baked.cellTimes[0], 20, accuracy: 0.01)
        // Cell 5 → sourceIndex 8 → 9/11*110 = 90
        XCTAssertEqual(baked.cellTimes[5], 90, accuracy: 0.01)
    }

    func testBakeStoryboardRejectsTooFewFrames() {
        let cell = ThumbnailService.filmstripCellSize
        let size = NSSize(width: cell.width * 2, height: cell.height * 2)
        let filmstrip = NSImage(size: size)
        filmstrip.lockFocus()
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: size).fill()
        filmstrip.unlockFocus()

        XCTAssertNil(service.bakeStoryboard(fromFilmstrip: filmstrip, duration: 60))
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

    func testLoadStoryboardRejectsCollageWithoutCellTimes() throws {
        let path = "/Volumes/Media/Shows/clip-no-times.mp4"
        let url = service.storyboardURL(for: path)
        let collage = NSImage(size: ThumbnailService.storyboardCompositeSize)
        collage.lockFocus()
        NSColor.darkGray.setFill()
        NSRect(origin: .zero, size: collage.size).fill()
        collage.unlockFocus()
        guard let tiff = collage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else {
            return XCTFail("Failed to encode storyboard without times")
        }
        try jpeg.write(to: url)

        XCTAssertNil(service.loadStoryboard(for: path))
    }

    func testPeekStoryboardShowsValidCollageWithoutTimesForFirstPaint() throws {
        let path = "/Volumes/Media/Shows/clip-peek.mp4"
        let collage = NSImage(size: ThumbnailService.storyboardCompositeSize)
        collage.lockFocus()
        NSColor.darkGray.setFill()
        NSRect(origin: .zero, size: collage.size).fill()
        collage.unlockFocus()
        guard let tiff = collage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else {
            return XCTFail("Failed to encode peek collage")
        }
        try jpeg.write(to: service.storyboardURL(for: path))

        XCTAssertNil(service.residentStoryboard(for: path))
        XCTAssertNil(service.loadStoryboard(for: path))
        let peeked = service.peekStoryboardImage(for: path)
        XCTAssertNotNil(peeked)
        XCTAssertTrue(ThumbnailService.isValidStoryboardImage(peeked!))
        let cache = service.storyboardDisplayCache(for: path)
        XCTAssertNotNil(cache.image)
        XCTAssertFalse(cache.isComplete, "times sidecar missing — still generate in background")
    }

    func testStoryboardDisplayCacheCompleteWhenJPEGAndTimesExist() throws {
        let path = "/Volumes/Media/Shows/clip-complete.mp4"
        let collage = NSImage(size: ThumbnailService.storyboardCompositeSize)
        collage.lockFocus()
        NSColor.orange.setFill()
        NSRect(origin: .zero, size: collage.size).fill()
        collage.unlockFocus()
        guard let tiff = collage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else {
            return XCTFail("Failed to encode complete collage")
        }
        try jpeg.write(to: service.storyboardURL(for: path))
        let payload: [String: Any] = ["version": 1, "seconds": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]]
        try JSONSerialization.data(withJSONObject: payload).write(to: service.storyboardTimesURL(for: path))

        let cache = service.storyboardDisplayCache(for: path)
        XCTAssertNotNil(cache.image)
        XCTAssertTrue(cache.isComplete)
        XCTAssertNotNil(service.residentStoryboard(for: path), "complete peek should warm memory")
        XCTAssertNotNil(service.loadStoryboard(for: path))
    }

    func testStoryboardClickSecondsUsesStoredCellTimesNotEvenSplit() throws {
        let path = "/Volumes/Media/Shows/clip-times.mp4"
        let cell = ThumbnailService.filmstripCellSize
        let size = NSSize(width: cell.width * 5, height: cell.height * 2)
        let filmstrip = NSImage(size: size)
        filmstrip.lockFocus()
        NSColor.orange.setFill()
        NSRect(origin: .zero, size: size).fill()
        filmstrip.unlockFocus()

        let duration = 110.0
        guard let baked = service.bakeStoryboard(fromFilmstrip: filmstrip, duration: duration) else {
            return XCTFail("Expected bake")
        }
        // storeStoryboard is private — generate path via times URL + load after writing through bake+public APIs.
        // Write via generateStoryboard’s store by calling the public bake result through migrate-free disk write:
        // Use store by going through generate’s private store — instead write times JSON the same way store does
        // by using bake + a minimal encode via storyboardTimesURL after forcing store through reflection-free path:
        // ThumbnailService.store is private; write JPEG + JSON mirroring encode format.
        guard let tiff = baked.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        else {
            return XCTFail("encode collage")
        }
        try jpeg.write(to: service.storyboardURL(for: path))
        let payload: [String: Any] = ["version": 1, "seconds": baked.cellTimes]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: service.storyboardTimesURL(for: path))

        // Even-split for cell 0 would be 1/7*110 ≈ 15.7; stored filmstrip time is 20.
        let evenSplit = ThumbnailService.storyboardEvenSplitSeconds(index: 0, duration: duration)
        XCTAssertEqual(evenSplit, duration / 7.0, accuracy: 0.01)

        let seek = service.storyboardClickSeconds(
            for: path,
            at: CGPoint(x: 10, y: 10),
            size: CGSize(width: 300, height: 200),
            duration: duration
        )
        XCTAssertEqual(seek, baked.cellTimes[0], accuracy: 0.01)
        XCTAssertNotEqual(seek, evenSplit, accuracy: 0.5)
    }

    func testStoryboardClickSecondsFallbackEvenSplitWithoutTimes() {
        let seconds = service.storyboardClickSeconds(
            for: "/Volumes/Media/missing-times.mp4",
            at: CGPoint(x: 10, y: 10),
            size: CGSize(width: 300, height: 200),
            duration: 70
        )
        // index 0 → 1/7 * 70 = 10
        XCTAssertEqual(seconds, 10, accuracy: 0.01)
    }

    func testStoryboardCellIndexUsesFullCollageSizeNotTitleCrop() {
        // Seek overlay stops above the title band, but row math must use the full
        // 2×3 collage so the visual midline stays the row split.
        let full = CGSize(width: 300, height: 200)
        let seekCrop = CGSize(width: 300, height: 160)
        let pointInTopVisualRow = CGPoint(x: 10, y: 90)
        XCTAssertEqual(ThumbnailService.storyboardCellIndex(at: pointInTopVisualRow, size: full), 0)
        XCTAssertEqual(ThumbnailService.storyboardCellIndex(at: pointInTopVisualRow, size: seekCrop), 1)
        XCTAssertEqual(
            ThumbnailService.storyboardCellIndex(at: CGPoint(x: 10, y: 150), size: full),
            3
        )
    }

    func testMigrateMovesStoryboardFileAndTimesSidecar() throws {
        let oldPath = "/Volumes/Media/Shows/clip.mp4"
        let newPath = "/Volumes/Media 2/Shows/clip.mp4"
        let oldURL = service.storyboardURL(for: oldPath)
        let newURL = service.storyboardURL(for: newPath)
        let oldTimes = service.storyboardTimesURL(for: oldPath)
        let newTimes = service.storyboardTimesURL(for: newPath)
        let marker = Data("STORYBOARD".utf8)
        try marker.write(to: oldURL)
        let timesPayload: [String: Any] = [
            "version": 1,
            "seconds": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
        ]
        try JSONSerialization.data(withJSONObject: timesPayload).write(to: oldTimes)

        service.migrateCacheKeys([(from: oldPath, to: newPath)], onProgress: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(try Data(contentsOf: newURL), marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldTimes.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newTimes.path))
        let migrated = service.loadStoryboardCellTimes(for: newPath)
        XCTAssertEqual(migrated, [1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
    }
}
