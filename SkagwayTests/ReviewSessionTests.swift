import AppKit
import XCTest
@testable import Skagway

final class ReviewSessionTests: XCTestCase {
    private let a = "/a.mp4"
    private let b = "/b.mp4"
    private let c = "/c.mp4"
    private let d = "/d.mp4"

    func testFocusMoveKeepsCollectedSet() {
        var session = ReviewSession(focusedId: a, selectedIds: [a])
        session.toggleInSet(a)
        session.toggleInSet(a)
        session.focus(b)
        XCTAssertEqual(session.focusedId, b)
        XCTAssertEqual(session.selectedIds, [a])
        XCTAssertFalse(session.isSetMode)
        XCTAssertEqual(session.actionIds, [b])
    }

    func testArrowNavigationDoesNotReplaceSet() {
        var session = ReviewSession(focusedId: a, selectedIds: [a, c])
        session.moveFocus(step: 1, orderedIds: [a, b, c, d])
        XCTAssertEqual(session.focusedId, b)
        XCTAssertEqual(session.selectedIds, [a, c])
        // Focus left the collected set — Inspector follows the focused clip.
        XCTAssertFalse(session.isSetMode)
        XCTAssertEqual(session.actionIds, [b])
    }

    func testToggleDoesNotMoveFocus() {
        var session = ReviewSession(focusedId: b, selectedIds: [a])
        session.toggleInSet(b)
        XCTAssertEqual(session.focusedId, b)
        XCTAssertEqual(session.selectedIds, [a, b])
        session.toggleInSet(a)
        XCTAssertEqual(session.focusedId, b)
        XCTAssertEqual(session.selectedIds, [b])
    }

    func testSelectOnlyReplacesSetAndFocus() {
        var session = ReviewSession(focusedId: a, selectedIds: [a, c])
        session.selectOnly(b)
        XCTAssertEqual(session.focusedId, b)
        XCTAssertEqual(session.selectedIds, [b])
        XCTAssertFalse(session.isSetMode)
    }

    func testBatchWhenFocusClearedWithMultiSet() {
        let session = ReviewSession(focusedId: nil, selectedIds: [a, c])
        XCTAssertTrue(session.isSetMode)
        XCTAssertEqual(session.actionIds, [a, c])
        XCTAssertEqual(session.reviewedId(lastSelectedId: a), a)
    }

    func testFocusInSetUsesSingleInspect() {
        let session = ReviewSession(focusedId: a, selectedIds: [a, c])
        XCTAssertFalse(session.isSetMode)
        XCTAssertEqual(session.actionIds, [a])
    }

    func testFocusOutsideSetKeepsSingleInspect() {
        let session = ReviewSession(focusedId: d, selectedIds: [a, b, c])
        XCTAssertFalse(session.isSetMode)
        XCTAssertEqual(session.actionIds, [d])
    }

    func testMultiSelectCmdAddEntersBatchInspect() {
        var session = ReviewSession(focusedId: a, selectedIds: [a])
        XCTAssertFalse(session.isSetMode)
        session.toggleInSetForCollectionEdit(b)
        XCTAssertNil(session.focusedId)
        XCTAssertTrue(session.isSetMode)
        XCTAssertEqual(session.actionIds, [a, b])
    }

    func testPlainClickCollectedTogglesBatchAndFocus() {
        var session = ReviewSession(focusedId: nil, selectedIds: [a, b, c])
        XCTAssertTrue(session.isSetMode)

        _ = session.applyPlainClick(on: a, lastClickedId: nil)
        XCTAssertEqual(session.focusedId, a)
        XCTAssertFalse(session.isSetMode)

        _ = session.applyPlainClick(on: a, lastClickedId: a)
        XCTAssertNil(session.focusedId)
        XCTAssertTrue(session.isSetMode)

        _ = session.applyPlainClick(on: a, lastClickedId: a)
        XCTAssertEqual(session.focusedId, a)
        XCTAssertFalse(session.isSetMode)
    }

    func testPlainClickDifferentCollectedFocusesImmediately() {
        var session = ReviewSession(focusedId: a, selectedIds: [a, b, c])
        _ = session.applyPlainClick(on: b, lastClickedId: a)
        XCTAssertEqual(session.focusedId, b)
        XCTAssertFalse(session.isSetMode)

        var batch = ReviewSession(focusedId: nil, selectedIds: [a, b, c])
        _ = batch.applyPlainClick(on: c, lastClickedId: a)
        XCTAssertEqual(batch.focusedId, c)
        XCTAssertFalse(batch.isSetMode)
    }

    func testPruneDropsInvalidFocusAndSetMembers() {
        var session = ReviewSession(focusedId: d, selectedIds: [a, d])
        session.prune(validIds: [a, b])
        XCTAssertEqual(session.selectedIds, [a])
        XCTAssertEqual(session.focusedId, a)
        XCTAssertFalse(session.isSetMode)
    }

    func testRemapPathUpdatesFocusAndSet() {
        var session = ReviewSession(focusedId: a, selectedIds: [a, b])
        session.remapPath(from: a, to: "/a-renamed.mp4")
        XCTAssertEqual(session.focusedId, "/a-renamed.mp4")
        XCTAssertEqual(session.selectedIds, ["/a-renamed.mp4", b])
    }

    func testNoFocusWithMultiSetIsSetMode() {
        var session = ReviewSession(focusedId: nil, selectedIds: [a, b])
        XCTAssertTrue(session.isSetMode)
        XCTAssertEqual(session.actionIds, [a, b])
        session.focus(c)
        XCTAssertFalse(session.isSetMode)
        XCTAssertEqual(session.actionIds, [c])
        XCTAssertEqual(session.selectedIds, [a, b])
    }

    func testReviewedIdInSetModePrefersLastSelectedInSet() {
        var session = ReviewSession(focusedId: nil, selectedIds: [a, b])
        XCTAssertEqual(session.reviewedId(lastSelectedId: b), b)
        XCTAssertEqual(session.reviewedId(lastSelectedId: c), session.selectedIds.first)
    }

    func testListShiftUsesFocusedIdWhenNoLastClick() {
        var session = ReviewSession(focusedId: b, selectedIds: [a])
        let last = session.applyListTableSelection(
            newIds: [a, b, c, d],
            allVideoIds: [a, b, c, d],
            previousTableFocusId: b,
            lastClickedId: nil,
            flags: [.shift]
        )
        XCTAssertEqual(last, d)
        XCTAssertNil(session.focusedId)
        XCTAssertEqual(session.selectedIds, [a, b, c, d])
        XCTAssertTrue(session.isSetMode)
    }

    func testListCommandAddEntersBatchInspect() {
        var session = ReviewSession(focusedId: c, selectedIds: [a])
        let last = session.applyListTableSelection(
            newIds: [b],
            allVideoIds: [a, b, c, d],
            previousTableFocusId: c,
            lastClickedId: a,
            flags: [.command]
        )
        XCTAssertEqual(last, b)
        XCTAssertNil(session.focusedId)
        XCTAssertEqual(session.selectedIds, [a, b])
        XCTAssertTrue(session.isSetMode)
    }

    func testListOptionSelectsOnly() {
        var session = ReviewSession(focusedId: a, selectedIds: [a, c])
        let last = session.applyListTableSelection(
            newIds: [b],
            allVideoIds: [a, b, c, d],
            previousTableFocusId: a,
            lastClickedId: a,
            flags: [.option]
        )
        XCTAssertEqual(last, b)
        XCTAssertEqual(session.focusedId, b)
        XCTAssertEqual(session.selectedIds, [b])
    }
}
