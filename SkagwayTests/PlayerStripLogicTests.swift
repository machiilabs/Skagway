import XCTest
@testable import Skagway

/// In-player filmstrip math (N, click→cell, linear playhead). No AV / disk.
final class PlayerStripLogicTests: XCTestCase {
    func testFrameCountClampsToMinAndMax() {
        XCTAssertEqual(
            ThumbnailService.playerStripFrameCount(trackWidth: 0, stripHeight: 54),
            ThumbnailService.playerStripMinFrames
        )
        XCTAssertEqual(
            ThumbnailService.playerStripFrameCount(trackWidth: 10_000, stripHeight: 54),
            ThumbnailService.playerStripMaxFrames
        )
        XCTAssertEqual(
            ThumbnailService.playerStripFrameCount(trackWidth: 800, stripHeight: 54),
            8
        )
        XCTAssertEqual(
            ThumbnailService.playerStripFrameCount(trackWidth: 400, stripHeight: 36),
            6
        )
    }

    func testDerivedAssetCacheFileMatcherLeavesPosterAndDetailStills() {
        let hash = "abc123"
        XCTAssertTrue(ThumbnailService.isDerivedAssetCacheFile(name: "\(hash)_filmstrip_e6.jpg", pathHash: hash))
        XCTAssertTrue(ThumbnailService.isDerivedAssetCacheFile(name: "\(hash)_storyboard.jpg", pathHash: hash))
        XCTAssertTrue(ThumbnailService.isDerivedAssetCacheFile(name: "\(hash)_storyboard_times.json", pathHash: hash))
        XCTAssertTrue(ThumbnailService.isDerivedAssetCacheFile(name: "\(hash)_playerstrip_n13_c2.jpg", pathHash: hash))
        XCTAssertTrue(ThumbnailService.isDerivedAssetCacheFile(name: "\(hash)_playerstrip_n13_c2_times.json", pathHash: hash))
        XCTAssertFalse(ThumbnailService.isDerivedAssetCacheFile(name: "\(hash).jpg", pathHash: hash))
        XCTAssertFalse(ThumbnailService.isDerivedAssetCacheFile(name: "\(hash)_detail_720.jpg", pathHash: hash))
        XCTAssertFalse(ThumbnailService.isDerivedAssetCacheFile(name: "other_playerstrip_n13_c2.jpg", pathHash: hash))
    }

    func testWarmupQueuePutsSelectionAtFrontAndCapsTheTail() {
        var queue = PlayerStripWarmupQueue()
        queue.prioritize("a")
        queue.prioritize("b")
        queue.prioritize("a")
        XCTAssertEqual(queue.paths, ["a", "b"])

        queue.removeAll()
        for index in 1...9 {
            queue.prioritize("v\(index)")
        }
        XCTAssertEqual(queue.paths.count, PlayerStripWarmupQueue.capacity)
        XCTAssertEqual(queue.paths.first, "v9")
        XCTAssertFalse(queue.paths.contains("v1"))
        XCTAssertEqual(queue.popNext(), "v9")
    }

    func testPredictedFrameCountUsesPlayerChrome() {
        // 800pt windowed panel: media 20 + bar 24 + time columns 88 → track 668.
        let windowed = PlaybackTimelineBar.predictedPlayerStripFrameCount(
            contentWidth: 800,
            fullScreen: false,
            thinFilmstrip: false
        )
        XCTAssertEqual(
            windowed,
            ThumbnailService.playerStripFrameCount(trackWidth: 668, stripHeight: 54)
        )
        let full = PlaybackTimelineBar.predictedPlayerStripFrameCount(
            contentWidth: 1440,
            fullScreen: true,
            thinFilmstrip: false
        )
        XCTAssertEqual(
            full,
            ThumbnailService.playerStripFrameCount(trackWidth: 1328, stripHeight: 54)
        )
    }

    func testCellIndexClampsToStrip() {
        let size = CGSize(width: 240, height: 36)
        XCTAssertEqual(
            ThumbnailService.playerStripCellIndex(at: .zero, size: size, frameCount: 6),
            0
        )
        XCTAssertEqual(
            ThumbnailService.playerStripCellIndex(at: CGPoint(x: 239, y: 10), size: size, frameCount: 6),
            5
        )
        XCTAssertEqual(
            ThumbnailService.playerStripCellIndex(at: CGPoint(x: -20, y: 0), size: size, frameCount: 6),
            0
        )
        XCTAssertEqual(
            ThumbnailService.playerStripCellIndex(at: CGPoint(x: 400, y: 0), size: size, frameCount: 6),
            5
        )
        XCTAssertEqual(
            ThumbnailService.playerStripCellIndex(at: CGPoint(x: 10, y: 0), size: .zero, frameCount: 6),
            0
        )
        XCTAssertEqual(
            ThumbnailService.playerStripCellIndex(at: CGPoint(x: 10, y: 0), size: size, frameCount: 0),
            0
        )
    }

