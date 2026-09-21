import XCTest
@testable import Skagway

final class BrowserScrollPinVisibleRangeTests: XCTestCase {
    func testNormalViewportProducesAscendingRange() {
        let range = BrowserScrollPinController.visibleStoryboardIndexRange(
            visibleTop: 400,
            visibleHeight: 800,
            documentHeight: 10_000,
            columnCount: 3,
            videoCount: 300
        )
        XCTAssertNotNil(range)
        XCTAssertLessThanOrEqual(range!.lowerBound, range!.upperBound)
        XCTAssertGreaterThan(range!.upperBound, range!.lowerBound)
    }

    func testInvertedHeightReturnsNil() {
        let range = BrowserScrollPinController.visibleStoryboardIndexRange(
            visibleTop: 800,
            visibleHeight: -800,
            documentHeight: 10_000,
            columnCount: 3,
            videoCount: 300
        )
        XCTAssertNil(range)
    }

    func testZeroSizeViewportReturnsNil() {
        XCTAssertNil(
            BrowserScrollPinController.visibleStoryboardIndexRange(
                visibleTop: 0,
                visibleHeight: 0,
                documentHeight: 10_000,
                columnCount: 3,
                videoCount: 300
            )
        )
    }

    /// Inspector hide can leave clip.origin.y past the document; startIdx used to exceed
    /// videoCount while endIdx was clamped, trapping `startIdx..<endIdx`.
    func testViewportPastDocumentDoesNotInvertRange() {
        let range = BrowserScrollPinController.visibleStoryboardIndexRange(
            visibleTop: 50_000,
            visibleHeight: 800,
            documentHeight: 2_000,
            columnCount: 3,
            videoCount: 90
        )
        XCTAssertNotNil(range)
        XCTAssertLessThanOrEqual(range!.lowerBound, range!.upperBound)
        XCTAssertLessThanOrEqual(range!.upperBound, 90)
        XCTAssertGreaterThanOrEqual(range!.lowerBound, 0)
    }

    func testNegativeVisibleTopClampsToStart() {
        let range = BrowserScrollPinController.visibleStoryboardIndexRange(
            visibleTop: -400,
            visibleHeight: 800,
            documentHeight: 10_000,
            columnCount: 3,
            videoCount: 300
        )
        XCTAssertEqual(range?.lowerBound, 0)
        XCTAssertLessThanOrEqual(range!.lowerBound, range!.upperBound)
    }

    func testNaNViewportReturnsNil() {
        XCTAssertNil(
            BrowserScrollPinController.visibleStoryboardIndexRange(
                visibleTop: .nan,
                visibleHeight: 800,
                documentHeight: 10_000,
                columnCount: 3,
                videoCount: 300
            )
        )
    }

    func testEmptyLibraryReturnsNil() {
        XCTAssertNil(
            BrowserScrollPinController.visibleStoryboardIndexRange(
                visibleTop: 0,
                visibleHeight: 800,
                documentHeight: 10_000,
                columnCount: 3,
                videoCount: 0
            )
        )
    }
}
