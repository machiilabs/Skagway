import AppKit
import SwiftUI

/// The single resizable, movable player surface. Positioned within the content area overlay;
/// Compact snaps to the top-right inspector footprint, otherwise the panel floats freely.
/// The title bar drags to reposition; edges and corners drag to resize (standard window cursors).
/// Size and position are persisted to `viewModel` on release.
///
/// Chrome (timeline, title, size controls) uses the same idle model as fullscreen: show on
/// pointer activity, stay up while over the transport/title chrome or while mouse-wheel
/// scrubbing the video, hide after inactivity even if the cursor is still on the video.
struct FloatingPlayerPanel: View {
    let video: Video
    @Bindable var viewModel: LibraryViewModel
    /// Size of the content area this panel floats in (from the caller's GeometryReader).
    let available: CGSize

    @State private var dragSize: CGSize?
    @State private var dragStartSize: CGSize?
    /// Live center point during title-bar or resize drag. Nil outside a drag.
    @State private var dragCenter: CGPoint?
    /// Center snapshot at the start of any drag, used to compute the delta.
    @State private var dragStartCenter: CGPoint?

    @State private var controlsVisible = true
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var pointerOverChrome = false
    /// Trackpad/Magic Mouse scroll gesture in progress (phase / momentum). Classic notch
    /// wheels fire discrete events with `.none` phases — those only force-reset the idle timer.
    @State private var wheelScrubActive = false
    @State private var lastActivityPoint: CGPoint?

    private let minSize = CGSize(width: 240, height: 140)
    private let outerPadding: CGFloat = 12
    /// Match fullscreen idle so compact / windowed / fullscreen feel the same.
    private static let idleSeconds: TimeInterval = FullscreenTransportChromeView.idleSeconds
    private static let activitySlop: CGFloat = 3
    private static let titleChromeHeight: CGFloat = 34
    /// Invisible edge grab thickness (not drawn — hit-test only).
    private static let resizeEdgeThickness: CGFloat = 6
    /// Corner grab size (wins over edges where they meet).
    private static let resizeCornerSize: CGFloat = 12

    // MARK: - Size helpers

    private var compactSize: CGSize {
        // Matches the Inspector's last user-adjusted width × hero height, even when the Inspector
        // pane is hidden — Compact stays that footprint, pinned top-right of the content area.
        let detailWidth = CGFloat(viewModel.browsingLayout.detailColumnWidth(for: viewModel.viewMode))
        // Matches the Inspector's user-adjustable, persisted hero height exactly (see
        // `LibraryViewModel.inspectorHeroHeight`), so Compact always snaps to whatever footprint
        // the user has actually set the hero to, not an independently-recomputed guess. Prefers
        // the live drag value (if the hero's resize handle is actively being dragged) so an
        // already-open compact player tracks the resize in realtime instead of only snapping to
        // the new size once the drag ends.
        let heroHeight = viewModel.inspectorHeroLiveHeight ?? viewModel.inspectorHeroHeight
        let w = min(max(detailWidth - 24, minSize.width), maxSize.width)
        let h = min(max(heroHeight + 4, minSize.height), maxSize.height)
        return CGSize(width: w, height: h)
    }

    private var maxSize: CGSize {
        CGSize(width: max(minSize.width, available.width - outerPadding * 2),
               height: max(minSize.height, available.height - outerPadding * 2))
    }

    private func clampSize(_ s: CGSize) -> CGSize {
        CGSize(width: min(max(s.width, minSize.width), maxSize.width),
               height: min(max(s.height, minSize.height), maxSize.height))
    }

    private var size: CGSize {
        if let dragSize { return dragSize }
        if viewModel.isPlayerCompactMode { return compactSize }
        return clampSize(viewModel.playerFloatingSize)
    }

    // MARK: - Position helpers

    /// Full frame size of the panel including its outer padding on all sides.
    private var totalSize: CGSize {
        CGSize(width: size.width + 2 * outerPadding, height: size.height + 2 * outerPadding)
    }