    func testSampleClampPullsTheLastFrameBackInsideThePictures() {
        // Antique Cabinets: container 55:06, pictures end at 50:56. A 13-frame strip’s last
        // bucket sits past the pictures and used to fail the whole bake.
        let ideal = ThumbnailService.playerStripEvenSplitSeconds(index: 12, duration: 3306, frameCount: 13)
        XCTAssertGreaterThan(ideal, 3055.65)
        let clamped = ThumbnailService.clampSampleSeconds(ideal, pictureStart: 0, pictureEnd: 3055.65)
        XCTAssertLessThan(clamped, 3055.65)
        XCTAssertGreaterThan(clamped, 3055.5)
        let early = ThumbnailService.playerStripEvenSplitSeconds(index: 0, duration: 3306, frameCount: 13)
        XCTAssertEqual(
            ThumbnailService.clampSampleSeconds(early, pictureStart: 0, pictureEnd: 3055.65),
            early,
            accuracy: 0.001
        )
    }

    func testPicturesEndEarlyWhenASampleWasPulledBack() {
        let duration = 3306.0
        let frameCount = 13
        var times = (0..<frameCount).map {
            ThumbnailService.playerStripEvenSplitSeconds(index: $0, duration: duration, frameCount: frameCount)
        }
        XCTAssertFalse(
            ThumbnailService.playerStripPicturesEndEarly(cellTimes: times, duration: duration, frameCount: frameCount)
        )
        XCTAssertNil(
            ThumbnailService.playerStripEarlyCellIndex(cellTimes: times, duration: duration, frameCount: frameCount)
        )
        times[frameCount - 1] = ThumbnailService.clampSampleSeconds(times[frameCount - 1], pictureStart: 0, pictureEnd: 3055.65)
        XCTAssertTrue(
            ThumbnailService.playerStripPicturesEndEarly(cellTimes: times, duration: duration, frameCount: frameCount)
        )
        XCTAssertEqual(
            ThumbnailService.playerStripEarlyCellIndex(cellTimes: times, duration: duration, frameCount: frameCount),
            12
        )
    }

    func testEvenSplitUsesBucketCenters() {
        XCTAssertEqual(
            ThumbnailService.playerStripEvenSplitSeconds(index: 0, duration: 60, frameCount: 6),
            5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ThumbnailService.playerStripEvenSplitSeconds(index: 5, duration: 60, frameCount: 6),
            55,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ThumbnailService.playerStripEvenSplitSeconds(index: -1, duration: 60, frameCount: 6),
            5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ThumbnailService.playerStripEvenSplitSeconds(index: 99, duration: 60, frameCount: 6),
            55,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ThumbnailService.playerStripEvenSplitSeconds(index: 0, duration: 0, frameCount: 6),
            0,
            accuracy: 0.001
        )
    }

    func testPlayheadIndexUsesLinearBuckets() {
        XCTAssertEqual(
            ThumbnailService.playerStripPlayheadIndex(seconds: 0, duration: 60, frameCount: 6),
            0
        )
        XCTAssertEqual(
            ThumbnailService.playerStripPlayheadIndex(seconds: 9.9, duration: 60, frameCount: 6),
            0
        )
        XCTAssertEqual(
            ThumbnailService.playerStripPlayheadIndex(seconds: 10, duration: 60, frameCount: 6),
            1
        )
        XCTAssertEqual(
            ThumbnailService.playerStripPlayheadIndex(seconds: 60, duration: 60, frameCount: 6),
            5
        )
        XCTAssertEqual(
            ThumbnailService.playerStripPlayheadIndex(seconds: -4, duration: 60, frameCount: 6),
            0
        )
        XCTAssertEqual(
            ThumbnailService.playerStripPlayheadIndex(seconds: 30, duration: 0, frameCount: 6),
            0
        )
        XCTAssertEqual(
            ThumbnailService.playerStripPlayheadIndex(seconds: 30, duration: 60, frameCount: 0),
            0
        )
    }

    func testClickCenterMapsBackToSamePlayheadCell() {
        let duration = 120.0
        let n = 8
        for i in 0..<n {
            let t = ThumbnailService.playerStripEvenSplitSeconds(index: i, duration: duration, frameCount: n)
            XCTAssertEqual(
                ThumbnailService.playerStripPlayheadIndex(seconds: t, duration: duration, frameCount: n),
                i
            )
        }
    }

    func testCompositeSizeAndCellTimesContract() {
        let size = ThumbnailService.playerStripCompositeSize(frameCount: 6)
        XCTAssertEqual(size.width, ThumbnailService.playerStripBakeCellWidth * 6, accuracy: 0.01)
        XCTAssertEqual(size.height, ThumbnailService.playerStripBakeCellHeight, accuracy: 0.01)
        XCTAssertTrue(
            ThumbnailService.isValidPlayerStripCellTimes([1, 2, 3, 4, 5, 6], frameCount: 6)
        )
        XCTAssertFalse(
            ThumbnailService.isValidPlayerStripCellTimes([1, 2, 3], frameCount: 6)
        )
        XCTAssertFalse(
            ThumbnailService.isValidPlayerStripCellTimes([1, .nan, 3, 4], frameCount: 4)
        )
    }
}
