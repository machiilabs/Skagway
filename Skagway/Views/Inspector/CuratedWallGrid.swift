import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Per-card selection state

/// One `@Observable` instance per card. When `isSelected` changes, only that card's
/// body re-runs — not the entire grid. This matches AppKit table behaviour where row
/// highlighting is O(1) rather than O(visible rows).
@Observable
final class CardSelectionState {
    var isSelected: Bool = false
    var isFocused: Bool = false
    var isHovering: Bool = false
}

/// Plain (non-`@Observable`) store so `CuratedWallGrid.body` can call `state(for:)`
/// without registering a SwiftUI observation dependency on the selection set.
private final class CardSelectionStore {
    private var states: [String: CardSelectionState] = [:]

    func state(for id: String) -> CardSelectionState {
        if let s = states[id] { return s }
        let s = CardSelectionState()
        states[id] = s
        return s
    }

    func sync(to newIds: Set<String>) {
        let current = Set(states.filter { $0.value.isSelected }.keys)
        for id in current.subtracting(newIds) { states[id]?.isSelected = false }
        for id in newIds.subtracting(current) { state(for: id).isSelected = true }
    }

    func syncFocus(to id: String?) {
        let current = states.first(where: { $0.value.isFocused })?.key
        if current == id { return }
        if let current { states[current]?.isFocused = false }
        if let id { state(for: id).isFocused = true }
    }
}

/// Process-wide Launch Services cache for "Open With" menus. Filled synchronously on miss so
/// eager `.contextMenu` builders don't re-query LS for every visible card of a new extension.
private enum OpenWithAppCache {
    static var byExtension: [String: [URL]] = [:]
}

// MARK: - Grid

/// The elegant "Wall" browsing surface for the Curated Wall experience.
/// Matches the refined mockups:
/// - Poster Grid: up to 8 columns when the browser is wide, ~188pt thumbs
/// - Storyboard View: fewer/taller cards with a large 2×3 collage per clip
/// - Clean gallery cards (no dense metadata overload)
/// - No in-wall header or controls — search/count/toggle/filters live in the thin bar above
struct CuratedWallGrid: View {
    @Bindable var viewModel: LibraryViewModel
    let thumbnailService: ThumbnailService
    /// Browser pane width from ContentView's GeometryReader (not ScrollView background —
    /// that measure was unreliable and collapsed the grid to 1 column).
    let containerWidth: CGFloat

    @State private var lastClickedId: String?
    @FocusState private var renameFocus: Bool
    @State private var selectionStore = CardSelectionStore()
    @State private var filmstripSession: FilmstripModifySession?
    /// Card id currently targeted by an image/video file drag (poster drop highlight).
    @State private var posterDropTargetId: String?
    /// Card id currently targeted by an in-album reorder drag.
    @State private var albumReorderTargetId: String?

    private var isStoryboard: Bool { viewModel.viewMode == .storyboard }
    private var storyboardDensity: StoryboardDensity { viewModel.storyboardDensity }

    // Max from the full-window mock; live `columns` is the source of truth for ↑/↓ row steps
    // in ContentView and for scroll-to-row math below.
    static let maxColumns = 8
    private(set) static var columns = 5
    /// Whole-card floor: thumb (188) + under-thumb row + card padding ≈ 220.
    private static let minCellWidth: CGFloat = 220
    private static let spacing: CGFloat = 22
    private static let outerPadding: CGFloat = 18

    /// Storyboard packing knobs — Normal is the roomier default; Compact is tighter.
    private var storyboardMaxColumns: Int {
        switch storyboardDensity {
        case .compact: return 4
        case .normal: return 3
        }
    }
    private var storyboardMinCellWidth: CGFloat {
        switch storyboardDensity {
        case .compact: return 360
        case .normal: return 440
        }
    }
    private var storyboardColumnSpacing: CGFloat {
        switch storyboardDensity {
        case .compact: return 16
        case .normal: return 28
        }
    }
    private var storyboardRowSpacing: CGFloat {
        switch storyboardDensity {
        case .compact: return 12
        case .normal: return 22
        }
    }
    private var storyboardOuterPadding: CGFloat {
        switch storyboardDensity {
        case .compact: return 12
        case .normal: return 18
        }
    }

