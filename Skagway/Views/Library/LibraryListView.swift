import SwiftUI
import AppKit
import AVFoundation

struct TableScrollHelper: NSViewRepresentable {
    let scrollToRow: Int?

    final class Coordinator: NSObject {
        /// Bumped whenever a new scroll is scheduled so stale delayed work (e.g. after deletes / table rebuild)
        /// cannot run — avoids EXC_BAD_ACCESS in SwiftUI’s AppKitOutlineTableCoordinator during scroll/layout races.
        var generation: UInt64 = 0
        var pending: [DispatchWorkItem] = []

        func cancelPending() {
            pending.forEach { $0.cancel() }
            pending.removeAll()
            generation &+= 1
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        return view
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.cancelPending()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.cancelPending()
        guard let row = scrollToRow, row >= 0 else { return }
        guard let window = nsView.window, window.contentView != nil else { return }

        let gen = context.coordinator.generation
        let coord = context.coordinator

        // Fewer, cancellable retries — the old 5× fire-and-forget pattern could still scroll after the
        // filtered list shrank, fighting SwiftUI Table updates and crashing in objc_retain (see crash .ips).
        let delays: [TimeInterval] = [0.06, 0.22, 0.45]
        for delay in delays {
            let work = DispatchWorkItem { [weak window, weak coord] in
                guard let window, let coord else { return }
                guard gen == coord.generation else { return }
                guard let content = window.contentView,
                      let tableView = Self.findTableView(in: content)
                else { return }
                Self.scrollRowSafely(row, in: tableView)
            }
            coord.pending.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        let focusWork = DispatchWorkItem { [weak window, weak coord] in
            guard let window, let coord else { return }
            guard gen == coord.generation else { return }
            guard let content = window.contentView,
                  let tableView = Self.findTableView(in: content),
                  row < tableView.numberOfRows
            else { return }
            window.makeFirstResponder(tableView)
        }
        coord.pending.append(focusWork)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: focusWork)
    }

    /// Scroll so the selected row sits near the **vertical center** of the scroll viewport.
    /// `scrollRowToVisible` only minimizes scroll and often pins the row to an edge.
    private static func scrollRowSafely(_ row: Int, in tableView: NSTableView) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        tableView.layoutSubtreeIfNeeded()

        guard let scrollView = tableView.enclosingScrollView else {
            tableView.scrollRowToVisible(row)
            return
        }
        scrollView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        clipView.layoutSubtreeIfNeeded()

        let rowRect = tableView.rect(ofRow: row)
        guard !rowRect.isEmpty else {
            tableView.scrollRowToVisible(row)
            return
        }

        let viewportH = clipView.bounds.height
        guard viewportH > 0 else {
            tableView.scrollRowToVisible(row)
            return
        }

        // Rectangle in table coordinates spanning one viewport tall, vertically centered on the row.
        // scrollToVisible on the table scrolls the enclosing NSScrollView to place this rect appropriately.
        let tableExtent = max(tableView.bounds.height, rowRect.maxY)
        let maxOriginY = max(0, tableExtent - viewportH)
        let rowMid = rowRect.midY
        let desiredOriginY = rowMid - viewportH / 2
        let originY = min(maxOriginY, max(0, desiredOriginY.rounded()))

        let targetRect = NSRect(
            x: tableView.bounds.minX,
            y: originY,
            width: tableView.bounds.width,
            height: viewportH
        )
        tableView.scrollToVisible(targetRect)

        tableView.layoutSubtreeIfNeeded()
        guard tableView.rect(ofRow: row).intersects(tableView.visibleRect) else {
            tableView.scrollRowToVisible(row)
            return
        }
    }

