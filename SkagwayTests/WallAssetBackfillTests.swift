import XCTest
@testable import Skagway

/// Idle wall fill: order, idle rule, per-view asset, disk-only completeness.
final class WallAssetBackfillTests: XCTestCase {
    private var cacheDir: URL!
    private var service: ThumbnailService!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkagwayWallFill-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        service = ThumbnailService(cacheDirectory: cacheDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDir)
        service = nil
        cacheDir = nil
        super.tearDown()
    }

    // MARK: - Order

    func testOrderStartsAtCenterAndTakesTwoDownForEachUp() {
        let view = (0..<10).map { "v\($0)" }
        let order = WallBackfillOrder.order(viewPaths: view, centerIndex: 5, libraryPaths: [])
        XCTAssertEqual(order, ["v5", "v6", "v4", "v7", "v8", "v3", "v9", "v2", "v1", "v0"])
    }

    func testOrderFinishesUpwardWhenBottomIsReached() {
        let view = (0..<5).map { "v\($0)" }
        let order = WallBackfillOrder.order(viewPaths: view, centerIndex: 4, libraryPaths: [])
        XCTAssertEqual(order, ["v4", "v3", "v2", "v1", "v0"])
    }

    func testOrderClampsCenterIntoRange() {
        let view = ["a", "b", "c"]
        XCTAssertEqual(WallBackfillOrder.order(viewPaths: view, centerIndex: -7, libraryPaths: []).first, "a")
        XCTAssertEqual(WallBackfillOrder.order(viewPaths: view, centerIndex: 99, libraryPaths: []).first, "c")
    }

    func testOrderAppendsRestOfLibraryWithoutRepeatingTheView() {
        let order = WallBackfillOrder.order(
            viewPaths: ["b", "c"],
            centerIndex: 0,
            libraryPaths: ["a", "b", "c", "d"]
        )
        XCTAssertEqual(order, ["b", "c", "a", "d"])
    }

    func testOrderWithEmptyViewIsTheLibrary() {
        let order = WallBackfillOrder.order(viewPaths: [], centerIndex: 3, libraryPaths: ["a", "b"])
        XCTAssertEqual(order, ["a", "b"])
    }

    func testOrderCoversEveryPathOnceForLargeLibrary() {
        let library = (0..<12_000).map { "/lib/\($0).mp4" }
        let view = Array(library[2_000..<5_000])
        let order = WallBackfillOrder.order(viewPaths: view, centerIndex: 1_500, libraryPaths: library)
        XCTAssertEqual(order.count, library.count)
        XCTAssertEqual(Set(order).count, library.count)
        XCTAssertEqual(order.first, view[1_500])
        XCTAssertEqual(Set(order.prefix(view.count)), Set(view))
    }

    // MARK: - Idle rule

    private func conditions(
        enabled: Bool = true,
        scanning: Bool = false,
        playing: Bool = false,
        moving: Bool = false,
        lowPower: Bool = false,
        hot: Bool = false,
        lastActivity: TimeInterval = 0
    ) -> WallBackfillConditions {
        WallBackfillConditions(
            enabled: enabled,
            isScanning: scanning,
            isPlaying: playing,
            isMoving: moving,
            isLowPower: lowPower,
            isThermalSerious: hot,
            lastActivityUptime: lastActivity
        )
    }

    func testIdleWhenNothingIsGoingOnAndQuietPeriodPassed() {
        XCTAssertTrue(WallBackfillIdle.isIdle(conditions(lastActivity: 100), now: 104))
    }

    func testNotIdleDuringQuietPeriod() {
        XCTAssertFalse(WallBackfillIdle.isIdle(conditions(lastActivity: 100), now: 101.5))
    }

    func testEachBlockerStopsFill() {
        let now: TimeInterval = 1_000
        XCTAssertFalse(WallBackfillIdle.isIdle(conditions(enabled: false), now: now))
        XCTAssertFalse(WallBackfillIdle.isIdle(conditions(scanning: true), now: now))
        XCTAssertFalse(WallBackfillIdle.isIdle(conditions(playing: true), now: now))
        XCTAssertFalse(WallBackfillIdle.isIdle(conditions(moving: true), now: now))
        XCTAssertFalse(WallBackfillIdle.isIdle(conditions(lowPower: true), now: now))
        XCTAssertFalse(WallBackfillIdle.isIdle(conditions(hot: true), now: now))
    }

    // MARK: - Asset per view

    func testAssetKindFollowsViewMode() {
        XCTAssertEqual(WallAssetKind(viewMode: .grid), .gridPreview)
        XCTAssertEqual(WallAssetKind(viewMode: .list), .poster)
        XCTAssertEqual(WallAssetKind(viewMode: .storyboard), .storyboard)
    }

    // MARK: - Disk-only completeness

    private func touch(_ url: URL, _ contents: String = "x") {
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
    }

    func testPosterIsCompleteWhenPosterFileExists() {
        let path = "/Volumes/Media/a.mp4"
        XCTAssertFalse(service.hasWallAsset(.poster, for: path))
        touch(service.thumbnailURL(for: path))
        XCTAssertTrue(service.hasWallAsset(.poster, for: path))
    }

    func testGridPreviewNeedsPosterAnd720Still() {
        let path = "/Volumes/Media/b.mp4"
        touch(service.thumbnailURL(for: path))
        XCTAssertFalse(service.hasWallAsset(.gridPreview, for: path))
        touch(service.detailPreviewURL(for: path, longEdge: ThumbnailService.wallGridPreviewLongEdge))
        XCTAssertTrue(service.hasWallAsset(.gridPreview, for: path))
    }

    func testStoryboardWithoutTimesSidecarIsIncomplete() {
        let path = "/Volumes/Media/c.mp4"
        touch(service.storyboardURL(for: path))
        XCTAssertFalse(service.hasWallAsset(.storyboard, for: path))
        touch(
            service.storyboardTimesURL(for: path),
            #"{"version":1,"seconds":[1,2,3,4,5,6]}"#
        )
        XCTAssertTrue(service.hasWallAsset(.storyboard, for: path))
    }
}
