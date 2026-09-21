import XCTest
import AppKit
@testable import Skagway

@MainActor
final class ScrollIndexHUDOverlayTests: XCTestCase {
    func testLocateBindsToWallScrollViewNotInspector() {
        let fixture = Fixture()
        let found = ScrollIndexHUDOverlay.Coordinator.locateScrollView(
            from: fixture.host,
            mode: .grid
        )
        XCTAssertTrue(found === fixture.wall, "HUD must attach to the wall scroller")
        XCTAssertFalse(found === fixture.inspector, "HUD must not attach to the Inspector scroller")
    }

    func testAttachParentsChipToWallScrollViewEvenWhenHostIsZeroSized() {
        let fixture = Fixture()
        XCTAssertEqual(fixture.host.bounds, .zero)

        let coordinator = ScrollIndexHUDOverlay.Coordinator()
        coordinator.mode = .grid
        coordinator.attachIfNeeded(from: fixture.host)

        XCTAssertTrue(coordinator.debugTrackedScrollView === fixture.wall)
        XCTAssertTrue(
            coordinator.debugChipSuperview === fixture.wall,
            "Chip parented to a 0×0 representable host is clipped (1168)"
        )
        XCTAssertFalse(coordinator.debugChipSuperview === fixture.inspector)
        coordinator.tearDown()
    }

    func testClipBoundsChangeFiresHUDObserver() async {
        let fixture = Fixture()
        let coordinator = ScrollIndexHUDOverlay.Coordinator()
        coordinator.mode = .grid
        coordinator.attachIfNeeded(from: fixture.host)
        XCTAssertTrue(coordinator.debugTrackedScrollView === fixture.wall)
        XCTAssertEqual(coordinator.debugBoundsEvents, 0)

        let clip = fixture.wall.contentView
        XCTAssertTrue(clip.postsBoundsChangedNotifications)
        var bounds = clip.bounds
        bounds.origin.y += 80
        clip.bounds = bounds

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(
            coordinator.debugBoundsEvents,
            0,
            "NSView.boundsDidChangeNotification must reach the HUD coordinator"
        )
        coordinator.tearDown()
    }

    func testHostFillsSuperviewSoOverlayIsNotZeroSized() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let host = ScrollIndexHUDOverlay.HostView(frame: .zero)
        parent.addSubview(host)
        XCTAssertEqual(host.frame.size, parent.bounds.size)
    }

    // MARK: - 1167-like split: wall pane + Inspector pane

    private struct Fixture {
        let host: ScrollIndexHUDOverlay.HostView
        let wall: NSScrollView
        let inspector: NSScrollView
        let split: NSSplitView

        init() {
            let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            split.isVertical = true

            let browser = ClippingContainer(frame: NSRect(x: 0, y: 0, width: 820, height: 800))
            let detail = ClippingContainer(frame: NSRect(x: 0, y: 0, width: 380, height: 800))

            let wall = NSScrollView(frame: browser.bounds)
            wall.hasVerticalScroller = true
            wall.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 4000))
            browser.addSubview(wall)

            // Overlay is a sibling of the wall ScrollView (SwiftUI `.overlay` on ScrollView).
            // Zero-size wrapper matches the 1168 representable host (chip must not live there).
            let overlayWrap = NSView(frame: .zero)
            browser.addSubview(overlayWrap)
            let host = ScrollIndexHUDOverlay.HostView(frame: .zero)
            overlayWrap.addSubview(host)

            let inspector = NSScrollView(frame: detail.bounds)
            inspector.hasVerticalScroller = true
            inspector.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 600))
            detail.addSubview(inspector)

            split.addArrangedSubview(browser)
            split.addArrangedSubview(detail)
            split.adjustSubviews()

            self.host = host
            self.wall = wall
            self.inspector = inspector
            self.split = split
        }
    }
}