    /// Prefer the table with the most rows (video list) over sidebar/collections. Starts at -1 (not
    /// 0) so a table that hasn't finished populating rows yet (e.g. right after cold launch) is still
    /// found rather than silently skipped.
    static func findTableView(in view: NSView) -> NSTableView? {
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

/// Per-row hover for List Review collect circles — avoids a single shared id racing when
/// pointer moves between Table rows (one row's `onHover(false)` must not clear another's).
@Observable
private final class ListRowReviewState {
    var isRowHovering: Bool = false
    var isBadgeHovering: Bool = false

    var showsCollectBadge: Bool { isRowHovering || isBadgeHovering }
}

private final class ListRowReviewStore {
    private var states: [String: ListRowReviewState] = [:]

    func state(for id: String) -> ListRowReviewState {
        if let s = states[id] { return s }
        let s = ListRowReviewState()
        states[id] = s
        return s
    }
}

/// Catches mouse-down before transient popover dismissal or Table routing eats the click.
private struct ListMouseDownHandler: NSViewRepresentable {
    let onPlainMouseDown: () -> Void
    var onModifierMouseDown: ((NSEvent.ModifierFlags) -> Void)? = nil
    var ignoreModifiers: Bool = false

    final class HandlerView: NSView {
        var onPlainMouseDown: (() -> Void)?
        var onModifierMouseDown: ((NSEvent.ModifierFlags) -> Void)?
        var ignoreModifiers = false

        override func mouseDown(with event: NSEvent) {
            if ignoreModifiers || !ListSelectionModifiers.usesExtendedSelection(event.modifierFlags) {
                onPlainMouseDown?()
                super.mouseDown(with: event)
                return
            }
            onModifierMouseDown?(event.modifierFlags)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> HandlerView {
        let view = HandlerView()
        view.onPlainMouseDown = onPlainMouseDown
        view.onModifierMouseDown = onModifierMouseDown
        view.ignoreModifiers = ignoreModifiers
        return view
    }

    func updateNSView(_ nsView: HandlerView, context: Context) {
        nsView.onPlainMouseDown = onPlainMouseDown
        nsView.onModifierMouseDown = onModifierMouseDown
        nsView.ignoreModifiers = ignoreModifiers
    }
}

/// Enlarged hover preview in a child panel that ignores mouse events so row clicks (including
/// ⌘/⇧) land on the first press instead of being eaten by popover dismiss.
private struct ListHoverPreviewFloater: NSViewRepresentable {
    var isPresented: Bool
    let video: Video
    let thumbnailService: ThumbnailService
    var livePreviewEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FloaterAnchorView {
        let view = FloaterAnchorView()
        view.onFrameChange = { [weak coordinator = context.coordinator] in
            coordinator?.repositionIfNeeded()
        }
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: FloaterAnchorView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.sync(
            isPresented: isPresented,
            video: video,
            thumbnailService: thumbnailService,
            livePreviewEnabled: livePreviewEnabled
        )
    }

    static func dismantleNSView(_ nsView: FloaterAnchorView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class FloaterAnchorView: NSView {
        var onFrameChange: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            onFrameChange?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onFrameChange?()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            onFrameChange?()
        }
    }

    @MainActor
    final class Coordinator {
        weak var anchorView: FloaterAnchorView?
        private var panel: NSPanel?
        private var hostingView: NSHostingView<ListHoverPreviewPanel>?
        private var video: Video?
        private var thumbnailService: ThumbnailService?
        private var livePreviewEnabled = false
        private var isPresented = false

        func sync(
            isPresented: Bool,
            video: Video,
            thumbnailService: ThumbnailService,
            livePreviewEnabled: Bool
        ) {
            self.isPresented = isPresented
            self.video = video
            self.thumbnailService = thumbnailService
            self.livePreviewEnabled = livePreviewEnabled
            if isPresented {
                show()
            } else {
                hide()
            }
        }

        func repositionIfNeeded() {
            guard isPresented else { return }
            reposition()
        }

        private func show() {
            guard let video, let thumbnailService else { return }
            let panel = ensurePanel()
            let panelSize = NSSize(width: 224, height: 144)
            let content = ListHoverPreviewPanel(
                video: video,
                thumbnailService: thumbnailService,
                livePreviewEnabled: livePreviewEnabled
            )
            if let hostingView {
                hostingView.rootView = content
                hostingView.frame = NSRect(origin: .zero, size: panelSize)
            } else {
                let hosting = NSHostingView(rootView: content)
                hosting.frame = NSRect(origin: .zero, size: panelSize)
                panel.contentView = hosting
                hostingView = hosting
            }
            panel.setContentSize(panelSize)
            reposition()
            panel.orderFront(nil)
        }

        private func reposition() {
            guard let panel, let anchorView, let window = anchorView.window else { return }
            if panel.parent == nil {
                window.addChildWindow(panel, ordered: .above)
            }
            let panelSize = panel.frame.size
            guard panelSize.width > 0, panelSize.height > 0 else { return }

            // `convert(_:to: nil)` is window space; child panels need screen space.
            let anchorInWindow = anchorView.convert(anchorView.bounds, to: nil)
            guard anchorInWindow.width > 0, anchorInWindow.height > 0 else { return }
            let anchorOnScreen = window.convertToScreen(anchorInWindow)

            let origin = NSPoint(
                x: anchorOnScreen.maxX + 8,
                y: anchorOnScreen.midY - panelSize.height * 0.5
            )
            panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        }

        private func ensurePanel() -> NSPanel {
            if let panel { return panel }
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 224, height: 144),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            self.panel = panel
            return panel
        }

        private func hide() {
            panel?.orderOut(nil)
        }

        func teardown() {
            if let panel, let parent = panel.parent {
                parent.removeChildWindow(panel)
            }
            panel?.close()
            panel = nil
            hostingView = nil
        }
    }
}

/// Enlarged List hover panel — static poster, optionally with Grid-style live scrub on top.
private struct ListHoverPreviewPanel: View {
    let video: Video
    let thumbnailService: ThumbnailService
    var livePreviewEnabled: Bool

    @State private var previewPlayer: AVPlayer?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        AsyncThumbnailView(
            filePath: video.filePath,
            thumbnailService: thumbnailService,
            cacheVersion: video.thumbnailPath
        )
        .overlay {
            if let previewPlayer {
                HoverPreviewPlayerView(player: previewPlayer)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: 224, height: 144)
        .appMediaFrame(cornerRadius: AppRadius.md)
        .onAppear {
            if livePreviewEnabled { startLivePreview() }
        }
        .onDisappear {
            stopLivePreview()
        }
        .onChange(of: livePreviewEnabled) { _, enabled in
            if enabled { startLivePreview() } else { stopLivePreview() }
        }
    }

    private func startLivePreview() {
        guard livePreviewEnabled else { return }
        previewTask?.cancel()
        previewTask = nil
        if let previewPlayer {
            previewPlayer.pause()
            previewPlayer.replaceCurrentItem(with: nil)
        }
        previewPlayer = nil

        let token = HoverPreviewExclusive.claim()
        previewTask = Task { @MainActor in
            await HoverPreviewPlayback.run(
                url: video.url,
                knownDuration: video.duration,
                token: token,
                assignPlayer: { player in
                    self.previewPlayer = player
                }
            )
        }
    }

    private func stopLivePreview() {
        previewTask?.cancel()
        previewTask = nil
        if let previewPlayer {
            previewPlayer.pause()
            previewPlayer.replaceCurrentItem(with: nil)
        }
        previewPlayer = nil
    }
}

/// Small List title thumbnail; hover opens the enlarged preview popover.
private struct ListRowHoverThumbnail: View {
    let video: Video
    let thumbnailService: ThumbnailService
    var hoverPreviewEnabled: Bool
    var isMoving: Bool
    let onSelect: () -> Void
    let onModifierSelect: (NSEvent.ModifierFlags) -> Void

    @State private var isThumbnailHovered = false

    var body: some View {
        AsyncThumbnailView(
            filePath: video.filePath,
            thumbnailService: thumbnailService,
            cacheVersion: video.thumbnailPath
        )
        .frame(width: 56, height: 36)
        .appMediaFrame(cornerRadius: AppRadius.sm)
        .overlay {
            ListMouseDownHandler(onPlainMouseDown: onSelect, onModifierMouseDown: onModifierSelect)
        }
        .overlay {
            ListHoverPreviewFloater(
                isPresented: isThumbnailHovered,
                video: video,
                thumbnailService: thumbnailService,
                livePreviewEnabled: hoverPreviewEnabled && !isMoving
            )
            .frame(width: 56, height: 36)
            .allowsHitTesting(false)
        }
        .onHover { isThumbnailHovered = $0 }
    }
}

private struct ListCollectedSetBadge: View {
    let isCollected: Bool
    let reviewState: ListRowReviewState
    let onCollectClick: (NSEvent.ModifierFlags) -> Void

    var body: some View {
        if isCollected || reviewState.showsCollectBadge {
            Image(systemName: isCollected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, isCollected ? Color.appAccent : Color.white.opacity(0.55))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .padding(2)
                .contentShape(Circle())
                .overlay {
                    ListMouseDownHandler(
                        onPlainMouseDown: { onCollectClick([]) },
                        onModifierMouseDown: onCollectClick
                    )
                }
                .help(isCollected ? "Remove from collected set" : "Add to collected set")
                .zIndex(1)
                .onHover { reviewState.isBadgeHovering = $0 }
        }
    }
}

struct LibraryListView: View {
    @Bindable var viewModel: LibraryViewModel
    let thumbnailService: ThumbnailService
    @Binding var scrollPositionRow: Int?

    @State private var filmstripSession: FilmstripModifySession?
    @FocusState private var isRenameFocused: Bool
    @State private var scrollToRow: Int?
    @State private var albumReorderTargetId: String?
    @State private var lastClickedId: String?
    @State private var reviewRowStore = ListRowReviewStore()

    private var tableSelectionBinding: Binding<Set<String>> {
        Binding(
            get: {
                if viewModel.isReviewMode {
                    if let id = viewModel.focusedVideoId { return [id] }
                    return []
                }
                return viewModel.selectedVideoIds
            },
            set: { applyTableSelection($0) }
        )
    }

    var body: some View {
        listTableWithContextMenu
        .tint(Color.appAccent)
        .id("\(viewModel.filteredVideosVersion)-\(viewModel.listColumnConfigurationSignature)")
        .background(TableScrollHelper(scrollToRow: scrollToRow))
        .background(ScrollCommandHandler(command: viewModel.scrollCommand, mode: .list))
        .onAppear {
            if viewModel.scrollToSelectedOnViewSwitch {
                viewModel.scrollToSelectedOnViewSwitch = false
                scrollToSelectedRow(delay: 0.3)
            } else if let row = scrollPositionRow, row >= 0, row < viewModel.filteredVideos.count {
                scrollToRow(withId: viewModel.filteredVideos[row].id, delay: 0.2)
            } else {
                // Cold launch (or any other appearance) with no switch flag and no persisted scroll
                // row — still claim first responder so the Table's native ⌘A/arrow keys work without
                // requiring the user to click a row first.
                focusTable(delay: 0.2)
            }
        }
        .onChange(of: viewModel.scrollToVideoId, initial: true) { _, targetId in
            guard let id = targetId else { return }
            viewModel.scrollToVideoId = nil
            // Table may not have laid out yet after version bump; retry with increasing delays
            for delay in [0.05, 0.15, 0.35] as [Double] {
                scrollToRow(withId: id, delay: delay)
            }
        }
        .onChange(of: viewModel.focusedVideoId) { _, id in
            if let id { lastClickedId = id }
        }
        .sheet(item: $filmstripSession) { session in
            FilmstripConfigView(
                videos: session.videos,
                thumbnailService: thumbnailService,
                defaultRows: viewModel.defaultFilmstripRows,
                defaultColumns: viewModel.defaultFilmstripColumns
            ) {
                viewModel.filmstripRefreshId &+= 1
            }
        }
        .confirmationDialog(
            "Delete \(viewModel.pendingDeleteIds.count == 1 ? "Video" : "\(viewModel.pendingDeleteIds.count) Videos")",
            isPresented: $viewModel.showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = viewModel.pendingDeleteIds
                viewModel.pendingDeleteIds = []
                Task { await viewModel.deleteVideos(ids) }
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingDeleteIds = []
            }
        } message: {
            if viewModel.pendingDeleteIds.count == 1 {
                Text("The file will be moved to Trash.")
            } else {
                Text("\(viewModel.pendingDeleteIds.count) files will be moved to Trash.")
            }
        }
    }

    private var listTableWithContextMenu: some View {
        Table(
            viewModel.filteredVideos,
            selection: tableSelectionBinding,
            // While shuffled, `tableSortOrder` itself is left untouched (see `shuffleOrder()`) so
            // exiting random order can tell whether the user picked a genuinely different sort —
            // but that means the Table would otherwise keep showing a caret on whichever column
            // was sorted before the shuffle. Reporting an empty order here clears that indicator
            // without touching the real value; a real column click still writes through normally,
            // which correctly exits random order via `tableSortOrder`'s own didSet.
            sortOrder: Binding(
                get: { (viewModel.isRandomOrder || viewModel.isShowingAlbumOrder) ? [] : viewModel.tableSortOrder },
                set: { viewModel.tableSortOrder = $0 }
            ),
            columnCustomization: $viewModel.columnCustomization
        ) {
            listTableColumns()
        }
        .contextMenu(forSelectionType: Video.ID.self) { ids in
            listSelectionContextMenu(tableSelection: ids)
        } primaryAction: { ids in
            handleListPrimaryAction(ids: ids)
        }
    }

    @ViewBuilder
    private func listSelectionContextMenu(tableSelection selectionIds: Set<String>) -> some View {
        if let filePath = selectionIds.first,
           let video = viewModel.filteredVideos.first(where: { $0.id == filePath })
        {
            let ids = effectiveContextMenuIds(tableSelection: selectionIds, for: video.id)
            let isMoving = ids.contains { viewModel.activeMoveVideoIds.contains($0) }
            Button("Play in External Player") {
                    NSWorkspace.shared.open(video.url)
                    Task { await viewModel.recordPlay(for: video) }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(
                        video.filePath, inFileViewerRootedAtPath: ""
                    )
                }
                if ids.count == 1 {
                    Button("Edit Title\u{2026}") {
                        viewModel.beginEditingTitle(for: video)
                    }
                    Button("Rename File\u{2026}") {
                        viewModel.beginRenamingFile(for: video)
                    }
                    .disabled(isMoving)
                    .help(isMoving ? "Move in progress — file isn't safe to modify yet" : "")
                }
                Button("Bulk Rename\u{2026}") {
                    viewModel.selectedVideoIds = ids
                    viewModel.presentBulkRename(scope: .selection)
                }
                .disabled(isMoving)
                .help(isMoving ? "Move in progress — file isn't safe to modify yet" : "")
                Menu("Open With") {
                    // If the right-clicked row is part of a multi-selection,
                    // send the whole selection; otherwise just this one video.
                    // Single pass with O(1) set lookups — the old per-id linear scan made a
                    // right-click on a large selection cost selection × library comparisons.
                    let urlsToSend: [URL] = {
                        if ids.count > 1, ids.contains(video.id) {
                            return viewModel.filteredVideos.filter { ids.contains($0.id) }.map(\.url)
                        }
                        return [video.url]
                    }()
                    if ExternalApps.isSubmarineInstalled {
                        Button("Submarine") {
                            ExternalApps.openInSubmarine(urlsToSend)
                        }
                        Divider()
                    }
                    let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: video.url)
                    ForEach(appURLs, id: \.self) { appURL in
                        Button(appURL.deletingPathExtension().lastPathComponent) {
                            NSWorkspace.shared.open(
                                [video.url],
                                withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()
                            )
                            Task { await viewModel.recordPlay(for: video) }
                        }
                    }
                }
                .disabled(isMoving)
                .help(isMoving ? "Move in progress — file isn't safe to modify yet" : "")
                Divider()
                Button("Fix for Built-in Player\u{2026}") {
                    if let ffmpeg = ffmpegPath {
                        let selected = viewModel.filteredVideos.filter { ids.contains($0.id) }
                        for v in selected {
                            viewModel.reencodeVideo(v, ffmpegPath: ffmpeg)
                        }
                    }
                }
                .disabled(isMoving || ffmpegPath == nil)
                .help(isMoving ? "Move in progress — file isn't safe to modify yet" : (ffmpegPath == nil ? "Requires ffmpeg — configure the path in Settings \u{2192} Tools" : ""))
                Button("Move Files\u{2026}") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Move Here"
                    panel.message = "Choose a destination folder"
                    if panel.runModal() == .OK, let dest = panel.url {
                        let selected = viewModel.filteredVideos.filter { ids.contains($0.id) }
                        Task { await viewModel.moveVideos(selected, to: dest) }
                    }
                }
                .disabled(isMoving)
                .help(isMoving ? "Move already in progress" : "")
                Divider()
                Button("Modify Filmstrip\u{2026}") {
                    let selected = viewModel.filteredVideos.filter { ids.contains($0.id) }
                    filmstripSession = FilmstripModifySession(videos: selected)
                }
                Button("Set Poster from Image\u{2026}") {
                    let selected = viewModel.filteredVideos.filter { ids.contains($0.id) }
                    Task {
                        await viewModel.chooseAndApplyPosterImage(
                            to: selected,
                            thumbnailService: thumbnailService
                        )
                    }
                }
                .disabled(isMoving)
                .help(isMoving ? "Move in progress — file isn't safe to modify yet" : "Choose an image to use as the poster thumbnail")
                Button("Regenerate Thumbnail") {
                    let selected = viewModel.filteredVideos.filter { ids.contains($0.id) }
                    for v in selected {
                        Task {
                            if let url = try? await thumbnailService.regenerateThumbnail(for: v) {
                                await viewModel.setRegeneratedThumbnailPath(videoPath: v.filePath, url: url)
                            }
                        }
                    }
                }
                .disabled(isMoving)
                .help(isMoving ? "Move in progress — file isn't safe to modify yet" : "")
                if ids.contains(where: { viewModel.isDuplicate($0) }) {
                    Divider()
                    Button("Not a Duplicate") {
                        let selected = viewModel.filteredVideos.filter { ids.contains($0.id) }
                        Task { await viewModel.markNotDuplicate(selected) }
                    }
                    .help("Confirm this isn't a duplicate — it leaves the Duplicates library and stays out unless a genuinely new matching file is added")
                }
                Divider()
                Button("Export Metadata\u{2026}") {
                    // Context menu selection `ids` is the effective set for this action.
                    viewModel.selectedVideoIds = ids
                    viewModel.presentExportMetadata(scope: .selection)
                }
                Divider()
                Button("New Album from Selection\u{2026}") {
                    viewModel.presentNewAlbumFromSelection(ids)
                }
                if !viewModel.albums.isEmpty {
                    Menu("Add to Album") {
                        ForEach(viewModel.albums, id: \.listId) { album in
                            Button(album.name) {
                                Task { await viewModel.addVideos(paths: ids, toAlbum: album) }
                            }
                        }
                    }
                }
                if case .collection(let active) = viewModel.sidebarFilter, active.isAlbum {
                    Button("Remove from \"\(active.name)\"") {
                        Task { await viewModel.removeVideos(paths: ids, fromAlbum: active) }
                    }
                }
                Divider()
                Button("Remove from Library") {
                    Task { await viewModel.removeVideosFromLibrary(ids) }
                }
                .disabled(isMoving)
                .help(isMoving ? "Move in progress — file isn't safe to modify yet" : "")
                Button("Delete Video…", role: .destructive) {
                    if viewModel.confirmDeletions {
                        viewModel.pendingDeleteIds = ids
                        viewModel.showDeleteConfirmation = true
                    } else {
                        Task { await viewModel.deleteVideos(ids) }
                    }
                }
                .disabled(isMoving)
                .help(isMoving ? "Move in progress — file isn't safe to modify yet" : "")
        }
    }