    private var activeMaxColumns: Int { isStoryboard ? storyboardMaxColumns : Self.maxColumns }
    private var activeMinCellWidth: CGFloat { isStoryboard ? storyboardMinCellWidth : Self.minCellWidth }
    private var columnSpacing: CGFloat { isStoryboard ? storyboardColumnSpacing : Self.spacing }
    private var rowSpacing: CGFloat { isStoryboard ? storyboardRowSpacing : Self.spacing }
    private var outerPadding: CGFloat { isStoryboard ? storyboardOuterPadding : Self.outerPadding }

    /// Largest `1...maxColumns` such that flexible cells are at least `minCellWidth` wide.
    /// Invalid/zero widths keep `maxColumns` so a transient layout pass can't pin the grid at 1.
    /// Used for ↑/↓ and Inspector scroll-pin math — not as `LazyVGrid(columns: count:)` (that remounts).
    static func columnCount(
        forContainerWidth width: CGFloat,
        maxColumns: Int = maxColumns,
        minCellWidth: CGFloat = minCellWidth,
        spacing: CGFloat = spacing,
        outerPadding: CGFloat = outerPadding
    ) -> Int {
        guard width > 1 else { return maxColumns }
        let inner = max(0, width - outerPadding * 2)
        let n = Int((inner + spacing) / (minCellWidth + spacing))
        return min(maxColumns, max(1, n))
    }

    /// Raise `minCellWidth` just enough that `maxColumns + 1` cannot fit. Typical ⌘I (3→4 Compact)
    /// leaves the value at `minCellWidth`, so the single adaptive `GridItem` identity is unchanged.
    static func adaptiveColumnMinimum(
        containerWidth: CGFloat,
        maxColumns: Int,
        minCellWidth: CGFloat,
        spacing: CGFloat,
        outerPadding: CGFloat
    ) -> CGFloat {
        let inner = max(0, containerWidth - outerPadding * 2)
        let cols = max(1, maxColumns)
        let capFloor = (inner + spacing) / CGFloat(cols + 1) - spacing
        return max(minCellWidth, capFloor + 1)
    }

    /// One adaptive `GridItem` so pane-width changes (⌘I) reflow 3→4 without replacing the grid.
    /// Changing `Array(repeating:count:)` from N→M tears down every visible card, restarts `.task`,
    /// and re-decodes Storyboard collages.
    static func wallGridItems(
        minCellWidth: CGFloat,
        spacing: CGFloat,
        maxColumns: Int = maxColumns,
        containerWidth: CGFloat = 0,
        outerPadding: CGFloat = outerPadding
    ) -> [GridItem] {
        let minimum = adaptiveColumnMinimum(
            containerWidth: containerWidth,
            maxColumns: maxColumns,
            minCellWidth: minCellWidth,
            spacing: spacing,
            outerPadding: outerPadding
        )
        return [GridItem(.adaptive(minimum: minimum), spacing: spacing)]
    }

    private var columnCount: Int {
        Self.columnCount(
            forContainerWidth: containerWidth,
            maxColumns: activeMaxColumns,
            minCellWidth: activeMinCellWidth,
            spacing: columnSpacing,
            outerPadding: outerPadding
        )
    }

    private var wallGridItems: [GridItem] {
        Self.wallGridItems(
            minCellWidth: activeMinCellWidth,
            spacing: columnSpacing,
            maxColumns: activeMaxColumns,
            containerWidth: containerWidth,
            outerPadding: outerPadding
        )
    }

