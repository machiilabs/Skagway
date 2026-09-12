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

    func testCommandClickTogglesIntoSetWithoutMovingFocus() {
        var session = ReviewSession(focusedId: a, selectedIds: [a])
        _ = session.applyListTableSelection(
            newIds: [a, b],
            allVideoIds: ordered,
            previousTableFocusId: a,
            lastClickedId: a,
            flags: commandFlags()
        )
        XCTAssertEqual(session.focusedId, a)
        XCTAssertEqual(session.selectedIds, [a, b])
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
        XCTAssertEqual(session.focusedId, c)
        XCTAssertEqual(session.selectedIds, [a, b, c, d])
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
