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

    func testPlaybackStopEntersSetModeWhenCollecting() {
        var session = ReviewSession(focusedId: b, selectedIds: [a, c])
        session.playbackStopped()
        XCTAssertTrue(session.isSetMode)
        XCTAssertEqual(session.actionIds, [a, c])
        XCTAssertEqual(session.reviewedId(lastSelectedId: a), a)
    }

    func testPlaybackStopStaysOnFocusWhenSetIsEmptyOrSingle() {
        var empty = ReviewSession(focusedId: a, selectedIds: [])
        empty.playbackStopped()
        XCTAssertFalse(empty.isSetMode)
        XCTAssertEqual(empty.actionIds, [a])

        var single = ReviewSession(focusedId: a, selectedIds: [a])
        single.playbackStopped()
        XCTAssertFalse(single.isSetMode)
        XCTAssertEqual(single.actionIds, [a])
    }

    func testInspectSetRequiresTwoOrMore() {
        var session = ReviewSession(focusedId: a, selectedIds: [a])
        session.inspectSet()
        XCTAssertFalse(session.isSetMode)

        session.toggleInSet(b)
        session.inspectSet()
        XCTAssertTrue(session.isSetMode)
        XCTAssertEqual(session.actionIds, [a, b])
    }

    func testFocusClearsSetMode() {
        var session = ReviewSession(focusedId: a, selectedIds: [a, b], inspectorPrefersSelection: true)
        XCTAssertTrue(session.isSetMode)
        session.focus(c)
        XCTAssertFalse(session.isSetMode)
        XCTAssertEqual(session.actionIds, [c])
        XCTAssertEqual(session.selectedIds, [a, b])
    }

    func testPruneDropsInvalidFocusAndSetMembers() {
        var session = ReviewSession(focusedId: d, selectedIds: [a, d], inspectorPrefersSelection: true)
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
        var session = ReviewSession(focusedId: c, selectedIds: [a, b], inspectorPrefersSelection: true)
        XCTAssertEqual(session.reviewedId(lastSelectedId: b), b)
        XCTAssertEqual(session.reviewedId(lastSelectedId: c), session.selectedIds.first)
    }

    func testCollectCirclePlainToggleAddsToSetWithoutMovingFocus() {
        var session = ReviewSession(focusedId: b, selectedIds: [])
        let last = session.applyCollectCircleClick(
            id: a,
            orderedIds: [a, b, c, d],
            anchorId: nil,
            flags: []
        )
        XCTAssertEqual(last, a)
        XCTAssertEqual(session.focusedId, b)
        XCTAssertEqual(session.selectedIds, [a])
    }

    func testCollectCircleShiftSelectsRangeFromAnchor() {
        var session = ReviewSession(focusedId: nil, selectedIds: [a])
        let last = session.applyCollectCircleClick(
            id: d,
            orderedIds: [a, b, c, d],
            anchorId: a,
            flags: [.shift]
        )
        XCTAssertEqual(last, d)
        XCTAssertEqual(session.focusedId, d)
        XCTAssertEqual(session.selectedIds, [a, b, c, d])
    }

    func testCollectCircleCommandToggleDoesNotMoveFocus() {
        var session = ReviewSession(focusedId: c, selectedIds: [a])
        let last = session.applyCollectCircleClick(
            id: b,
            orderedIds: [a, b, c, d],
            anchorId: a,
            flags: [.command]
        )
        XCTAssertEqual(last, b)
        XCTAssertEqual(session.focusedId, c)
        XCTAssertEqual(session.selectedIds, [a, b])
    }

    func testCollectCircleOptionSelectsOnly() {
        var session = ReviewSession(focusedId: a, selectedIds: [a, c])
        let last = session.applyCollectCircleClick(
            id: b,
            orderedIds: [a, b, c, d],
            anchorId: a,
            flags: [.option]
        )
        XCTAssertEqual(last, b)
        XCTAssertEqual(session.focusedId, b)
        XCTAssertEqual(session.selectedIds, [b])
    }

    func testCollectCircleShiftUnionsWithExistingSet() {
        let w = "/w.mp4"
        let x = "/x.mp4"
        let y = "/y.mp4"
        let z = "/z.mp4"
        let ordered = [a, b, c, d, w, x, y, z]

        var session = ReviewSession(focusedId: nil, selectedIds: [a, b, c, d])
        _ = session.applyCollectCircleClick(
            id: w,
            orderedIds: ordered,
            anchorId: d,
            flags: []
        )
        let last = session.applyCollectCircleClick(
            id: z,
            orderedIds: ordered,
            anchorId: w,
            flags: [.shift]
        )
        XCTAssertEqual(last, z)
        XCTAssertEqual(session.focusedId, z)
        XCTAssertEqual(session.selectedIds, [a, b, c, d, w, x, y, z])
    }
}