    var body: some View {
        // Adaptive columns follow the real pane width (3→4 Compact on ⌘I hide). Integer
        // `columnCount` is only for keyboard / pin math. One GridItem keeps card identity —
        // no `.id(filteredVideosVersion)`, no N→M remount. Animation is suppressed on the
        // grid content only — not the ScrollView — so the sort-index HUD still gets
        // live-scroll notifications.
        // No GeometryReader around LazyVGrid content — preserves native scroller behaviour.
        let cols = columnCount
        ScrollView(.vertical) {
            LazyVGrid(
                    columns: wallGridItems,
                    spacing: rowSpacing
                ) {
                    ForEach(viewModel.filteredVideos) { video in
                        let isRenamingRow = viewModel.renamingVideoId == video.id
                        let isEditingTitleRow = viewModel.editingTitleVideoId == video.id
                        let isMoving = viewModel.activeMoveVideoIds.contains(video.id)
                        CuratedWallCard(
                            video: video,
                            selectionState: selectionStore.state(for: video.id),
                            isRenaming: isRenamingRow,
                            isEditingTitle: isEditingTitleRow,
                            renameText: isRenamingRow ? $viewModel.renameText : .constant(""),
                            titleEditText: isEditingTitleRow ? $viewModel.titleEditText : .constant(""),
                            thumbnailService: thumbnailService,
                            displayMode: isStoryboard ? WallCardMediaMode.storyboard : .poster,
                            storyboardDensity: isStoryboard ? storyboardDensity : .normal,
                            isMoving: isMoving,
                            resumeFraction: resumeFraction(for: video),
                            hoverPreviewEnabled: !isStoryboard
                                && viewModel.gridHoverPreviewEnabled
                                && !viewModel.isPlayingInline,
                            thumbnailReloadId: viewModel.filmstripRefreshId,
                            showAlbumReorderHandle: viewModel.isViewingAlbum,
                            renameFocus: $renameFocus,
                            onCommitRename: { commitRename(video) },
                            onCancelRename: cancelRename,
                            onCommitTitle: { commitTitleEdit(video) },
                            onCancelTitle: cancelTitleEdit,
                            onRenameEditingChanged: { viewModel.isEditingText = $0 },
                            onStoryboardCellPlay: isStoryboard
                                ? { location, size in
                                    // Collage is Option 2 without the collected-set batch toggle:
                                    // unfocused → focus only; focused → seek+play. Title/footer
                                    // chrome still uses full handleSelection (batch ↔ single).
                                    let flags = NSEvent.modifierFlags
                                    if ListSelectionModifiers.usesExtendedSelection(flags) {
                                        handleSelection(video, flags: flags)
                                    } else if viewModel.focusedVideoId == video.id {
                                        playStoryboardCell(video, at: location, size: size)
                                    } else {
                                        focusStoryboardCollage(video)
                                    }
                                }
                                : nil,
                            onStoryboardChromeSelect: isStoryboard && !viewModel.isViewingAlbum
                                ? { handleSelection(video) }
                                : nil
                        )
                        // Identity is `video.id` from ForEach — do not append filmstrip/view-mode
                        // into `.id(...)` or Inspector width/column reflow remounts every card.
                        .contentShape(Rectangle())
                        .modifier(AlbumSelectionGestures(
                            enabled: !viewModel.isViewingAlbum && !isStoryboard,
                            onSelect: { handleSelection(video) },
                            onPlay: {
                                viewModel.setReviewFocus(video.id, retargetIfPlaying: false)
                                viewModel.isPlayingInline = true
                            }
                        ))
                        .modifier(StoryboardSelectionGestures(
                            enabled: isStoryboard && !viewModel.isViewingAlbum,
                            onSelect: { handleSelection(video) }
                        ))
                        .overlay(alignment: .topLeading) {
                            collectedSetCheckmark(for: video)
                        }
                        .onHover { hovering in
                            selectionStore.state(for: video.id).isHovering = hovering
                        }
                        .onDrop(of: [.fileURL], isTargeted: Binding(
                            get: { posterDropTargetId == video.id },
                            set: { hovering in
                                if hovering {
                                    posterDropTargetId = video.id
                                } else if posterDropTargetId == video.id {
                                    posterDropTargetId = nil
                                }
                            }
                        )) { providers in
                            handleCardFileDrop(providers, onto: video)
                        }
                        .overlay {
                            if viewModel.isViewingAlbum {
                                AlbumReorderInteractionOverlay(
                                    videoId: video.id,
                                    title: video.displayTitle,
                                    onClick: { flags in handleSelection(video, flags: flags) },
                                    onDoubleClick: {
                                        viewModel.setReviewFocus(video.id, retargetIfPlaying: false)
                                        viewModel.isPlayingInline = true
                                    },
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
                            if posterDropTargetId == video.id || albumReorderTargetId == video.id {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.appAccent, lineWidth: 2)
                                    .padding(4)
                                    .allowsHitTesting(false)
                            }
                        }
                        .contextMenu {
                            let menuState = selectionStore.state(for: video.id)
                            if menuState.isHovering || menuState.isFocused || menuState.isSelected {
                            Button("Play in External Player") { play(video) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.selectFile(video.filePath, inFileViewerRootedAtPath: "")
                            }
                            Button("Edit Title\u{2026}") {
                                viewModel.beginEditingTitle(for: video)
                            }
                    Button("Rename File\u{2026}") {
                        viewModel.beginRenamingFile(for: video)
                    }
                    .disabled(isMoving)
                    .help(isMoving ? "Move in progress — file isn't safe to modify yet" : "")
                    Button("Bulk Rename\u{2026}") {
                        let ids = viewModel.selectedVideoIds.contains(video.id)
                            ? viewModel.selectedVideoIds : [video.id]
                        viewModel.selectedVideoIds = ids
                        viewModel.presentBulkRename(scope: .selection)
                    }
                    .disabled(isMoving)
                    .help(isMoving ? "Move in progress — file isn't safe to modify yet" : "")
                    Menu("Open With") {
                                // NB: SwiftUI evaluates contextMenu content EAGERLY, per
                                // instantiated card, on every grid update — nothing heavy may
                                // run directly in this builder. Computing the selection URLs
                                // here (via a per-id linear scan, no less) was the 75-second
                                // select-all hang at 12k; it now happens in the button action.
                                // The installed-apps lookup below is a real Launch Services query,
                                // so it goes through `installedAppURLs(for:)`, which caches by file
                                // extension instead of re-querying per card on every render.
                                if ExternalApps.isSubmarineInstalled {
                                    Button("Submarine") { ExternalApps.openInSubmarine(openWithURLs(for: video)) }
                                    Divider()
                                }
                                let appURLs = installedAppURLs(for: video)
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
                                if let ffmpeg = viewModel.resolvedFFmpegPath {
                                    let ids = viewModel.selectedVideoIds.contains(video.id)
                                        ? viewModel.selectedVideoIds : [video.id]
                                    let selected = viewModel.filteredVideos.filter { ids.contains($0.id) }
                                    for v in selected { viewModel.reencodeVideo(v, ffmpegPath: ffmpeg) }
                                }
                            }
                            .disabled(isMoving || viewModel.resolvedFFmpegPath == nil)
                            .help(isMoving ? "Move in progress — file isn't safe to modify yet" : (viewModel.resolvedFFmpegPath == nil ? "Requires ffmpeg — configure the path in Settings \u{2192} Tools" : ""))
                            Button("Move Files\u{2026}") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.allowsMultipleSelection = false
                                panel.prompt = "Move Here"
                                panel.message = "Choose a destination folder"
                                if panel.runModal() == .OK, let dest = panel.url {
                                    let ids = viewModel.selectedVideoIds.contains(video.id)
                                        ? viewModel.selectedVideoIds : [video.id]
                                    let selected = viewModel.filteredVideos.filter { ids.contains($0.id) }
                                    Task { await viewModel.moveVideos(selected, to: dest) }
                                }
                            }
                            .disabled(isMoving)
                            .help(isMoving ? "Move already in progress" : "")
                            Divider()
                            Button("Modify Filmstrip\u{2026}") {
                                let ids = viewModel.selectedVideoIds.contains(video.id)
                                    ? viewModel.selectedVideoIds : [video.id]
                                let selected = viewModel.filteredVideos.filter { ids.contains($0.id) }
                                filmstripSession = FilmstripModifySession(videos: selected)
                            }
                            Button("Set Poster from Image\u{2026}") {
                                let ids = viewModel.selectedVideoIds.contains(video.id)
                                    ? viewModel.selectedVideoIds : [video.id]
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
                            Button("Regenerate Assets") {
                                let ids = viewModel.selectedVideoIds.contains(video.id)
                                    ? viewModel.selectedVideoIds : [video.id]
                                let selected = viewModel.filteredVideos.filter { ids.contains($0.id) }
                                Task { await viewModel.regenerateDerivedAssets(for: selected) }
                            }
                            .disabled(isMoving)
                            .help(isMoving ? "Move in progress — file isn't safe to modify yet" : "Rebuild the inspector filmstrip, storyboard, and scrubber strip")
                            Button("Regenerate Thumbnail") {
                                let ids = viewModel.selectedVideoIds.contains(video.id)
                                    ? viewModel.selectedVideoIds : [video.id]
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
                            if viewModel.isDuplicate(video.id) {
                                Divider()
                                Button("Not a Duplicate") {
                                    let ids = viewModel.selectedVideoIds.contains(video.id)
                                        ? viewModel.selectedVideoIds : [video.id]
                                    let selected = viewModel.filteredVideos.filter { ids.contains($0.id) }
                                    Task { await viewModel.markNotDuplicate(selected) }
                                }
                                .help("Confirm this isn't a duplicate — it leaves the Duplicates library and stays out unless a genuinely new matching file is added")
                            }
                            Divider()
                            Button("Export Metadata\u{2026}") {
                                let ids = viewModel.selectedVideoIds.contains(video.id)
                                    ? viewModel.selectedVideoIds : [video.id]
                                viewModel.selectedVideoIds = ids
                                viewModel.presentExportMetadata(scope: .selection)
                            }
                            Divider()
                            Button("New Album from Selection\u{2026}") {
                                let ids = viewModel.selectedVideoIds.contains(video.id)
                                    ? viewModel.selectedVideoIds : [video.id]
                                viewModel.presentNewAlbumFromSelection(ids)
                            }
                            if !viewModel.albums.isEmpty {
                                Menu("Add to Album") {
                                    ForEach(viewModel.albums, id: \.listId) { album in
                                        Button(album.name) {
                                            let ids = viewModel.selectedVideoIds.contains(video.id)
                                                ? viewModel.selectedVideoIds : [video.id]
                                            Task { await viewModel.addVideos(paths: ids, toAlbum: album) }
                                        }
                                    }
                                }
                            }
                            if case .collection(let active) = viewModel.sidebarFilter, active.isAlbum {
                                Button("Remove from \"\(active.name)\"") {
                                    let ids = viewModel.selectedVideoIds.contains(video.id)
                                        ? viewModel.selectedVideoIds : [video.id]
                                    Task { await viewModel.removeVideos(paths: ids, fromAlbum: active) }
                                }
                            }
                            Divider()
                            Button("Remove from Library") {
                                let ids = viewModel.selectedVideoIds.contains(video.id)
                                    ? viewModel.selectedVideoIds : [video.id]
                                Task { await viewModel.removeVideosFromLibrary(ids) }
                            }
                            .disabled(isMoving)
                            .help(isMoving ? "Move in progress — file isn't safe to modify yet" : "")
                            Button("Delete Video…", role: .destructive) {
                                let ids = viewModel.selectedVideoIds.contains(video.id)
                                    ? viewModel.selectedVideoIds : [video.id]
                                viewModel.pendingDeleteIds = ids
                                viewModel.showDeleteConfirmation = true
                            }
                            .disabled(isMoving)
                            .help(isMoving ? "Move in progress — file isn't safe to modify yet" : "")
                            }
                        }
                    }
                }
                .padding(outerPadding)
                .background(ScrollCommandHandler(command: viewModel.scrollCommand, mode: .grid))
                .transaction { $0.animation = nil }
                .background(
                    BrowserScrollPinController(
                        store: viewModel.browserScrollPinStore,
                        mode: .grid,
                        anchorVideoId: viewModel.focusedVideoId
                            ?? viewModel.lastSelectedVideoId
                            ?? viewModel.selectedVideoIds.first,
                        anchorIndex: {
                            let id = viewModel.focusedVideoId
                                ?? viewModel.lastSelectedVideoId
                                ?? viewModel.selectedVideoIds.first
                            guard let id else { return nil }
                            return viewModel.filteredVideos.firstIndex(where: { $0.id == id })
                        }(),
                        columnCount: cols,
                        videoCount: viewModel.filteredVideos.count,
                        thumbnailService: thumbnailService,
                        pathsInRange: { range in
                            let videos = viewModel.filteredVideos
                            let lo = max(0, range.lowerBound)
                            let hi = min(videos.count, range.upperBound)
                            guard lo < hi else { return [] }
                            return videos[lo..<hi].map(\.filePath)
                        }
                    )
                )
            }
            .scrollIndicators(.visible)
            .overlay {
                ScrollIndexHUDOverlay(viewModel: viewModel, mode: .grid)
                    .allowsHitTesting(false)
            }
            .background(Color(red: 3 / 255, green: 13 / 255, blue: 23 / 255))   // #030D17
            .onAppear {
                selectionStore.sync(to: viewModel.selectedVideoIds)
                selectionStore.syncFocus(to: viewModel.focusedVideoId)
                guard viewModel.scrollToSelectedOnViewSwitch else { return }
                viewModel.scrollToSelectedOnViewSwitch = false
                guard let id = viewModel.focusedVideoId ?? viewModel.lastSelectedVideoId ?? viewModel.selectedVideoIds.first,
                      let index = viewModel.filteredVideos.firstIndex(where: { $0.id == id }) else { return }
                let videos = viewModel.filteredVideos
                let cols = columnCount
                let rowIndex = index / cols
                let totalRows = (videos.count + cols - 1) / cols
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    viewModel.issueScrollCommand(.toRow(index: rowIndex, total: totalRows))
                }
            }
            .onChange(of: viewModel.selectedVideoIds) { _, newIds in
                selectionStore.sync(to: newIds)
            }
            .onChange(of: viewModel.focusedVideoId) { _, id in
                selectionStore.syncFocus(to: id)
                if let id { lastClickedId = id }
            }
            .onChange(of: viewModel.renamingVideoId) { _, id in
                if id != nil {
                    DispatchQueue.main.async { renameFocus = true }
                }
            }
            .onChange(of: viewModel.editingTitleVideoId) { _, id in
                if id != nil {
                    DispatchQueue.main.async { renameFocus = true }
                }
            }
            .onChange(of: viewModel.scrollToVideoId) { _, targetId in
                guard let id = targetId else { return }
                viewModel.scrollToVideoId = nil
                let videos = viewModel.filteredVideos
                guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
                let cols = columnCount
                let rowIndex = index / cols
                let totalRows = (videos.count + cols - 1) / cols
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    viewModel.issueScrollCommand(.toRow(index: rowIndex, total: totalRows))
                }
            }
            .onChange(of: cols, initial: true) { _, n in
                if Self.columns != n { Self.columns = n }
            }
            .onChange(of: viewModel.storyboardDensity) { _, _ in
                // Force column static refresh when density changes while Storyboard is active.
                if Self.columns != cols { Self.columns = cols }
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

    private struct AlbumSelectionGestures: ViewModifier {
        var enabled: Bool
        let onSelect: () -> Void
        let onPlay: () -> Void

        func body(content: Content) -> some View {
            if enabled {
                content
                    .onTapGesture(perform: onSelect)
                    .simultaneousGesture(TapGesture(count: 2).onEnded(onPlay))
            } else {
                content
            }
        }
    }


    /// Storyboard View: chrome clicks use full selection (incl. batch toggle); collage cells
    /// focus-only on first plain click, seek+play on a second while focused (modifier clicks collect).
    private struct StoryboardSelectionGestures: ViewModifier {
        var enabled: Bool
        let onSelect: () -> Void

        func body(content: Content) -> some View {
            if enabled {
                content.onTapGesture(perform: onSelect)
            } else {
                content
            }
        }
    }

    /// Storyboard collage: focus without batch-inspect toggle (collection membership unchanged).
    private func focusStoryboardCollage(_ video: Video) {
        viewModel.requestDefocusTextInputs()
        lastClickedId = video.id
        viewModel.setReviewFocus(video.id, retargetIfPlaying: false)
        selectionStore.syncFocus(to: video.id)
        // Focus ring rebuilds tracking areas; rebind hover under a still cursor (Esc path).
        DispatchQueue.main.async {
            PointerHitTesting.refreshHover()
        }
    }

    private func playStoryboardCell(_ video: Video, at location: CGPoint, size: CGSize) {
        // Seek+play only — do not touch the collected set (unlike exclusive select).
        viewModel.requestDefocusTextInputs()
        lastClickedId = video.id
        let duration = video.duration ?? 0
        let seconds = thumbnailService.storyboardClickSeconds(
            for: video.filePath,
            at: location,
            size: size,
            duration: duration
        )
        viewModel.setReviewFocus(video.id, retargetIfPlaying: false)
        if viewModel.isPlayingInline {
            // `isPlayingInline = true` would no-op; seek the live player instead.
            viewModel.playback.seek(toSeconds: seconds, resumePlayback: true)
        } else {
            viewModel.pendingFilmstripSeekSeconds = seconds
            viewModel.isPlayingInline = true
        }
    }
    private func handleSelection(_ video: Video, flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        viewModel.requestDefocusTextInputs()
        let optionOnly = flags.contains(.option)
            && !flags.contains(.command)
            && !flags.contains(.shift)
        if optionOnly {
            lastClickedId = video.id
            selectionStore.sync(to: [video.id])
            selectionStore.syncFocus(to: video.id)
            viewModel.selectOnly(video.id)
            return
        }
        if flags.contains(.command) {
            lastClickedId = video.id
            viewModel.toggleInCollectedSet(video.id)
            selectionStore.sync(to: viewModel.selectedVideoIds)
            return
        }
        // Shift range anchors on the last click (including ⌘-click), not review focus alone.
        let anchor = lastClickedId ?? viewModel.focusedVideoId
        if flags.contains(.shift), let anchor,
           let aIdx = viewModel.filteredVideos.firstIndex(where: { $0.id == anchor }),
           let idx = viewModel.filteredVideos.firstIndex(where: { $0.id == video.id }) {
            let range = min(aIdx, idx)...max(aIdx, idx)
            let rangeIds = Set(range.map { viewModel.filteredVideos[$0].id })
            viewModel.unionIntoCollectedSet(rangeIds, lastTouchedId: video.id)
            selectionStore.sync(to: viewModel.selectedVideoIds)
            selectionStore.syncFocus(to: nil)
            lastClickedId = video.id
            return
        }
        viewModel.applyPlainReviewClick(on: video.id, lastClickedId: &lastClickedId)
        selectionStore.syncFocus(to: viewModel.focusedVideoId)
    }

    @ViewBuilder
    private func collectedSetCheckmark(for video: Video) -> some View {
        if selectionStore.state(for: video.id).isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.appAccent)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .padding(12)
                .allowsHitTesting(false)
        }
    }

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

