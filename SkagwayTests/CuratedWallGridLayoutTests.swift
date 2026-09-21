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

    func testInspectorWidthChangeDoesNotChangeWallGridItemCount() {
        // ⌘I hide/show changes pane width (and integer columnCount) but must keep a single
        // adaptive GridItem so LazyVGrid does not remount every Storyboard/Grid card.
        let withInspector = CuratedWallGrid.columnCount(
            forContainerWidth: 900,
            maxColumns: 3,
            minCellWidth: 440,
            spacing: 28,
            outerPadding: 18
        )
        let withoutInspector = CuratedWallGrid.columnCount(
            forContainerWidth: 1400,
            maxColumns: 3,
            minCellWidth: 440,
            spacing: 28,
            outerPadding: 18
        )
        XCTAssertNotEqual(withInspector, withoutInspector)

        let itemsNarrow = CuratedWallGrid.wallGridItems(minCellWidth: 440, spacing: 28)
        let itemsWide = CuratedWallGrid.wallGridItems(minCellWidth: 440, spacing: 28)
        XCTAssertEqual(itemsNarrow.count, 1)
        XCTAssertEqual(itemsWide.count, 1)
    }
}
