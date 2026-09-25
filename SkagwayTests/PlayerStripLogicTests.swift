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
