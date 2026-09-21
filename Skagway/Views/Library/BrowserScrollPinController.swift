import AppKit
import SwiftUI

/// Keeps a live viewport pin for the focused clip and restores it after Inspector show/hide so the
/// clip stays in the **same on-screen slot** when the browser width (and grid columns) change.
struct BrowserScrollPinController: NSViewRepresentable {
    enum Mode { case grid, list }

    var store: BrowserScrollPinStore
    var restoreToken: Int
    var pendingRestore: BrowserScrollPinStore.Pin?
    /// Called after a restore is scheduled so the view model can clear `pendingBrowserScrollPinRestore`.
    var onRestoreConsumed: () -> Void
    var mode: Mode
    var anchorVideoId: String?
    var anchorIndex: Int?
    var columnCount: Int
    var videoCount: Int

    final class Coordinator {
        var lastRestoreToken: Int = 0
        var boundsObserver: NSObjectProtocol?
        var trackedScrollView: NSScrollView?
        var mode: Mode = .grid
        var store: BrowserScrollPinStore?
        var anchorVideoId: String?
        var anchorIndex: Int?
        var columnCount: Int = 1
        var videoCount: Int = 0

        func tearDownObserver() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }
            trackedScrollView = nil
        }

        func capturePin() {
            guard let store,
                  let videoId = anchorVideoId,
                  let index = anchorIndex,
                  let scrollView = trackedScrollView
            else {
                store?.pin = nil
                return
            }
            scrollView.layoutSubtreeIfNeeded()
            let clip = scrollView.contentView
            clip.layoutSubtreeIfNeeded()

            switch mode {
            case .list:
                guard let table = ScrollCommandHandlerListTable.find(under: scrollView),
                      index >= 0, index < table.numberOfRows
                else {
                    store.pin = nil
                    return
                }
                table.layoutSubtreeIfNeeded()
                let rowRect = table.rect(ofRow: index)
                guard !rowRect.isEmpty else {
                    store.pin = nil
                    return
                }
                let offset = rowRect.midY - table.visibleRect.minY
                store.pin = .init(videoId: videoId, offsetFromVisibleTop: offset)
            case .grid:
                let cols = max(1, columnCount)
                let totalRows = max(1, (videoCount + cols - 1) / cols)
                let rowIndex = index / cols
                let docHeight = scrollView.documentView?.bounds.height ?? clip.bounds.height
                let insets = scrollView.contentInsets
                let visibleH = max(0, clip.bounds.height - insets.top - insets.bottom)
                guard visibleH > 0, docHeight > 0 else {
                    store.pin = nil
                    return
                }
                let rowHeight = docHeight / CGFloat(totalRows)
                let rowMid = CGFloat(rowIndex) * rowHeight + rowHeight * 0.5
                // Match ScrollCommandHandler grid space (origin can be negative from top inset).
                let visibleTop = clip.bounds.origin.y
                let offset = rowMid - visibleTop
                store.pin = .init(videoId: videoId, offsetFromVisibleTop: offset)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDownObserver()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.store = store
        coordinator.mode = mode
        coordinator.anchorVideoId = anchorVideoId
        coordinator.anchorIndex = anchorIndex
        coordinator.columnCount = max(1, columnCount)
        coordinator.videoCount = max(0, videoCount)

        // Defer locate — the representable mounts before the ScrollView’s NSScrollView exists.
        DispatchQueue.main.async { [weak nsView, weak coordinator] in
            guard let nsView, let coordinator else { return }
            Self.attachIfNeeded(from: nsView, coordinator: coordinator)
            coordinator.capturePin()
        }

        guard restoreToken != coordinator.lastRestoreToken else { return }
        coordinator.lastRestoreToken = restoreToken
        guard let pin = pendingRestore else { return }
        onRestoreConsumed()

        // Split width settles on the next layout pass. One follow-up is enough — repeating
        // pin restores used to re-tile the wall and restart every visible card `.task`.
        let delays: [TimeInterval] = [0.04, 0.12]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak nsView, weak coordinator] in
                guard let nsView, let coordinator else { return }
                Self.attachIfNeeded(from: nsView, coordinator: coordinator)
                Self.applyRestore(pin: pin, from: nsView, coordinator: coordinator)
                coordinator.capturePin()
            }
        }
    }

    private static func attachIfNeeded(from view: NSView, coordinator: Coordinator) {
        let mode = coordinator.mode
        guard let scrollView = locateScrollView(from: view, mode: mode) else { return }
        if coordinator.trackedScrollView === scrollView, coordinator.boundsObserver != nil { return }

        coordinator.tearDownObserver()
        coordinator.trackedScrollView = scrollView
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak coordinator] _ in
            coordinator?.capturePin()
        }
    }

    private static func applyRestore(
        pin: BrowserScrollPinStore.Pin,
        from view: NSView,
        coordinator: Coordinator
    ) {
        guard let scrollView = coordinator.trackedScrollView ?? locateScrollView(from: view, mode: coordinator.mode)
        else { return }
        guard pin.videoId == coordinator.anchorVideoId,
              let index = coordinator.anchorIndex
        else { return }

        let cols = max(1, coordinator.columnCount)
        let totalRows: Int
        let rowIndex: Int
        switch coordinator.mode {
        case .list:
            totalRows = max(1, coordinator.videoCount)
            rowIndex = index
        case .grid:
            totalRows = max(1, (coordinator.videoCount + cols - 1) / cols)
            rowIndex = index / cols
        }

        // Drive through the same path as ⌘J / Home so list vs grid geometry stays consistent.
        // Use a one-shot command via direct apply (avoid fighting an unrelated scrollCommand token).
        ScrollCommandHandler.applyPin(
            mode: coordinator.mode == .grid ? .grid : .list,
            rowIndex: rowIndex,
            totalRows: totalRows,
            offsetFromVisibleTop: pin.offsetFromVisibleTop,
            scrollView: scrollView
        )
    }

    private static func locateScrollView(from view: NSView, mode: Mode) -> NSScrollView? {
        switch mode {
        case .grid:
            var current: NSView? = view.superview
            while let v = current {
                if let sv = v as? NSScrollView { return sv }
                current = v.superview
            }
            return nil
        case .list:
            guard let content = view.window?.contentView else { return nil }
            return ScrollCommandHandlerListTable.tableWithMostRows(in: content)?.enclosingScrollView
        }
    }
}