    /// Clamp a proposed center point so the entire panel stays within the available area.
    private func clampCenter(_ c: CGPoint, totalW: CGFloat, totalH: CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(c.x, totalW / 2), available.width  - totalW / 2),
            y: min(max(c.y, totalH / 2), available.height - totalH / 2)
        )
    }

    /// Default center for the current mode: top-right for Compact, centered for S/M/L.
    private var defaultCenter: CGPoint {
        let tw = totalSize.width; let th = totalSize.height
        if viewModel.isPlayerCompactMode {
            return CGPoint(x: available.width - tw / 2, y: th / 2)
        }
        return CGPoint(x: available.width / 2, y: available.height / 2)
    }

    /// Committed center from the ViewModel (or the mode default), clamped to current bounds.
    private var baseCenter: CGPoint {
        if viewModel.isPlayerCompactMode { return defaultCenter }
        let tw = totalSize.width; let th = totalSize.height
        let raw = viewModel.playerFloatingPosition ?? defaultCenter
        return clampCenter(raw, totalW: tw, totalH: th)
    }

    /// Effective center used for positioning: live drag value if dragging, otherwise the base.
    private var effectiveCenter: CGPoint {
        dragCenter ?? baseCenter
    }

    /// Forced true while a resize or move drag is active.
    private var effectiveControlsVisible: Bool {
        controlsVisible || dragSize != nil || dragCenter != nil
    }

    // MARK: - Body

    var body: some View {
        // This root fills the entire content pane (Wall/List + Inspector) purely so `available`
        // reflects the true floating/clamping bounds — nothing is drawn here. Without
        // `allowsHitTesting(false)`, a `Color` view still claims hit-testing across its whole
        // frame by default, silently swallowing clicks anywhere in that pane while playing —
        // e.g. the Inspector's own hero-resize handle, well outside where the player is visible.
        // `panelContent` is composited via `.overlay` as an independent layer, so it keeps its own
        // hit-testing (buttons, drag handles) unaffected by this.
        Color.clear
            .allowsHitTesting(false)
            .overlay {
                panelContent
                    .position(effectiveCenter)
            }
    }

    // MARK: - Panel content

    private var panelContent: some View {
        OverlayInlinePlayerView(video: video, viewModel: viewModel, controlsVisible: effectiveControlsVisible)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.3), lineWidth: 1)
            )
            .overlay(alignment: .top) {
                // Interior title drag — inset so top edge/corners remain resize targets.
                // Leave leading room for traffic lights (they sit above this layer).
                titleBarDragArea
                    .padding(.top, Self.resizeEdgeThickness)
                    .padding(.trailing, Self.resizeCornerSize)
                    .padding(.leading, Self.resizeCornerSize + PlayerTrafficLights.leadingChromeWidth)
                    .opacity(effectiveControlsVisible ? 1 : 0)
                    .allowsHitTesting(effectiveControlsVisible)
            }
            .overlay(alignment: .topLeading) {
                // Supplement to the bottom size cluster (kept in all modes).
                PlayerTrafficLights(
                    mode: viewModel.isPlayerCompactMode ? .compact : .windowed,
                    onClose: { viewModel.isPlayingInline = false },
                    onYellow: {
                        if viewModel.isPlayerCompactMode {
                            // Option A: no-op. Option B: step up to Windowed.
                            guard PlayerTrafficLights.compactMapping == .optionB_compactLadder else { return }
                            viewModel.setPlayerCompactMode(false)
                        } else {
                            viewModel.setPlayerCompactMode(true)
                        }
                    },
                    onGreen: {
                        if viewModel.isPlayerCompactMode {
                            switch PlayerTrafficLights.compactMapping {
                            case .optionA_yellowNopGreenWindowed:
                                viewModel.setPlayerCompactMode(false)
                            case .optionB_compactLadder:
                                viewModel.setPlayerCompactMode(false)
                                viewModel.isPlayerFullScreen = true
                            }
                        } else {
                            viewModel.isPlayerFullScreen = true
                        }
                    }
                )
                // Vertically center in the 30pt title bar (same band as the window title).
                .frame(height: 30, alignment: .center)
                .padding(.leading, PlayerTrafficLights.leadingInset)
                .opacity(effectiveControlsVisible ? 1 : 0)
                .allowsHitTesting(effectiveControlsVisible)
            }
            // Edge/corner resize — Windowed only (Compact stays locked to the inspector footprint).
            // Under size chrome so Compact/Windowed/Close keep priority in the bottom-trailing cluster.
            .overlay(alignment: .top) {
                resizeStrip(.north) {
                    Color.clear
                        .frame(height: Self.resizeEdgeThickness)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Self.resizeCornerSize)
                }
            }
            .overlay(alignment: .bottom) {
                resizeStrip(.south) {
                    Color.clear
                        .frame(height: Self.resizeEdgeThickness)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Self.resizeCornerSize)
                }
            }
            .overlay(alignment: .leading) {
                resizeStrip(.west) {
                    Color.clear
                        .frame(width: Self.resizeEdgeThickness)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, Self.resizeCornerSize)
                }
            }
            .overlay(alignment: .trailing) {
                resizeStrip(.east) {
                    Color.clear
                        .frame(width: Self.resizeEdgeThickness)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, Self.resizeCornerSize)
                }
            }
            .overlay(alignment: .topLeading) {
                resizeStrip(.northWest) {
                    Color.clear.frame(width: Self.resizeCornerSize, height: Self.resizeCornerSize)
                }
            }
            .overlay(alignment: .topTrailing) {
                resizeStrip(.northEast) {
                    Color.clear.frame(width: Self.resizeCornerSize, height: Self.resizeCornerSize)
                }
            }
            .overlay(alignment: .bottomLeading) {
                resizeStrip(.southWest) {
                    Color.clear.frame(width: Self.resizeCornerSize, height: Self.resizeCornerSize)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                resizeStrip(.southEast) {
                    Color.clear.frame(width: Self.resizeCornerSize, height: Self.resizeCornerSize)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                sizeControls
                    .opacity(effectiveControlsVisible ? 1 : 0)
                    .allowsHitTesting(effectiveControlsVisible)
            }
            .background {
                PanelChromeMouseTracker(
                    transportHeight: PlaybackTimelineBar.barHeight + 8,
                    titleHeight: Self.titleChromeHeight,
                    onActivity: { point, overChrome, force in
                        notePointerActivity(at: point, overChrome: overChrome, force: force)
                    },
                    onScrollWheel: { point, overChrome, event in
                        noteScrollWheel(at: point, overChrome: overChrome, event: event)
                    },
                    onExit: {
                        pointerOverChrome = false
                        wheelScrubActive = false
                        scheduleChromeHide()
                    }
                )
            }
            .onAppear {
                controlsVisible = true
                scheduleChromeHide()
            }
            .onDisappear {
                controlsHideTask?.cancel()
                controlsHideTask = nil
            }
            .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
            .padding(outerPadding)
    }

    // MARK: - Idle chrome (parity with fullscreen)

    private func notePointerActivity(at point: CGPoint, overChrome: Bool, force: Bool = false) {
        if !force, let last = lastActivityPoint {
            let dx = point.x - last.x
            let dy = point.y - last.y
            if (dx * dx + dy * dy) < (Self.activitySlop * Self.activitySlop) {
                pointerOverChrome = overChrome
                return
            }
        }
        lastActivityPoint = point
        pointerOverChrome = overChrome
        withAnimation(.easeInOut(duration: 0.15)) { controlsVisible = true }
        scheduleChromeHide()
    }

    private func noteScrollWheel(at point: CGPoint, overChrome: Bool, event: NSEvent) {
        let phaseActive = Self.isScrollPhaseActive(event.phase)
        let momentumActive = Self.isScrollPhaseActive(event.momentumPhase)
        // Classic mouse wheels usually report `.none` for both — each notch still counts as activity.
        if event.phase == .none, event.momentumPhase == .none {
            wheelScrubActive = false
        } else {
            wheelScrubActive = phaseActive || momentumActive
        }
        notePointerActivity(at: point, overChrome: overChrome, force: true)
    }

    private static func isScrollPhaseActive(_ phase: NSEvent.Phase) -> Bool {
        phase.contains(.began) || phase.contains(.changed) || phase.contains(.mayBegin)
    }

    private func scheduleChromeHide() {
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.idleSeconds))
            guard !Task.isCancelled else { return }
            // Keep chrome up while dragging, resting on transport/title, or wheel-scrubbing.
            if dragSize != nil || dragCenter != nil || pointerOverChrome || wheelScrubActive {
                scheduleChromeHide()
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
        }
    }

    // MARK: - Title bar drag

    /// Transparent 30 pt (25% larger than the original 24pt) overlay on the header; drag moves
    /// the panel. Only hit-testable while `controlsVisible` (see `panelContent`), which also means
    /// it's never active unless the mouse is already over the panel to begin with.
    private var titleBarDragArea: some View {
        Color.clear
            .frame(height: 30 + outerPadding)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartCenter == nil {
                            dragStartCenter = baseCenter   // snapshot before exiting compact
                            if viewModel.isPlayerCompactMode {
                                // Freeze the current (compact) size as the new floating size so
                                // dragging doesn't also cause a visual resize jump.
                                viewModel.playerFloatingSize = size
                                viewModel.setPlayerCompactMode(false)
                            }
                        }
                        let tw = totalSize.width; let th = totalSize.height
                        let proposed = CGPoint(
                            x: dragStartCenter!.x + value.translation.width,
                            y: dragStartCenter!.y + value.translation.height
                        )
                        dragCenter = clampCenter(proposed, totalW: tw, totalH: th)
                    }
                    .onEnded { _ in
                        if let c = dragCenter { viewModel.playerFloatingPosition = c }
                        dragCenter = nil
                        dragStartCenter = nil
                        scheduleChromeHide()
                    }
            )
            .help("Drag to move")
    }

    // MARK: - Size controls

    /// Compact / Windowed / Full screen snaps. Free sizing is edge/corner drag.
    private var sizeControls: some View {
        HStack(spacing: 4) {
            iconButton("camera.viewfinder", help: "Make thumbnail from current frame (⌥⌘M)") {
                viewModel.playback.makeThumbnailFromCurrentFrame()
            }
            iconButton(
                "rectangle",
                help: viewModel.isInspectorVisible
                    ? "Compact (follows the inspector width) (⌃⌘C)"
                    : "Compact needs the Inspector — show it first (⌘I)",
                disabled: !viewModel.isInspectorVisible
            ) {
                viewModel.setPlayerCompactMode(true)
            }
            iconButton("macwindow", help: "Windowed — last used size (⌃⌘W)") {
                viewModel.setPlayerCompactMode(false)
            }
            iconButton("arrow.up.left.and.arrow.down.right", help: "Full screen (⌃⌘F)") {
                viewModel.isPlayerFullScreen = true
            }
            Divider().frame(height: 12).overlay(Color.appTextSecondary.opacity(0.4))
            // Mouse-only equivalent of Escape (which already stops playback the same way — see
            // ContentView's key monitor). A close button lived in the title bar once, but that
            // whole area is covered by `titleBarDragArea`'s hit-testable drag surface, which
            // claimed every tap before it reached the button underneath, so it was removed as
            // dead weight rather than fixed. This lives here instead, outside the drag area.
            iconButton("xmark", help: "Stop playback (Esc)") {
                viewModel.isPlayingInline = false
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .padding(.top, 2)
    }

    private func iconButton(
        _ systemName: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                // 14pt vs. the original .caption2 (~11pt) — 25% larger, matching the drag bar.
                .font(.system(size: 14, weight: .semibold))
                // Padding/background moved inside the label (were outside .buttonStyle below) so
                // .contentShape covers the full capsule — a .plain button otherwise only hit-tests
                // the icon glyph itself, leaving the visible padded circle around it unclickable.
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.appSurface.opacity(0.85), in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.appTextSecondary)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        // Sitting over the player's title/drag bar area otherwise resolves the hover cursor to
        // an I-beam (text-edit) instead of the normal arrow every other button in the app shows.
        .onHover { hovering in
            if hovering { NSCursor.arrow.set() }
        }
        .help(help)
    }

    // MARK: - Edge / corner resize

    private enum ResizeEdge {
        case north, south, east, west
        case northEast, northWest, southEast, southWest

        var affectsWidth: Bool {
            switch self {
            case .east, .west, .northEast, .northWest, .southEast, .southWest: true
            case .north, .south: false
            }
        }

        var affectsHeight: Bool {
            switch self {
            case .north, .south, .northEast, .northWest, .southEast, .southWest: true
            case .east, .west: false
            }
        }

        /// Growing when dragging in the positive translation direction for this edge.
        func sizeDelta(translation: CGSize) -> CGSize {
            var dw: CGFloat = 0
            var dh: CGFloat = 0
            if affectsWidth {
                switch self {
                case .east, .northEast, .southEast: dw = translation.width
                case .west, .northWest, .southWest: dw = -translation.width
                default: break
                }
            }
            if affectsHeight {
                switch self {
                case .south, .southEast, .southWest: dh = translation.height
                case .north, .northEast, .northWest: dh = -translation.height
                default: break
                }
            }
            return CGSize(width: dw, height: dh)
        }

        var cursor: NSCursor {
            switch self {
            case .north, .south:
                return .resizeUpDown
            case .east, .west:
                return .resizeLeftRight
            case .northEast:
                return .frameResize(
                    position: .topTrailing(relativeTo: .leftToRight),
                    directions: .all
                )
            case .northWest:
                return .frameResize(
                    position: .topLeading(relativeTo: .leftToRight),
                    directions: .all
                )
            case .southEast:
                return .frameResize(
                    position: .bottomTrailing(relativeTo: .leftToRight),
                    directions: .all
                )
            case .southWest:
                return .frameResize(
                    position: .bottomLeading(relativeTo: .leftToRight),
                    directions: .all
                )
            }
        }
    }

    /// Invisible hit zone for one edge or corner (no drawn affordance). Disabled in Compact.
    private func resizeStrip<Content: View>(
        _ edge: ResizeEdge,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let enabled = !viewModel.isPlayerCompactMode
        return content()
            .contentShape(Rectangle())
            .gesture(resizeDragGesture(for: edge))
            .onHover { hovering in
                guard enabled else { return }
                if hovering {
                    edge.cursor.push()
                } else {
                    NSCursor.pop()
                }
            }
            .help("Drag to resize")
            .allowsHitTesting(enabled)
    }

    private func resizeDragGesture(for edge: ResizeEdge) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if dragStartSize == nil {
                    dragStartSize = size
                    dragStartCenter = effectiveCenter
                    if viewModel.isPlayerCompactMode {
                        viewModel.playerFloatingSize = size
                    }
                    viewModel.setPlayerCompactMode(false)
                }
                applyResize(edge: edge, translation: value.translation)
            }
            .onEnded { _ in
                if let s = dragSize { viewModel.playerFloatingSize = s }
                if let c = dragCenter { viewModel.playerFloatingPosition = c }
                dragSize = nil
                dragStartSize = nil
                dragCenter = nil
                dragStartCenter = nil
                scheduleChromeHide()
            }
    }

    /// Resize while keeping the opposite edge/corner fixed in the content area.
    private func applyResize(edge: ResizeEdge, translation: CGSize) {
        guard let baseSize = dragStartSize, let startCtr = dragStartCenter else { return }
        let delta = edge.sizeDelta(translation: translation)
        let proposed = CGSize(
            width: (baseSize.width + delta.width).rounded(),
            height: (baseSize.height + delta.height).rounded()
        )
        let newSize = clampSize(proposed)

        let baseTotalW = baseSize.width + 2 * outerPadding
        let baseTotalH = baseSize.height + 2 * outerPadding
        let newTotalW = newSize.width + 2 * outerPadding
        let newTotalH = newSize.height + 2 * outerPadding

        let left = startCtr.x - baseTotalW / 2
        let right = startCtr.x + baseTotalW / 2
        let top = startCtr.y - baseTotalH / 2
        let bottom = startCtr.y + baseTotalH / 2

        var newCtr = startCtr
        if edge.affectsWidth {
            switch edge {
            case .east, .northEast, .southEast:
                // Left edge fixed.
                newCtr.x = left + newTotalW / 2
            case .west, .northWest, .southWest:
                // Right edge fixed.
                newCtr.x = right - newTotalW / 2
            default:
                break
            }
        }
        if edge.affectsHeight {
            switch edge {
            case .south, .southEast, .southWest:
                // Top edge fixed.
                newCtr.y = top + newTotalH / 2
            case .north, .northEast, .northWest:
                // Bottom edge fixed.
                newCtr.y = bottom - newTotalH / 2
            default:
                break
            }
        }

        dragSize = newSize
        dragCenter = clampCenter(newCtr, totalW: newTotalW, totalH: newTotalH)
    }
}