    private func handleListPrimaryAction(ids: Set<String>) {
        if let filePath = ids.first,
           let video = viewModel.filteredVideos.first(where: { $0.id == filePath })
        {
            if viewModel.isReviewMode {
                viewModel.setReviewFocus(video.id, retargetIfPlaying: false)
            } else {
                viewModel.selectOnly(video.id)
            }
            viewModel.isPlayingInline = true
        }
    }

    @TableColumnBuilder<Video, KeyPathComparator<Video>>
    private func listTableColumns() -> some TableColumnContent<Video, KeyPathComparator<Video>> {
        TableColumn("Title", value: \.displayTitle) { video in
            nameRowView(for: video)
        }
        .width(min: 200, ideal: 350)
        .customizationID("name")

        // Grouped so the outer `Table` column builder stays within SwiftUI’s sibling limit.
        listStandardOptionalColumns()

        // `ForEach` is not supported inside `TableColumnBuilder`; emit up to 16 custom columns by index.
        // Split across two helpers: SwiftUI’s column builder limits sibling column count per block.
        listCustomTableColumnsSlots0to7()
        listCustomTableColumnsSlots8to15()
    }

    @TableColumnBuilder<Video, KeyPathComparator<Video>>
    private func listStandardOptionalColumns() -> some TableColumnContent<Video, KeyPathComparator<Video>> {
        if viewModel.isStandardListColumnVisible("duration") {
            TableColumn("Duration", value: \.sortableDuration) { video in
                Text(video.formattedDuration ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(Color.appTextSecondary)
            }
            .width(min: 60, ideal: 80)
            .alignment(.trailing)
            .customizationID("duration")
        }

        if viewModel.isStandardListColumnVisible("resolution") {
            TableColumn("Resolution", value: \.sortableResolutionHeight) { video in
                if let label = video.resolutionLabel {
                    Text(label)
                        .font(Font.appCaption2)
                        .padding(.horizontal, AppSpacing.xxs)
                        .padding(.vertical, 1)
                        .background(Color.appSurface)
                        .foregroundStyle(Color.appAccent)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous))
                } else {
                    Text("—")
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
            .width(min: 60, ideal: 80)
            .alignment(.center)
            .customizationID("resolution")
        }

        if viewModel.isStandardListColumnVisible("size") {
            TableColumn("Size", value: \.fileSize) { video in
                Text(video.formattedFileSize)
                    .monospacedDigit()
                    .foregroundStyle(Color.appTextSecondary)
            }
            .width(min: 60, ideal: 80)
            .alignment(.trailing)
            .customizationID("size")
        }

        if viewModel.isStandardListColumnVisible("rating") {
            TableColumn("Rating", value: \.rating) { video in
                RatingView(rating: video.rating, size: 10) { newRating in
                    viewModel.applyRating(to: [video.id], rating: newRating)
                    Task { await viewModel.persistRating(for: [video.id], rating: newRating) }
                }
            }
            .width(min: 70, ideal: 90)
            .customizationID("rating")
        }

        if viewModel.isStandardListColumnVisible("dateAdded") {
            TableColumn("Date Added", value: \.dateAdded) { video in
                Text(video.dateAdded, format: .dateTime.month(.twoDigits).day(.twoDigits).year())
                    .foregroundStyle(Color.appTextSecondary)
                    .help(video.dateAdded.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 80, ideal: 100)
            .customizationID("dateAdded")
        }

        if viewModel.isStandardListColumnVisible("playCount") {
            TableColumn("Plays", value: \.sortablePlayCount) { video in
                Text("\(video.playCount)")
                    .monospacedDigit()
                    .foregroundStyle(Color.appTextSecondary)
            }
            .width(min: 56, ideal: 72)
            .alignment(.trailing)
            .customizationID("playCount")
        }

        if viewModel.isStandardListColumnVisible("created") {
            TableColumn("Created", value: \.sortableCreationDate) { video in
                if let created = video.creationDate {
                    Text(created, format: .dateTime.month(.twoDigits).day(.twoDigits).year())
                        .foregroundStyle(Color.appTextSecondary)
                        .help(created.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("—")
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
            .width(min: 80, ideal: 100)
            .customizationID("created")
        }

        if viewModel.isStandardListColumnVisible("lastPlayed") {
            TableColumn("Last Played", value: \.sortableLastPlayed) { video in
                if let last = video.lastPlayed {
                    Text(last, format: .dateTime.month(.twoDigits).day(.twoDigits).year())
                        .foregroundStyle(Color.appTextSecondary)
                        .help(last.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("—")
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
            .width(min: 80, ideal: 100)
            .customizationID("lastPlayed")
        }
    }

    @TableColumnBuilder<Video, KeyPathComparator<Video>>
    private func listCustomTableColumnsSlots0to7() -> some TableColumnContent<Video, KeyPathComparator<Video>> {
        let fields = viewModel.allCustomFieldsForList
        if fields.indices.contains(0) { listCustomColumn(for: fields[0], slot: 0) }
        if fields.indices.contains(1) { listCustomColumn(for: fields[1], slot: 1) }
        if fields.indices.contains(2) { listCustomColumn(for: fields[2], slot: 2) }
        if fields.indices.contains(3) { listCustomColumn(for: fields[3], slot: 3) }
        if fields.indices.contains(4) { listCustomColumn(for: fields[4], slot: 4) }
        if fields.indices.contains(5) { listCustomColumn(for: fields[5], slot: 5) }
        if fields.indices.contains(6) { listCustomColumn(for: fields[6], slot: 6) }
        if fields.indices.contains(7) { listCustomColumn(for: fields[7], slot: 7) }
    }

    @TableColumnBuilder<Video, KeyPathComparator<Video>>
    private func listCustomTableColumnsSlots8to15() -> some TableColumnContent<Video, KeyPathComparator<Video>> {
        let fields = viewModel.allCustomFieldsForList
        if fields.indices.contains(8)  { listCustomColumn(for: fields[8],  slot: 8)  }
        if fields.indices.contains(9)  { listCustomColumn(for: fields[9],  slot: 9)  }
        if fields.indices.contains(10) { listCustomColumn(for: fields[10], slot: 10) }
        if fields.indices.contains(11) { listCustomColumn(for: fields[11], slot: 11) }
        if fields.indices.contains(12) { listCustomColumn(for: fields[12], slot: 12) }
        if fields.indices.contains(13) { listCustomColumn(for: fields[13], slot: 13) }
        if fields.indices.contains(14) { listCustomColumn(for: fields[14], slot: 14) }
        if fields.indices.contains(15) { listCustomColumn(for: fields[15], slot: 15) }
    }

    @TableColumnBuilder<Video, KeyPathComparator<Video>>
    private func listCustomColumn(for field: CustomMetadataFieldDefinition, slot: Int) -> some TableColumnContent<
        Video,
        KeyPathComparator<Video>
    > {
        // Sentinel keypath gives the column a unique sort identity for caret display and header-click detection.
        // defaultVisibility reflects the Settings > List Columns toggle; columnCustomization overrides it.
        let defaultVis: Visibility = viewModel.isCustomFieldDefaultVisible(field.id) ? .visible : .hidden
        TableColumn(field.name, value: Video.customSortKeyPath(slot: slot)) { video in
            Text(viewModel.listCustomFieldDisplay(for: video, field: field))
                .lineLimit(2)
                .foregroundStyle(Color.appTextSecondary)
        }
        .width(min: 80, ideal: 120)
        .customizationID("custom-\(field.id.uuidString)")
        .defaultVisibility(defaultVis)
    }

    @ViewBuilder
    private func nameRowView(for video: Video) -> some View {
        HStack(spacing: AppSpacing.sm) {
            if viewModel.isViewingAlbum {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.appAccent)
                    .help("Drag to reorder this album")
                    .allowsHitTesting(false)
            }
            listRowThumbnail(for: video)

            if viewModel.renamingVideoId == video.id {
                TextField("", text: $viewModel.renameText)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .padding(.horizontal, AppSpacing.xs)
                    .padding(.vertical, AppSpacing.xxs)
                    .background(Color.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous)
                            .stroke(Color.appAccent, lineWidth: 1.5)
                    )
                    .focused($isRenameFocused)
                    .onSubmit { commitRename(video) }
                    .onExitCommand { cancelRename() }
                    .onAppear {
                        viewModel.isEditingText = true
                        DispatchQueue.main.async {
                            isRenameFocused = true
                        }
                    }
                    .onDisappear {
                        viewModel.isEditingText = false
                    }
            } else if viewModel.editingTitleVideoId == video.id {
                TextField("", text: $viewModel.titleEditText)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .padding(.horizontal, AppSpacing.xs)
                    .padding(.vertical, AppSpacing.xxs)
                    .background(Color.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous)
                            .stroke(Color.appAccent, lineWidth: 1.5)
                    )
                    .focused($isRenameFocused)
                    .onSubmit { commitTitleEdit(video) }
                    .onExitCommand { cancelTitleEdit() }
                    .onAppear {
                        viewModel.isEditingText = true
                        DispatchQueue.main.async {
                            isRenameFocused = true
                        }
                    }
                    .onDisappear {
                        viewModel.isEditingText = false
                    }
            } else {
                Text(video.displayTitle)
                    .lineLimit(1)
                    .foregroundStyle(Color.appTextPrimary)
                if video.subtitlePresence.showsBadge {
                    // Blue-accented subtitles indicator, consistent with Cinematic Blue theme.
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.appAccent, in: RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous))
                        .help(video.subtitlePresence.badgeHelp)
                        .accessibilityLabel(video.subtitlePresence.badgeHelp)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if viewModel.isReviewMode {
                reviewRowStore.state(for: video.id).isRowHovering = hovering
            }
        }
        .overlay {
            if viewModel.isViewingAlbum {
                AlbumReorderInteractionOverlay(
                    videoId: video.id,
                    title: video.displayTitle,
                    onClick: { _ in
                        if viewModel.isReviewMode {
                            viewModel.setReviewFocus(video.id)
                        } else {
                            viewModel.selectedVideoIds = [video.id]
                        }
                    },
                    onDoubleClick: { viewModel.isPlayingInline = true },
                    onTargeted: { hovering in
                        if hovering {
                            albumReorderTargetId = video.id
                        } else if albumReorderTargetId == video.id {
                            albumReorderTargetId = nil
                        }
                    },
                    onReorder: { draggedId in
                        Task {
                            await viewModel.reorderAlbumDrop(
                                draggingPathId: draggedId,
                                ontoPathId: video.id
                            )
                        }
                    }
                )
            }
        }
        .overlay {
            if albumReorderTargetId == video.id {
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .strokeBorder(Color.appAccent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private var ffmpegPath: String? { viewModel.resolvedFFmpegPath }

    private func commitRename(_ video: Video) {
        let newName = viewModel.renameText.trimmingCharacters(in: .whitespaces)
        viewModel.cancelFileRename()
        guard !newName.isEmpty, newName != video.fileName else { return }
        Task {
            _ = await viewModel.renameVideo(video, to: newName)
        }
    }

    private func cancelRename() {
        viewModel.cancelFileRename()
    }

    private func commitTitleEdit(_ video: Video) {
        let newTitle = viewModel.titleEditText.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.cancelTitleEdit()
        guard newTitle != video.displayTitle else { return }
        Task {
            await viewModel.updateVideoTitle(video, to: newTitle)
        }
    }

    private func cancelTitleEdit() {
        viewModel.cancelTitleEdit()
    }

    @ViewBuilder
    private func listRowThumbnail(for video: Video) -> some View {
        let thumb = ListRowHoverThumbnail(
            video: video,
            thumbnailService: thumbnailService,
            hoverPreviewEnabled: viewModel.gridHoverPreviewEnabled && !viewModel.isPlayingInline,
            isMoving: viewModel.activeMoveVideoIds.contains(video.id),
            onSelect: { selectListRow(video) },
            onModifierSelect: { handleListThumbnailModifierClick(video, flags: $0) }
        )

        if viewModel.isReviewMode {
            let reviewState = reviewRowStore.state(for: video.id)
            ZStack(alignment: .topLeading) {
                thumb
                ListCollectedSetBadge(
                    isCollected: viewModel.selectedVideoIds.contains(video.id),
                    reviewState: reviewState,
                    onCollectClick: { handleCollectCircleClick(video, flags: $0) }
                )
            }
            .frame(width: 56, height: 36)
            .onHover { reviewState.isRowHovering = $0 }
        } else {
            thumb
        }
    }

    private func selectListRow(_ video: Video) {
        lastClickedId = video.id
        if viewModel.isReviewMode {
            viewModel.setReviewFocus(video.id)
        } else {
            viewModel.selectedVideoIds = [video.id]
        }
    }

    private func handleCollectCircleClick(_ video: Video, flags: NSEvent.ModifierFlags) {
        var session = ReviewSession(
            focusedId: viewModel.focusedVideoId,
            selectedIds: viewModel.selectedVideoIds,
            inspectorPrefersSelection: viewModel.inspectorPrefersSelection
        )
        lastClickedId = session.applyCollectCircleClick(
            id: video.id,
            orderedIds: viewModel.filteredVideos.map(\.id),
            anchorId: lastClickedId,
            flags: flags
        )
        viewModel.focusedVideoId = session.focusedId
        viewModel.selectedVideoIds = session.selectedIds
        viewModel.inspectorPrefersSelection = session.inspectorPrefersSelection
        if let id = session.focusedId {
            viewModel.lastSelectedVideoId = id
        }
    }

    private func handleListThumbnailModifierClick(_ video: Video, flags: NSEvent.ModifierFlags) {
        if !viewModel.isReviewMode {
            if flags.contains(.command) {
                var ids = viewModel.selectedVideoIds
                if ids.contains(video.id) { ids.remove(video.id) } else { ids.insert(video.id) }
                viewModel.selectedVideoIds = ids
                lastClickedId = video.id
                return
            }
            if flags.contains(.shift) {
                viewModel.selectedVideoIds = listModifierSelectionIds(for: video, flags: flags)
                lastClickedId = video.id
                return
            }
        }
        applyTableSelection(listModifierSelectionIds(for: video, flags: flags), flags: flags)
    }

    private func listModifierSelectionIds(for video: Video, flags: NSEvent.ModifierFlags) -> Set<String> {
        if flags.contains(.shift) {
            let anchor = lastClickedId
                ?? viewModel.focusedVideoId
                ?? viewModel.selectedVideoIds.first
            if let anchor,
               let aIdx = viewModel.filteredVideos.firstIndex(where: { $0.id == anchor }),
               let idx = viewModel.filteredVideos.firstIndex(where: { $0.id == video.id })
            {
                let range = min(aIdx, idx)...max(aIdx, idx)
                return Set(range.map { viewModel.filteredVideos[$0].id })
            }
        }
        return [video.id]
    }

    private func effectiveContextMenuIds(tableSelection: Set<String>, for videoId: String) -> Set<String> {
        if viewModel.isReviewMode {
            if viewModel.selectedVideoIds.contains(videoId), !viewModel.selectedVideoIds.isEmpty {
                return viewModel.selectedVideoIds
            }
            return [videoId]
        }
        if tableSelection.count > 1, tableSelection.contains(videoId) {
            return tableSelection
        }
        return [videoId]
    }

    private func applyTableSelection(
        _ newIds: Set<String>,
        flags: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {
        if !viewModel.isReviewMode {
            viewModel.selectedVideoIds = newIds
            return
        }

        var session = ReviewSession(
            focusedId: viewModel.focusedVideoId,
            selectedIds: viewModel.selectedVideoIds,
            inspectorPrefersSelection: viewModel.inspectorPrefersSelection
        )
        lastClickedId = session.applyListTableSelection(
            newIds: newIds,
            allVideoIds: viewModel.filteredVideos.map(\.id),
            previousTableFocusId: viewModel.focusedVideoId,
            lastClickedId: lastClickedId,
            flags: flags
        )
        viewModel.focusedVideoId = session.focusedId
        viewModel.selectedVideoIds = session.selectedIds
        viewModel.inspectorPrefersSelection = session.inspectorPrefersSelection
        if let id = session.focusedId {
            viewModel.lastSelectedVideoId = id
        }
    }

    private func scrollToSelectedRow(delay: Double) {
        let primaryId = viewModel.focusedVideoId ?? viewModel.selectedVideoIds.first
        guard let selectedId = primaryId,
              let row = viewModel.filteredVideos.firstIndex(where: { $0.id == selectedId })
        else {
            // No selection to scroll to (e.g. after Deselect All) — still grab first responder so
            // the Table's native ⌘A/arrow-key handling works right after switching from Wall.
            focusTable(delay: delay)
            return
        }
        scrollPositionRow = row
        scrollToRow(withId: selectedId, delay: delay)
    }

    private func focusTable(delay: Double) {
        // Retry at a couple of delays — same rationale as TableScrollHelper's scroll retries: right
        // after cold launch or a view switch, the Table's underlying NSTableView may not be laid out
        // (or its window may not be key) yet on the first attempt.
        for extra in [0.0, 0.2, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + extra) {
                guard let window = NSApp.keyWindow,
                      let content = window.contentView,
                      let tableView = TableScrollHelper.findTableView(in: content),
                      window.firstResponder !== tableView
                else { return }
                window.makeFirstResponder(tableView)
            }
        }
    }

    private func scrollToRow(withId id: String, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let row = viewModel.filteredVideos.firstIndex(where: { $0.id == id }) {
                scrollToRow = nil
                DispatchQueue.main.async {
                    scrollToRow = row
                }
            }
        }
    }
}