    /// Fraction (0...1) of the video already watched, per its saved resume position — drives the
    /// thin progress bar on the card thumbnail, Netflix/Hulu "continue watching" style. `nil` hides
    /// the bar (never played, or finished — the resume position is cleared in both those cases).
    private func resumeFraction(for video: Video) -> Double? {
        _ = viewModel.resumePositionsRevision // establishes the Observation dependency for re-renders
        guard let seconds = PlaybackPositionStore.loadSeconds(filePath: video.filePath),
              let duration = video.duration, duration > 0
        else { return nil }
        return min(max(seconds / duration, 0), 1)
    }

    private func play(_ video: Video) {
        NSWorkspace.shared.open(video.url)
        Task { await viewModel.recordPlay(for: video) }
    }

    /// Image drop → set that card’s poster. Video/folder drop → same library import as the browser pane.
    private func handleCardFileDrop(_ providers: [NSItemProvider], onto video: Video) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            let urls = await Self.loadFileURLs(from: providers)
            guard !urls.isEmpty else { return }
            if let imageURL = urls.first(where: \.isImageFile) {
                await viewModel.applyPosterImage(
                    from: imageURL,
                    to: [video],
                    thumbnailService: thumbnailService
                )
                return
            }
            await viewModel.importDroppedFiles(urls)
        }
        return true
    }

    private static func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: URL?.self, returning: [URL].self) { group in
            for provider in providers {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                            guard let data,
                                  let path = String(data: data, encoding: .utf8)?
                                    .trimmingCharacters(in: .whitespacesAndNewlines),
                                  let url = URL(string: path)
                            else {
                                continuation.resume(returning: nil)
                                return
                            }
                            continuation.resume(returning: url)
                        }
                    }
                }
            }
            var urls: [URL] = []
            for await url in group {
                if let url { urls.append(url) }
            }
            return urls
        }
    }

    /// URLs the "Open With" actions target: the whole selection when the clicked card is part of
    /// a multi-selection, else just the clicked video. Single pass over `filteredVideos` — and
    /// only ever called from a button action, never from the (eagerly evaluated) menu builder.
    private func openWithURLs(for video: Video) -> [URL] {
        let ids = viewModel.selectedVideoIds
        guard ids.count > 1, ids.contains(video.id) else { return [video.url] }
        return viewModel.filteredVideos.filter { ids.contains($0.id) }.map(\.url)
    }

    /// Which apps can open this video's file type — Launch Services, cached per extension in
    /// `OpenWithAppCache` (process-wide). Eager `.contextMenu` builders call this per visible card
    /// on every grid update; a miss fills the cache synchronously so the next card of the same
    /// type is free (async `@State` fill left every new extension re-querying LS for all cells).
    private func installedAppURLs(for video: Video) -> [URL] {
        let ext = video.url.pathExtension.lowercased()
        if let cached = OpenWithAppCache.byExtension[ext] { return cached }
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: video.url)
        OpenWithAppCache.byExtension[ext] = urls
        return urls
    }
}
