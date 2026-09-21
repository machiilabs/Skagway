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

    func testCompactStoryboardGainsFourthColumnWhenInspectorHides() {
        // Typical ~1200pt browser + ~380pt Inspector → 3 Compact cols; hide → ~1580pt → 4.
        let shown = CuratedWallGrid.columnCount(
            forContainerWidth: 1200,
            maxColumns: 4,
            minCellWidth: 360,
            spacing: 16,
            outerPadding: 12
        )
        let hidden = CuratedWallGrid.columnCount(
            forContainerWidth: 1580,
            maxColumns: 4,
            minCellWidth: 360,
            spacing: 16,
            outerPadding: 12
        )
        XCTAssertEqual(shown, 3)
        XCTAssertEqual(hidden, 4)
    }

    func testInspectorWidthChangeKeepsSingleAdaptiveGridItem() {
        // ⌘I hide/show changes integer columnCount (3→4) but must keep one adaptive GridItem
        // so LazyVGrid does not remount every Storyboard/Grid card.
        let shown = CuratedWallGrid.columnCount(
            forContainerWidth: 1200,
            maxColumns: 4,
            minCellWidth: 360,
            spacing: 16,
            outerPadding: 12
        )
        let hidden = CuratedWallGrid.columnCount(
            forContainerWidth: 1580,
            maxColumns: 4,
            minCellWidth: 360,
            spacing: 16,
            outerPadding: 12
        )
        XCTAssertNotEqual(shown, hidden)

        let itemsNarrow = CuratedWallGrid.wallGridItems(
            minCellWidth: 360,
            spacing: 16,
            maxColumns: 4,
            containerWidth: 1200,
            outerPadding: 12
        )
        let itemsWide = CuratedWallGrid.wallGridItems(
            minCellWidth: 360,
            spacing: 16,
            maxColumns: 4,
            containerWidth: 1580,
            outerPadding: 12
        )
        XCTAssertEqual(itemsNarrow.count, 1)
        XCTAssertEqual(itemsWide.count, 1)

        // Typical 3→4 keeps the same adaptive minimum so GridItem identity is stable.
        let minShown = CuratedWallGrid.adaptiveColumnMinimum(
            containerWidth: 1200,
            maxColumns: 4,
            minCellWidth: 360,
            spacing: 16,
            outerPadding: 12
        )
        let minHidden = CuratedWallGrid.adaptiveColumnMinimum(
            containerWidth: 1580,
            maxColumns: 4,
            minCellWidth: 360,
            spacing: 16,
            outerPadding: 12
        )
        XCTAssertEqual(minShown, 360)
        XCTAssertEqual(minHidden, 360)
    }

    func testAdaptiveMinimumCapsUltrawideAtMaxColumns() {
        let minimum = CuratedWallGrid.adaptiveColumnMinimum(
            containerWidth: 2400,
            maxColumns: 4,
            minCellWidth: 360,
            spacing: 16,
            outerPadding: 12
        )
        XCTAssertGreaterThan(minimum, 360)
        let n = CuratedWallGrid.columnCount(
            forContainerWidth: 2400,
            maxColumns: 4,
            minCellWidth: 360,
            spacing: 16,
            outerPadding: 12
        )
        XCTAssertEqual(n, 4)
    }
}