// MARK: - Mouse activity (idle chrome)

/// Pass-through tracker over the player panel. Reports moves and whether the pointer is in the
/// bottom transport band or top title strip (chrome stay-up zones). Scroll-wheel events use a
/// window-scoped local monitor because `hitTest` returns nil (so SwiftUI/AVPlayerView still
/// receive the wheel for seeking).
private struct PanelChromeMouseTracker: NSViewRepresentable {
    var transportHeight: CGFloat
    var titleHeight: CGFloat
    var onActivity: (_ point: CGPoint, _ overChrome: Bool, _ force: Bool) -> Void
    var onScrollWheel: (_ point: CGPoint, _ overChrome: Bool, _ event: NSEvent) -> Void
    var onExit: () -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.transportHeight = transportHeight
        view.titleHeight = titleHeight
        view.onActivity = onActivity
        view.onScrollWheel = onScrollWheel
        view.onExit = onExit
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        nsView.transportHeight = transportHeight
        nsView.titleHeight = titleHeight
        nsView.onActivity = onActivity
        nsView.onScrollWheel = onScrollWheel
        nsView.onExit = onExit
    }

    final class TrackerView: NSView {
        var transportHeight: CGFloat = 0
        var titleHeight: CGFloat = 0
        var onActivity: ((CGPoint, Bool, Bool) -> Void)?
        var onScrollWheel: ((CGPoint, Bool, NSEvent) -> Void)?
        var onExit: (() -> Void)?
        private var tracking: NSTrackingArea?
        private var scrollMonitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
            rebuildTracking()
            refreshScrollMonitor()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeScrollMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            rebuildTracking()
        }

        private func rebuildTracking() {
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            tracking = area
        }

        private func refreshScrollMonitor() {
            removeScrollMonitor()
            guard window != nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                guard event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let overChrome = point.y <= self.transportHeight || point.y >= self.bounds.height - self.titleHeight
                self.onScrollWheel?(point, overChrome, event)
                return event
            }
        }

        private func removeScrollMonitor() {
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
                self.scrollMonitor = nil
            }
        }

        private func report(_ event: NSEvent, force: Bool = false) {
            let point = convert(event.locationInWindow, from: nil)
            let overChrome = point.y <= transportHeight || point.y >= bounds.height - titleHeight
            onActivity?(point, overChrome, force)
        }

        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseDragged(with event: NSEvent) { report(event, force: true) }
        override func mouseExited(with event: NSEvent) { onExit?() }
    }
}
