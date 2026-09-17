import AppKit
import QuartzCore
import SwiftUI

/// Full-screen transport + exit control + top-leading traffic lights.
///
/// Idle model:
/// - Real pointer **movement** (or click) → show chrome and (re)schedule hide.
/// - Mouse-wheel / trackpad scroll over the video → show chrome; stay up while the
///   scroll gesture (or its momentum) is active; each discrete notch also resets idle.
/// - Stationary / spurious tracking noise is ignored (movement threshold).
/// - Timer fire: if pointer is in the bar / lights band or wheel-scrubbing → reschedule; else hide.
/// - After hide, only re-enable `acceptsMouseMovedEvents` — do **not** rebuild tracking
///   areas (that synthesizes `mouseEntered` and immediately re-shows chrome).
@MainActor
final class FullscreenTransportChromeView: NSView {
    static let idleSeconds: TimeInterval = 2.5
    /// Ignore sub-pixel / tracking-area jitter so idle can actually elapse.
    private static let activitySlop: CGFloat = 3

    private static let previewClearance: CGFloat = PlaybackTimelineBar.scrubPreviewHeight + 16
    static var chromeHeight: CGFloat { previewClearance + PlaybackTimelineBar.barHeight }

    private let viewModel: LibraryViewModel
    private let timelineHost: NSHostingView<FullscreenTimelineOverlay>
    private let trafficLightsHost: NSHostingView<PlayerTrafficLights>
    private let closeButton = NSButton()
    private var hideWorkItem: DispatchWorkItem?
    private var lastActivityLocation: CGPoint?
    private var wheelScrubActive = false
    private(set) var isChromeVisible = true

    /// Called after chrome hides so the window can re-enable mouse-moved delivery (lightweight).
    var onDidHide: (() -> Void)?
    private let onStopPlayback: () -> Void
    private weak var exitTarget: AnyObject?
    private let exitAction: Selector

    private var barHitRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: PlaybackTimelineBar.barHeight)
    }

    private var trafficLightsHitRect: NSRect {
        let height: CGFloat = 44
        let width: CGFloat = 88
        return NSRect(x: 0, y: bounds.height - height, width: width, height: height)
    }

    init(
        viewModel: LibraryViewModel,
        exitTarget: AnyObject,
        exitAction: Selector,
        onStopPlayback: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.exitTarget = exitTarget
        self.exitAction = exitAction
        self.onStopPlayback = onStopPlayback
        timelineHost = NSHostingView(rootView: FullscreenTimelineOverlay(viewModel: viewModel))
        trafficLightsHost = NSHostingView(
            rootView: PlayerTrafficLights(
                mode: .fullScreen,
                onClose: {},
                onYellow: {},
                onGreen: {}
            )
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor

        timelineHost.wantsLayer = true
        timelineHost.layer?.masksToBounds = false
        timelineHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timelineHost)

        trafficLightsHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trafficLightsHost)
        rebindTrafficLights()

        closeButton.bezelStyle = .accessoryBarAction
        closeButton.image = NSImage(
            systemSymbolName: "arrow.down.right.and.arrow.up.left",
            accessibilityDescription: "Exit Full Screen"
        )
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.target = exitTarget
        closeButton.action = exitAction
        closeButton.toolTip = "Exit Full Screen (⌃⌘F)"
        closeButton.contentTintColor = .labelColor
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            timelineHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            timelineHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            timelineHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            timelineHost.heightAnchor.constraint(equalToConstant: Self.chromeHeight),

            trafficLightsHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            trafficLightsHost.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            closeButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        alphaValue = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func rebindTrafficLights() {
        trafficLightsHost.rootView = PlayerTrafficLights(
            mode: .fullScreen,
            onClose: { [weak self] in
                self?.onStopPlayback()
            },
            onYellow: { [weak self] in
                guard let self else { return }
                self.viewModel.setPlayerCompactMode(true)
                _ = self.exitTarget?.perform(self.exitAction)
            },
            onGreen: { [weak self] in
                guard let self else { return }
                self.viewModel.setPlayerCompactMode(false)
                _ = self.exitTarget?.perform(self.exitAction)
            }
        )
    }

    func beginIdleCycle() {
        lastActivityLocation = nil
        wheelScrubActive = false
        applyVisible(true, animated: false)
        scheduleHide()
    }

    func shutdown() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        wheelScrubActive = false
        onDidHide = nil
    }

    /// - Parameter force: click / drag — always counts as activity even without movement.
    func noteMouseActivity(locationInWindow: CGPoint, force: Bool = false) {
        if !force, let last = lastActivityLocation {
            let dx = locationInWindow.x - last.x
            let dy = locationInWindow.y - last.y
            if (dx * dx + dy * dy) < (Self.activitySlop * Self.activitySlop) {
                return
            }
        }
        lastActivityLocation = locationInWindow
        applyVisible(true, animated: true)
        scheduleHide()
    }

    /// Mouse-wheel / trackpad scroll over the player — keep transport visible while scrubbing.
    func noteScrollWheel(locationInWindow: CGPoint, event: NSEvent) {
        let phaseActive = Self.isScrollPhaseActive(event.phase)
        let momentumActive = Self.isScrollPhaseActive(event.momentumPhase)
        if event.phase == .none, event.momentumPhase == .none {
            wheelScrubActive = false
        } else {
            wheelScrubActive = phaseActive || momentumActive
        }
        noteMouseActivity(locationInWindow: locationInWindow, force: true)
    }

    private static func isScrollPhaseActive(_ phase: NSEvent.Phase) -> Bool {
        phase.contains(.began) || phase.contains(.changed) || phase.contains(.mayBegin)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isChromeVisible else { return nil }
        guard barHitRect.contains(point) || trafficLightsHitRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Visibility

    private func applyVisible(_ visible: Bool, animated: Bool) {
        if visible == isChromeVisible, visible ? alphaValue > 0.99 : alphaValue < 0.01 {
            return
        }
        isChromeVisible = visible
        closeButton.isEnabled = visible

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = visible ? 0.12 : 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().alphaValue = visible ? 1 : 0
            }
        } else {
            alphaValue = visible ? 1 : 0
        }

        if !visible {
            onDidHide?()
        }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fireIdleHide()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleSeconds, execute: work)
    }

    private func fireIdleHide() {
        hideWorkItem = nil
        if wheelScrubActive || isPointerInsideChrome() {
            scheduleHide()
            return
        }
        applyVisible(false, animated: true)
    }

    private func isPointerInsideChrome() -> Bool {
        guard let window else { return false }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = convert(inWindow, from: nil)
        return barHitRect.contains(local) || trafficLightsHitRect.contains(local)
    }
}

/// Full-window mouse-move sensor. Clicks pass through (`hitTest` → nil).
/// Uses `.activeInKeyWindow` (not `.activeAlways`) to avoid continuous spurious moves
/// that permanently reset the idle timer.
final class FullscreenMouseMoveCatcher: NSView {
    var onMouseMoved: ((CGPoint) -> Void)?
    private var tracking: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .mouseMoved,
                .inVisibleRect,
                .enabledDuringMouseDrag,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseMoved?(event.locationInWindow)
    }
}

struct FullscreenTimelineOverlay: View {
    @Bindable var viewModel: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            PlaybackTimelineBar(viewModel: viewModel, controlsVisible: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
