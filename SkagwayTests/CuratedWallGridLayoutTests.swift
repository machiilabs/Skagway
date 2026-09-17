import XCTest
@testable import Skagway

final class CuratedWallGridLayoutTests: XCTestCase {
    func testWideBrowserCanExceedFiveGridColumns() {
        let n = CuratedWallGrid.columnCount(
            forContainerWidth: 1800,
            maxColumns: CuratedWallGrid.maxColumns,
            minCellWidth: 220,
            spacing: 22,
            outerPadding: 18
        )
        XCTAssertGreaterThanOrEqual(n, 6)
        XCTAssertLessThanOrEqual(n, 8)
    }

    func testMinCellWidthStillFloorsNarrowBrowser() {
        let n = CuratedWallGrid.columnCount(
            forContainerWidth: 500,
            maxColumns: CuratedWallGrid.maxColumns,
            minCellWidth: 220,
            spacing: 22,
            outerPadding: 18
        )
        XCTAssertEqual(n, 2)
    }

    func testStoryboardCompactAllowsFourColumnsWhenWide() {
        let n = CuratedWallGrid.columnCount(
            forContainerWidth: 1600,
            maxColumns: 4,
            minCellWidth: 360,
            spacing: 16,
            outerPadding: 12
        )
        XCTAssertEqual(n, 4)
    }
}
