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

    func testInspectorToggleDoesNotChangeColumnLayoutWidth() {
        let inspector: CGFloat = 380
        let withInspector = CuratedWallGrid.columnLayoutWidth(
            availableWidth: 900,
            isInspectorVisible: true,
            inspectorWidth: inspector
        )
        let hidden = CuratedWallGrid.columnLayoutWidth(
            availableWidth: 900 + inspector,
            isInspectorVisible: false,
            inspectorWidth: inspector
        )
        XCTAssertEqual(withInspector, hidden)

        let colsShown = CuratedWallGrid.columnCount(
            forContainerWidth: withInspector,
            maxColumns: 3,
            minCellWidth: 440,
            spacing: 28,
            outerPadding: 18
        )
        let colsHidden = CuratedWallGrid.columnCount(
            forContainerWidth: hidden,
            maxColumns: 3,
            minCellWidth: 440,
            spacing: 28,
            outerPadding: 18
        )
        XCTAssertEqual(colsShown, colsHidden)

        XCTAssertEqual(
            CuratedWallGrid.wallGridItems(columnCount: colsShown, spacing: 28).count,
            colsShown
        )
    }

    func testRawHiddenWidthWouldAddStoryboardColumns() {
        // Sanity: without compensation, hiding the Inspector would change N (the stall).
        let shown = CuratedWallGrid.columnCount(
            forContainerWidth: 900,
            maxColumns: 3,
            minCellWidth: 440,
            spacing: 28,
            outerPadding: 18
        )
        let rawHidden = CuratedWallGrid.columnCount(
            forContainerWidth: 1280,
            maxColumns: 3,
            minCellWidth: 440,
            spacing: 28,
            outerPadding: 18
        )
        XCTAssertNotEqual(shown, rawHidden)
    }
}
