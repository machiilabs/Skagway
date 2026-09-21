import AppKit
import SwiftUI

/// Compact sort-index chip parked immediately left of the native vertical scroller thumb.
///
/// Native scrollbars stay in place — this overlay is hit-test transparent. Shown while the user
/// drags the thumb or a trackpad/mouse live-scroll / fling is in progress; fades out when motion stops.
struct ScrollIndexHUDOverlay: NSViewRepresentable {
    enum Mode { case grid, list }

    var viewModel: LibraryViewModel
    var mode: Mode

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView(frame: .zero)
        view.setAccessibilityElement(false)
        context.coordinator.host = view
        return view
    }

    func updateNSView(_ nsView: HostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.host = nsView
        coordinator.mode = mode
        coordinator.viewModel = viewModel
        DispatchQueue.main.async { [weak nsView, weak coordinator] in
            guard let nsView, let coordinator else { return }
            Task { @MainActor in
                coordinator.attachIfNeeded(from: nsView)
            }
        }
    }

    /// Overlay `NSViewRepresentable` has no intrinsic size. Without this, SwiftUI keeps the
    /// host at 0×0 (1168's `.frame(maxWidth: .infinity)` only sized the SwiftUI wrapper).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    static func dismantleNSView(_ nsView: HostView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    // MARK: - Host

    final class HostView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isFlipped: Bool { false }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            autoresizingMask = [.width, .height]
            if let superview { frame = superview.bounds }
        }

        override func resize(withOldSuperviewSize oldSize: NSSize) {
            super.resize(withOldSuperviewSize: oldSize)
            if let superview { frame = superview.bounds }
        }
    }

    // MARK: - Chip

    final class ChipView: NSView {
        let label = NSTextField(labelWithString: "")

        /// Ice fill / dark-slate text in Dark (inverted cinematic chrome). Reverse in Light.
        /// Not collection orange; not the inspector batch bar.
        private static let ice = NSColor(srgbRed: 244 / 255, green: 247 / 255, blue: 251 / 255, alpha: 1)
        private static let slate = NSColor(srgbRed: 11 / 255, green: 18 / 255, blue: 32 / 255, alpha: 1)

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 11
            layer?.masksToBounds = true
            layer?.borderWidth = 1

            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.drawsBackground = false
            label.isBordered = false
            label.isBezeled = false
            label.isEditable = false
            label.isSelectable = false
            label.setAccessibilityElement(false)
            addSubview(label)
            applyAppearanceColors()
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyAppearanceColors()
        }

        func applyAppearanceColors() {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let fill = dark ? Self.ice : Self.slate
            let text = dark ? Self.slate : Self.ice
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = text.withAlphaComponent(0.28).cgColor
            label.textColor = text
        }

        func setText(_ text: String) {
            label.stringValue = text
            let fitting = label.fittingSize
            let width = min(220, max(36, ceil(fitting.width) + 16))
            setFrameSize(NSSize(width: width, height: 22))
            label.frame = bounds.insetBy(dx: 8, dy: 2)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        var mode: Mode = .grid
        weak var host: HostView?
        var viewModel: LibraryViewModel?

        private var observers: [NSObjectProtocol] = []
        private var mouseMonitor: Any?
        private weak var trackedScrollView: NSScrollView?
        private var chip: ChipView?
        private var liveScrolling = false
        private var knobDragging = false
        private var hideWork: DispatchWorkItem?
        private var lastLabel = ""
        private var isShowing = false
        private var lastClipOriginY: CGFloat?
        private var attachAttempts = 0
        private(set) var debugBoundsEvents = 0
        var debugTrackedScrollView: NSScrollView? { trackedScrollView }
        var debugChipSuperview: NSView? { chip?.superview }

        func tearDown() {
            hideWork?.cancel()
            hideWork = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
            chip?.removeFromSuperview()
            chip = nil
            trackedScrollView = nil
            liveScrolling = false
            knobDragging = false
            isShowing = false
            lastLabel = ""
            lastClipOriginY = nil
            debugBoundsEvents = 0
        }

        func attachIfNeeded(from view: NSView) {
            guard let scrollView = Self.locateScrollView(from: view, mode: mode) else {
                // Inspector clip/collapse can leave the overlay unhosted for a frame.
                guard attachAttempts < 8 else { return }
                attachAttempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(attachAttempts)) { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.attachIfNeeded(from: view)
                }
                return
            }
            attachAttempts = 0
            if trackedScrollView === scrollView, !observers.isEmpty { return }

            tearDown()
            attachAttempts = 0
            trackedScrollView = scrollView
            lastClipOriginY = scrollView.contentView.bounds.origin.y
            let chip = ChipView(frame: .zero)
            chip.alphaValue = 0
            chip.isHidden = true
            // Must live on the wall NSScrollView. The representable host is often 0×0, and
            // SwiftUI clips that wrapper — a chip parented there is invisible (1168).
            if let scroller = scrollView.verticalScroller {
                scrollView.addSubview(chip, positioned: .above, relativeTo: scroller)
            } else {
                scrollView.addSubview(chip)
            }
            self.chip = chip

            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true

            let nc = NotificationCenter.default
            observers.append(nc.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.liveScrolling = true
                    self?.showAndUpdate()
                }
            })
            observers.append(nc.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.showAndUpdate()
                }
            })
            observers.append(nc.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.liveScrolling = false
                    self?.scheduleHide()
                }
            })
            observers.append(nc.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clip,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleBoundsChange()
                }
            })

            // Overlay scroller knob drags sometimes skip live-scroll notifications; hitPart is authoritative.
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                Task { @MainActor in
                    self?.handleMouse(event)
                }
                return event
            }
        }

        private func handleMouse(_ event: NSEvent) {
            guard let host, event.window === host.window else { return }
            if event.type == .leftMouseUp {
                guard knobDragging else { return }
                knobDragging = false
                liveScrolling = false
                scheduleHide()
                return
            }
            guard isKnobTracking() else { return }
            knobDragging = true
            liveScrolling = true
            showAndUpdate()
        }

        private func handleBoundsChange() {
            debugBoundsEvents += 1
            let y = trackedScrollView?.contentView.bounds.origin.y
            if let y, let last = lastClipOriginY, abs(y - last) > 0.5 {
                liveScrolling = true
            }
            if let y { lastClipOriginY = y }
            guard liveScrolling || isShowing || isKnobTracking() else { return }
            if isKnobTracking() { liveScrolling = true }
            showAndUpdate()
            if !liveScrolling {
                scheduleHide()
            }
        }

        private func isKnobTracking() -> Bool {
            guard let scroller = trackedScrollView?.verticalScroller else { return false }
            return scroller.hitPart == .knob
        }

        private func showAndUpdate() {
            guard let host, let scrollView = trackedScrollView, let viewModel else { return }
            let videos = viewModel.filteredVideos
            let fraction = Self.scrollFraction(scrollView: scrollView, mode: mode)
            guard let idx = ScrollIndexHUDLabel.index(fraction: fraction, count: videos.count) else {
                hideImmediately()
                return
            }
            let video = videos[idx]
            let sort = ScrollIndexHUDLabel.sort(
                isRandomOrder: viewModel.isRandomOrder,
                isShowingAlbumOrder: viewModel.isShowingAlbumOrder,
                hasCustomSort: viewModel.customSortFieldId != nil,
                keyPath: viewModel.tableSortOrder.first?.keyPath
            )
            var customDisplay: String?
            if sort == .custom,
               let fieldId = viewModel.customSortFieldId,
               let field = viewModel.customMetadataFieldDefinitions.first(where: { $0.id == fieldId })
            {
                customDisplay = viewModel.listCustomFieldDisplay(for: video, field: field)
            }
            let text = ScrollIndexHUDLabel.text(
                sort: sort,
                video: video,
                index: idx,
                count: videos.count,
                customDisplay: customDisplay
            )

            let chip = self.chip ?? {
                let created = ChipView(frame: .zero)
                scrollView.addSubview(created, positioned: .above, relativeTo: scrollView.verticalScroller)
                self.chip = created
                return created
            }()

            if text != lastLabel {
                lastLabel = text
                chip.setText(text)
            }
            positionChip(chip, in: scrollView, scrollView: scrollView)
            showChip(chip)
        }

        private func positionChip(_ chip: ChipView, in host: NSView, scrollView: NSScrollView) {
            let knob = Self.knobRect(in: host, scrollView: scrollView)
            let gap: CGFloat = 6
            var x = knob.minX - gap - chip.bounds.width
            var y = knob.midY - chip.bounds.height / 2
            let pad: CGFloat = 4
            x = min(max(pad, x), max(pad, host.bounds.maxX - chip.bounds.width - pad))
            y = min(max(pad, y), max(pad, host.bounds.maxY - chip.bounds.height - pad))
            chip.setFrameOrigin(NSPoint(x: x, y: y))
        }

        private func showChip(_ chip: ChipView) {
            hideWork?.cancel()
            hideWork = nil
            isShowing = true
            chip.isHidden = false
            chip.alphaValue = 1
        }

        private func scheduleHide() {
            hideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.fadeOut()
                }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        private func fadeOut() {
            guard !liveScrolling, !isKnobTracking() else {
                scheduleHide()
                return
            }
            guard let chip, isShowing else { return }
            isShowing = false
            lastLabel = ""
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if reduceMotion {
                chip.alphaValue = 0
                chip.isHidden = true
                return
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                chip.animator().alphaValue = 0
            } completionHandler: { [weak self, weak chip] in
                guard let self, let chip else { return }
                if !self.isShowing {
                    chip.isHidden = true
                }
            }
        }

        private func hideImmediately() {
            hideWork?.cancel()
            hideWork = nil
            isShowing = false
            lastLabel = ""
            chip?.alphaValue = 0
            chip?.isHidden = true
        }

        // MARK: Geometry

        static func scrollFraction(scrollView: NSScrollView, mode: Mode) -> Double {
            if let scroller = scrollView.verticalScroller {
                let value = Double(scroller.floatValue)
                if value.isFinite { return min(1, max(0, value)) }
            }
            let clip = scrollView.contentView
            let insets = scrollView.contentInsets
            let clipH = clip.bounds.height
            let docHeight = scrollView.documentView?.bounds.height ?? clipH
            let minY: CGFloat = (mode == .list) ? 0 : -insets.top
            let maxY = max(minY, docHeight + insets.bottom - clipH)
            let span = maxY - minY
            guard span > 0.5 else { return 0 }
            return min(1, max(0, Double((clip.bounds.origin.y - minY) / span)))
        }

        static func knobRect(in host: NSView, scrollView: NSScrollView) -> NSRect {
            if let scroller = scrollView.verticalScroller, scroller.superview != nil {
                let knob = scroller.rect(for: .knob)
                if knob.height > 1, knob.width > 1 {
                    return host.convert(knob, from: scroller)
                }
                let slot = host.convert(scroller.bounds, from: scroller)
                let proportion = max(CGFloat(scroller.knobProportion), 0.08)
                let knobH = max(24, slot.height * proportion)
                let travel = max(0, slot.height - knobH)
                let y = slot.minY + CGFloat(scroller.floatValue) * travel
                return NSRect(x: slot.minX, y: y, width: max(slot.width, 1), height: knobH)
            }
            let fraction = CGFloat(scrollView.verticalScroller?.floatValue ?? 0)
            let track = host.bounds
            let knobH: CGFloat = 24
            let travel = max(0, track.height - knobH)
            return NSRect(
                x: track.maxX - 14,
                y: track.minY + fraction * travel,
                width: 14,
                height: knobH
            )
        }

        static func locateScrollView(from view: NSView, mode: Mode) -> NSScrollView? {
            switch mode {
            case .grid:
                // Overlay is on the wall ScrollView. Nearest ancestor/sibling is the wall —
                // never DFS the Inspector pane (cousin under NSSplitView).
                if let sv = enclosingScrollView(from: view) { return sv }
                if let sv = siblingScrollView(from: view) { return sv }
                if let pane = browserPane(from: view) {
                    return largestVerticalScrollView(in: pane)
                }
                return nil
            case .list:
                if let pane = browserPane(from: view),
                   let table = ScrollCommandHandlerListTable.tableWithMostRows(in: pane)
                {
                    return table.enclosingScrollView
                }
                guard let content = view.window?.contentView else { return nil }
                return ScrollCommandHandlerListTable.tableWithMostRows(in: content)?.enclosingScrollView
            }
        }

        private static func enclosingScrollView(from view: NSView) -> NSScrollView? {
            var current: NSView? = view.superview
            while let v = current {
                if let sv = v as? NSScrollView { return sv }
                if v is NSSplitView { break }
                current = v.superview
            }
            return nil
        }

        private static func siblingScrollView(from view: NSView) -> NSScrollView? {
            var current: NSView? = view
            while let v = current {
                if v is NSSplitView { break }
                if let parent = v.superview {
                    if parent is NSSplitView { break }
                    for sub in parent.subviews where sub !== v {
                        if let sv = firstVerticalScrollView(in: sub) { return sv }
                    }
                }
                current = v.superview
            }
            return nil
        }

        private static func firstVerticalScrollView(in root: NSView) -> NSScrollView? {
            if let sv = root as? NSScrollView { return sv }
            for sub in root.subviews {
                if let found = firstVerticalScrollView(in: sub) { return found }
            }
            return nil
        }

        private static func largestVerticalScrollView(in root: NSView) -> NSScrollView? {
            var best: NSScrollView?
            var bestScore: CGFloat = 0
            func search(_ v: NSView) {
                if let sv = v as? NSScrollView {
                    let clip = sv.contentView.bounds
                    if clip.width > 40, clip.height > 40 {
                        let docH = sv.documentView?.bounds.height ?? clip.height
                        let score = max(docH, 1) * clip.width
                        if score > bestScore {
                            best = sv
                            bestScore = score
                        }
                    }
                }
                for sub in v.subviews { search(sub) }
            }
            search(root)
            return best
        }

        /// Left split pane (browser). Stops at `NSSplitView` so Inspector scrollers are ignored.
        private static func browserPane(from view: NSView) -> NSView? {
            var current: NSView? = view
            var last = view
            while let v = current {
                if v is NSSplitView { return last }
                last = v
                current = v.superview
            }
            return view.superview
        }
    }
}