/// Shared table lookup for pin + scroll handlers (keeps list targeting consistent).
enum ScrollCommandHandlerListTable {
    static func find(under scrollView: NSScrollView) -> NSTableView? {
        findTableView(under: scrollView)
    }

    static func tableWithMostRows(in view: NSView) -> NSTableView? {
        var best: NSTableView?
        var bestRows = -1
        func search(_ v: NSView) {
            if let tv = v as? NSTableView, tv.numberOfRows > bestRows {
                best = tv
                bestRows = tv.numberOfRows
            }
            for sub in v.subviews { search(sub) }
        }
        search(view)
        return best
    }

    private static func findTableView(under view: NSView) -> NSTableView? {
        if let tv = view as? NSTableView { return tv }
        for sub in view.subviews {
            if let found = findTableView(under: sub) { return found }
        }
        return nil
    }
}

extension ScrollCommandHandler {
    /// Apply a viewport pin without going through `scrollCommand` (Inspector toggle restore).
    static func applyPin(
        mode: Mode,
        rowIndex: Int,
        totalRows: Int,
        offsetFromVisibleTop: CGFloat,
        scrollView: NSScrollView
    ) {
        apply(
            .pinRow(index: rowIndex, total: totalRows, offsetFromVisibleTop: offsetFromVisibleTop),
            to: scrollView,
            mode: mode
        )
    }
}
