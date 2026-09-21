import AppKit
import SwiftUI

/// Drives the `NSScrollView` backing the grid or list in response to `LibraryViewModel.scrollCommand`
/// (top / bottom / page up / page down). Operates directly on the clip view so it works identically for
/// the SwiftUI `ScrollView` (grid) and the `Table`'s scroll view (list), independent of selection — this
/// keeps the existing fast scrollbar "rip" untouched while adding explicit jump controls.
struct ScrollCommandHandler: NSViewRepresentable {
    enum Mode { case grid, list }
    let command: LibraryViewModel.ScrollCommand?
    let mode: Mode

    final class Coordinator {
        var lastToken: Int = 0
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        // Adopt the current token so a freshly mounted handler (e.g. after a grid/list switch) does not
        // replay the most recent command on appear.
        c.lastToken = command?.token ?? 0
        return c
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let command, command.token != context.coordinator.lastToken else { return }
        context.coordinator.lastToken = command.token
        let kind = command.kind
        let mode = self.mode
        // Defer so any pending layout (version bump, column changes) settles before we read viewport metrics.
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, let scrollView = Self.locateScrollView(from: nsView, mode: mode) else { return }
            Self.apply(kind, to: scrollView, mode: mode)
        }
    }

    // MARK: - Scrolling

    static func apply(_ kind: LibraryViewModel.ScrollCommand.Kind, to scrollView: NSScrollView, mode: Mode) {
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        let clipH = clip.bounds.height
        let docHeight = scrollView.documentView?.bounds.height ?? clipH

        // Top scroll position accounting for chrome vs. table headers.
        // Grid: use negative inset so the content area can scroll under the titlebar area.
        // List: we compute a dynamic "minY" for most operations (see scrollListToAbsoluteTop for .top).
        //       The column header is a separate headerView; simply targeting y=0 or -insets.top can leave
        //       the first row partially obscured if the clip view overlaps the header frame.
        let minY: CGFloat = (mode == .list) ? 0 : -insets.top

        let maxY = max(minY, docHeight + insets.bottom - clipH)
        let visibleH = max(0, clipH - insets.top - insets.bottom)
        // Overlap ~one row's worth so content at the seam stays visible across a page jump.
        let page = visibleH * 0.9
        var y = clip.bounds.origin.y

        switch kind {
        case .top:
            if mode == .list {
                Self.scrollListToAbsoluteTop(scrollView)
                // Re-apply shortly after; SwiftUI Table / NSTableView may perform additional layout or
                // selection-visibility scrolls on the next tick(s) that would otherwise leave the first row
                // partially under the column header.
                DispatchQueue.main.async { [weak scrollView] in
                    guard let sv = scrollView else { return }
                    Self.scrollListToAbsoluteTop(sv)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak scrollView] in
                    guard let sv = scrollView else { return }
                    Self.scrollListToAbsoluteTop(sv)
                }
                return
            }
            y = minY
        case .bottom: y = maxY
        case .pageUp: y = max(minY, y - page)
        case .pageDown: y = min(maxY, y + page)
        case .toRow(let index, let total):
            // Reveal the target row with minimal scroll. Skip when it is already fully visible
            // (arrow-key navigation within or across on-screen rows should not re-center the grid).
            guard total > 0 else { break }
            let rowHeight = docHeight / CGFloat(total)
            let rowTop = CGFloat(index) * rowHeight
            let rowBottom = rowTop + rowHeight
            let padding: CGFloat = 8
            let visibleTop = clip.bounds.origin.y
            let visibleBottom = visibleTop + visibleH
            if rowTop >= visibleTop + padding, rowBottom <= visibleBottom - padding {
                return
            }
            if rowTop < visibleTop + padding {
                y = max(minY, rowTop - padding)
            } else {
                y = min(maxY, rowBottom - visibleH + padding)
            }
            if abs(y - visibleTop) < 0.5 {
                return
            }
        case .pinRow(let index, let total, let offsetFromVisibleTop):
            // Put the row’s mid back at the same distance from the visible top as before Inspector toggle.
            if mode == .list {
                Self.pinListRow(index, offsetFromVisibleTop: offsetFromVisibleTop, scrollView: scrollView)
                return
            }
            guard total > 0 else { break }
            let rowHeight = docHeight / CGFloat(total)
            let rowMid = CGFloat(index) * rowHeight + rowHeight * 0.5
            y = min(maxY, max(minY, rowMid - offsetFromVisibleTop))
            if abs(y - clip.bounds.origin.y) < 0.5 {
                return
            }
        case .retile:
            // Keep the current offset; the nudge-and-restore below forces a re-tile in place.
            break
        }

        let target = NSPoint(x: clip.bounds.origin.x, y: y)
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)

        // A `.toRow` re-anchor (detail-pane playback exit) or `.retile` (fullscreen exit) often lands on the
        // offset the clip already held, so no bounds-changed fires — and an `NSScrollView` that was frozen
        // or occluded by the fullscreen player never re-tiles, leaving the `LazyVGrid` showing blank cells
        // until the user scrolls. Force a 1pt nudge-and-restore across two runloop ticks so each step posts
        // a bounds-changed notification and the grid re-instantiates its visible cells. Net visible position
        // is unchanged (the bump is sub-row, so the re-tiled region matches the target).
        // Do **not** retile on `.pinRow` (Inspector ⌘I): that restart every visible card `.task` and
        // re-decodes Storyboard collages already in memory.
        switch kind {
        case .toRow, .retile:
            let bump = NSPoint(x: target.x, y: target.y > minY ? target.y - 1 : target.y + 1)
            DispatchQueue.main.async { [weak scrollView, weak clip] in
                guard let scrollView, let clip else { return }
                clip.scroll(to: bump)
                scrollView.reflectScrolledClipView(clip)
                DispatchQueue.main.async { [weak scrollView, weak clip] in
                    guard let scrollView, let clip else { return }
                    clip.scroll(to: target)
                    scrollView.reflectScrolledClipView(clip)
                }
            }
        default:
            break
        }
    }

    /// List: pin row midY to the same offset from the visible top (table document coordinates).
    private static func pinListRow(_ row: Int, offsetFromVisibleTop: CGFloat, scrollView: NSScrollView) {
        scrollView.layoutSubtreeIfNeeded()
        guard let table = findTableView(under: scrollView),
              row >= 0, row < table.numberOfRows
        else { return }
        table.layoutSubtreeIfNeeded()
        let rowRect = table.rect(ofRow: row)
        guard !rowRect.isEmpty else { return }
        let targetY = rowRect.midY - offsetFromVisibleTop
        table.scroll(NSPoint(x: table.visibleRect.minX, y: targetY))
    }

    // MARK: - List top (precise under-header pinning)

    /// Scrolls the list (NSTableView-backed) so that row 0 is positioned with its top edge exactly
    /// visually flush under the column header (no gap, nothing hidden). We compute the required clip
    /// origin by mapping the header's bottom edge into the clip view's local coordinate space and
    /// solving for the document Y that should appear right at that "under-header" line.
    private static func scrollListToAbsoluteTop(_ scrollView: NSScrollView) {
        scrollView.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        clip.layoutSubtreeIfNeeded()

        guard let table = Self.findTableView(under: scrollView) else {
            let target = NSPoint(x: clip.bounds.origin.x, y: 0)
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
            return
        }

        table.layoutSubtreeIfNeeded()
        if table.numberOfRows > 0 {
            table.scrollRowToVisible(0)
        }
        table.layoutSubtreeIfNeeded()

        let rowRect = (table.numberOfRows > 0) ? table.rect(ofRow: 0) : .zero
        guard !rowRect.isEmpty else {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: 0))
            scrollView.reflectScrolledClipView(clip)
            return
        }

        // Base target aligns row top to the top of the clip (document y = row top at clip local y=0).
        var targetY = rowRect.minY

        if let tableHeader = table.headerView {
            tableHeader.layoutSubtreeIfNeeded()

            // Convert the *bottom edge* of the header into the clip view's local coords.
            // The Y value we get is the local point in the clip at which the header visually ends.
            let headerBottomLocalInClip = tableHeader.convert(
                NSPoint(x: 0, y: tableHeader.bounds.maxY),
                to: clip
            ).y

            // Document point shown at local clip Y = L is: clip.bounds.origin.y + L
            // We want rowRect.minY to be the document point shown at local Y = headerBottomLocalInClip.
            // Therefore: clip.bounds.origin.y + headerBottomLocalInClip == rowRect.minY
            targetY = rowRect.minY - headerBottomLocalInClip
        }

        let target = NSPoint(x: clip.bounds.origin.x, y: targetY)
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)

        // Immediate correction: a layout or selection-visibility pass can nudge the clip by a few points.
        // Re-measure using the same header-to-clip mapping and correct if we're off by > 0.25 pt.
        Self.correctListFirstRowUnderHeader(table: table, clip: clip, scrollView: scrollView)
    }

    /// After a scroll, re-compute the ideal clip origin using header-bottom → clip local mapping and
    /// apply a micro-correction if the actual position drifted. This catches the last 1-4 px that
    /// SwiftUI/AppKit sometimes reapplies right after we set the origin.
    private static func correctListFirstRowUnderHeader(table: NSTableView, clip: NSClipView, scrollView: NSScrollView) {
        table.layoutSubtreeIfNeeded()
        clip.layoutSubtreeIfNeeded()
        guard table.numberOfRows > 0 else { return }

        let rowTopDoc = table.rect(ofRow: 0).minY
        var desiredY = rowTopDoc

        if let hdr = table.headerView {
            hdr.layoutSubtreeIfNeeded()
            let hb = hdr.convert(NSPoint(x: 0, y: hdr.bounds.maxY), to: clip).y
            desiredY = rowTopDoc - hb
        }

        let currentY = clip.bounds.origin.y
        if abs(currentY - desiredY) > 0.25 {
            let corrected = NSPoint(x: clip.bounds.origin.x, y: desiredY)
            clip.scroll(to: corrected)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private static func findTableView(under view: NSView) -> NSTableView? {
        if let tv = view as? NSTableView { return tv }
        for sub in view.subviews {
            if let found = findTableView(under: sub) { return found }
        }
        return nil
    }

    // MARK: - Locating the scroll view

    private static func locateScrollView(from view: NSView, mode: Mode) -> NSScrollView? {
        switch mode {
        case .grid:
            // The handler sits inside the grid's scroll document; walk up to the enclosing scroll view.
            var current: NSView? = view.superview
            while let v = current {
                if let sv = v as? NSScrollView { return sv }
                current = v.superview
            }
            return nil
        case .list:
            // The handler is a sibling of the Table; find the table with the most rows (the video list,
            // not the sidebar) and use its enclosing scroll view.
            guard let content = view.window?.contentView else { return nil }
            return tableWithMostRows(in: content)?.enclosingScrollView
        }
    }

    private static func tableWithMostRows(in view: NSView) -> NSTableView? {
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
}
