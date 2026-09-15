import AppKit
import XCTest
@testable import Skagway

final class ListReviewTableSelectionTests: XCTestCase {
    private let a = "/a.mp4"
    private let b = "/b.mp4"
    private let c = "/c.mp4"
    private let d = "/d.mp4"
    private let ordered = ["/a.mp4", "/b.mp4", "/c.mp4", "/d.mp4"]

    private func commandFlags() -> NSEvent.ModifierFlags {
        [.command]
    }

    private func shiftFlags() -> NSEvent.ModifierFlags {
        [.shift]
    }

    func testPlainClickMovesFocusWithoutChangingSet() {
        var session = ReviewSession(focusedId: a, selectedIds: [a, c])
        let last = session.applyListTableSelection(
            newIds: [b],
            allVideoIds: ordered,
            previousTableFocusId: a,
            lastClickedId: a,
            flags: []
        )
        XCTAssertEqual(last, b)
        XCTAssertEqual(session.focusedId, b)
        XCTAssertEqual(session.selectedIds, [a, c])
    }

    func testCommandClickAddEntersBatchInspect() {
        var session = ReviewSession(focusedId: a, selectedIds: [a])
        _ = session.applyListTableSelection(
            newIds: [a, b],
            allVideoIds: ordered,
            previousTableFocusId: a,
            lastClickedId: a,
            flags: commandFlags()
        )
        XCTAssertNil(session.focusedId)
        XCTAssertEqual(session.selectedIds, [a, b])
        XCTAssertTrue(session.isSetMode)
    }

    func testCommandClickRemovesFromSet() {
        var session = ReviewSession(focusedId: a, selectedIds: [a, b])
        _ = session.applyListTableSelection(
            newIds: [b],
            allVideoIds: ordered,
            previousTableFocusId: a,
            lastClickedId: a,
            flags: commandFlags()
        )
        XCTAssertEqual(session.focusedId, a)
        XCTAssertEqual(session.selectedIds, [a])
    }

    func testShiftClickAnchorsOnLastCommandClickNotTableFocus() {
        let v4 = ordered[0]
        let v10 = ordered[2]
        let v15 = ordered[3]
        var session = ReviewSession(focusedId: v4, selectedIds: [v4, v15])
        // Table reports focus→click span (v4…v10); collection range should be v10…v15 (last ⌘-click).
        let last = session.applyListTableSelection(
            newIds: [v4, ordered[1], v10],
            allVideoIds: ordered,
            previousTableFocusId: v4,
            lastClickedId: v15,
            flags: shiftFlags()
        )
        XCTAssertEqual(last, v10)
        XCTAssertNil(session.focusedId)
        XCTAssertEqual(session.selectedIds, Set([v4, v10, v15]))
        XCTAssertTrue(session.isSetMode)
    }

    func testShiftClickUnionsRangeIntoExistingSet() {
        var session = ReviewSession(focusedId: a, selectedIds: [a, d])
        let last = session.applyListTableSelection(
            newIds: [a, b, c],
            allVideoIds: ordered,
            previousTableFocusId: a,
            lastClickedId: a,
            flags: shiftFlags()
        )
        XCTAssertEqual(last, c)
        XCTAssertNil(session.focusedId)
        XCTAssertEqual(session.selectedIds, [a, b, c, d])
        XCTAssertTrue(session.isSetMode)
    }

    func testOptionClickSelectsOnly() {
        var session = ReviewSession(focusedId: a, selectedIds: [a, c])
        let last = session.applyListTableSelection(
            newIds: [b],
            allVideoIds: ordered,
            previousTableFocusId: a,
            lastClickedId: a,
            flags: [.option]
        )
        XCTAssertEqual(last, b)
        XCTAssertEqual(session.focusedId, b)
        XCTAssertEqual(session.selectedIds, [b])
    }

    func testExtendedSelectionModifiersDetectCommandShiftOption() {
        XCTAssertTrue(ListSelectionModifiers.usesExtendedSelection([.command]))
        XCTAssertTrue(ListSelectionModifiers.usesExtendedSelection([.shift]))
        XCTAssertTrue(ListSelectionModifiers.usesExtendedSelection([.option]))
        XCTAssertFalse(ListSelectionModifiers.usesExtendedSelection([]))
    }
}
