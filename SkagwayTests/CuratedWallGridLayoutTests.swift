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

    /// Normal Storyboard is capped at 3 even on a wide pane (Compact is the 3↔4 density).
    func testStoryboardNormalStaysAtMostThreeColumnsWhenWide() {
        let wide = CuratedWallGrid.columnCount(
            forContainerWidth: 2400,
            maxColumns: CuratedWallGrid.storyboardNormalMaxColumns,
            minCellWidth: CuratedWallGrid.storyboardNormalMinCellWidth,
            spacing: CuratedWallGrid.storyboardColumnSpacing,
            outerPadding: CuratedWallGrid.storyboardOuterPadding
        )
        let withInspector = CuratedWallGrid.columnCount(
            forContainerWidth: 1200,
            maxColumns: CuratedWallGrid.storyboardNormalMaxColumns,
            minCellWidth: CuratedWallGrid.storyboardNormalMinCellWidth,
            spacing: CuratedWallGrid.storyboardColumnSpacing,
            outerPadding: CuratedWallGrid.storyboardOuterPadding
        )
        XCTAssertEqual(wide, 3)
        XCTAssertLessThanOrEqual(withInspector, 3)
        XCTAssertEqual(
            CuratedWallGrid.wallGridItems(
                minCellWidth: CuratedWallGrid.storyboardNormalMinCellWidth,
                spacing: CuratedWallGrid.storyboardColumnSpacing,
                maxColumns: CuratedWallGrid.storyboardNormalMaxColumns,
                containerWidth: 2400,
                outerPadding: CuratedWallGrid.storyboardOuterPadding
            ).count,
            1
        )
    }

    /// Same column count must not make Normal pictures narrower than Compact.
    /// Compact is smaller only when it fits more columns.
    func testNormalStoryboardCardsAreNotNarrowerThanCompactWhenColumnCountsMatch() {
        let spacing = CuratedWallGrid.storyboardColumnSpacing
        let padding = CuratedWallGrid.storyboardOuterPadding
        var sawMatchingColumns = false
        var width: CGFloat = 480
        while width <= 2600 {
            let normalColumns = CuratedWallGrid.columnCount(
                forContainerWidth: width,
                maxColumns: CuratedWallGrid.storyboardNormalMaxColumns,
                minCellWidth: CuratedWallGrid.storyboardNormalMinCellWidth,
                spacing: spacing,
                outerPadding: padding
            )
            let compactColumns = CuratedWallGrid.columnCount(
                forContainerWidth: width,
                maxColumns: CuratedWallGrid.storyboardCompactMaxColumns,
                minCellWidth: CuratedWallGrid.storyboardCompactMinCellWidth,
                spacing: spacing,
                outerPadding: padding
            )
            if normalColumns == compactColumns {
                sawMatchingColumns = true
                let normalCell = CuratedWallGrid.flexibleCellWidth(
                    containerWidth: width,
                    columns: normalColumns,
                    spacing: spacing,
                    outerPadding: padding
                )
                let compactCell = CuratedWallGrid.flexibleCellWidth(
                    containerWidth: width,
                    columns: compactColumns,
                    spacing: spacing,
                    outerPadding: padding
                )
                XCTAssertGreaterThanOrEqual(
                    normalCell,
                    compactCell - 0.5,
                    "Normal cell narrower than Compact at width \(width) with \(normalColumns) columns"
                )
            } else {
                XCTAssertLessThan(
                    normalColumns,
                    compactColumns,
                    "Normal should not pack more columns than Compact at width \(width)"
                )
            }
            width += 20
        }
        XCTAssertTrue(sawMatchingColumns)
    }
}
