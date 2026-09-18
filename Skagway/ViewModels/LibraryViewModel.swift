import AppKit
import Foundation
import GRDB
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class LibraryViewModel {
    var videos: [Video] = [] {
        didSet {
            // Surgical field updates (e.g. subtitlePresence on play) assign `videos` but must not
            // cascade into counts / filter recompute / custom-metadata refresh — those are O(n).
            // Also skip the full path-index rebuild; callers update the one touched entry.
            if suppressVideosDidSet { return }
            rebuildVideosPathIndex()
            updateLibraryCounts()
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                refreshSearchIfActive()
            } else {
                recomputeFilteredVideos()
            }
            scheduleCollectionCountRefresh()
            scheduleListCustomMetadataRefresh()
        }
    }

    /// False until the first GRDB video observation delivery. Prevents the empty-library invite
    /// from flashing while a populated library is still loading asynchronously.
    private(set) var hasCompletedInitialVideoLoad = false

    /// Path → video for O(1) lookup. Rebuilt whenever `videos` is assigned. `@ObservationIgnored`
    /// so reading it during selection/play does not register extra observation edges.
    @ObservationIgnored private(set) var videosByPath: [String: Video] = [:]
    /// Path → index into `videos` for O(1) in-place mutations.
    @ObservationIgnored private var videoIndexByPath: [String: Int] = [:]
    /// Path → index into `filteredVideos` for O(1) filtered lookup.
    @ObservationIgnored private var filteredIndexByPath: [String: Int] = [:]
    /// When true, `videos` didSet skips the O(n) cascade and path-index rebuild.
    @ObservationIgnored private var suppressVideosDidSet = false
    /// Discard the next N GRDB observation deliveries (play-time subtitle writes would otherwise
    /// reload the entire library and re-trigger the O(n) cascade).
    @ObservationIgnored private var discardObservationDeliveries = 0

    /// O(1) library lookup by file path (`Video.id`).
    func video(forPath path: String) -> Video? {
        videosByPath[path]
    }

    /// O(1) filtered-set lookup by file path.
    func filteredVideo(forPath path: String) -> Video? {
        guard let idx = filteredIndexByPath[path] else { return nil }
        return filteredVideos[idx]
    }

    /// Resolve a set of paths to videos in filtered order. O(selection log selection), not O(library).
    func filteredVideos(forPaths paths: Set<String>) -> [Video] {
        guard !paths.isEmpty else { return [] }
        if paths.count == 1, let path = paths.first, let idx = filteredIndexByPath[path] {
            return [filteredVideos[idx]]
        }
        return paths.compactMap { path -> (Int, Video)? in
            guard let idx = filteredIndexByPath[path] else { return nil }
            return (idx, filteredVideos[idx])
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    private func rebuildVideosPathIndex() {
        var byPath: [String: Video] = [:]
        var indexByPath: [String: Int] = [:]
        byPath.reserveCapacity(videos.count)
        indexByPath.reserveCapacity(videos.count)
        for (idx, video) in videos.enumerated() {
            byPath[video.filePath] = video
            indexByPath[video.filePath] = idx
        }
        videosByPath = byPath
        videoIndexByPath = indexByPath
    }

    private func rebuildFilteredPathIndex() {
        var indexByPath: [String: Int] = [:]
        indexByPath.reserveCapacity(filteredVideos.count)
        for (idx, video) in filteredVideos.enumerated() {
            indexByPath[video.filePath] = idx
        }
        filteredIndexByPath = indexByPath
    }
    var tags: [Tag] = []
    var collections: [VideoCollection] = []
    var collectionCounts: [Int64: Int] = [:]
    var tagCounts: [Int64: Int] = [:]
    var tagsByVideoId: [Int64: [Tag]] = [:] {
        didSet {
            recomputeFilteredVideos()
            updateTagCounts()
        }
    }
    var searchText: String = "" {
        didSet { debouncedSearch() }
    }
    var tableSortOrder: [KeyPathComparator<Video>] = [KeyPathComparator(\Video.dateAdded, order: .reverse)] {
        didSet {
            // Any explicit sort action (column header click, sort menu) exits random order
            // and album playlist order.
            let wasRandomOrder = isRandomOrder
            let leavingAlbumOrder = isShowingAlbumOrder
            isRandomOrder = false
            defer {
                // The branches below only recompute when the *target* sort actually differs from
                // what was active before — correct when coming from a real sort, but exiting random
                // order (or album order) needs a re-sort even if the picked sort happens to match
                // whatever was active before (e.g. sorted by Name, shuffled, then clicked Name
                // again), since `filteredVideos` is still sitting in the stale shuffled/album order.
                // Deferred so it sees the branches' final state (e.g. `customSortFieldId`), not the
                // value present when this didSet started.
                if wasRandomOrder || leavingAlbumOrder { recomputeFilteredVideos() }
            }

            // Ignore programmatic updates from selectCustomSort (which sets a sentinel to show the caret)
            // and from loadPreferences (which must restore descending as saved).
            guard !_settingCustomSortOrder, !_loadingSortPreferences else { return }

            if isViewingAlbum {
                usesAlbumManualOrder = false
            }

            let ascending = tableSortOrder.first?.order == .forward

            // Custom column header click: sentinel keypath → sort by the corresponding custom field.
            if let slot = Video.customSortSlot(from: tableSortOrder.first?.keyPath) {
                let fields = allCustomFieldsForList
                guard slot < fields.count else { return }
                pendingScrollAfterSortId = selectedVideoIds.count == 1 ? selectedVideoIds.first : nil
                customSortAscending = ascending
                customSortFieldId = fields[slot].id  // didSet → recomputeFilteredVideos + savePreferences
                return
            }

            // Built-in column header click: clear any active custom sort.
            customSortFieldId = nil  // didSet may fire recomputeFilteredVideos if it was non-nil

            let oldSort = VideoSort.from(keyPath: oldValue.first?.keyPath ?? \Video.dateAdded)
            let newSort = VideoSort.from(keyPath: tableSortOrder.first?.keyPath ?? \Video.dateAdded)
            if oldSort != newSort, !ascending {
                tableSortOrder = newSort.comparators(ascending: true)
                return
            }
            guard oldSort != newSort || oldValue.first?.order != tableSortOrder.first?.order else { return }
            if selectedVideoIds.count > 1 {
                pendingScrollAfterSortId = nil
                selectedVideoIds = []
            } else if selectedVideoIds.count == 1 {
                pendingScrollAfterSortId = selectedVideoIds.first
            } else {
                pendingScrollAfterSortId = nil
            }
            recomputeFilteredVideos()
            savePreferences()
        }
    }

    /// Suppresses `tableSortOrder.didSet` side-effects while `selectCustomSort` updates the sentinel.
    @ObservationIgnored private var _settingCustomSortOrder = false
    /// Suppresses `tableSortOrder.didSet` while restoring prefs. Without this, loading a saved
    /// descending sort on a column other than the default triggers the Table-header heuristic
    /// that forces ascending when the sort *field* changes — so direction never survived relaunch.
    @ObservationIgnored private var _loadingSortPreferences = false

    /// UUID of the custom metadata field currently used for sorting; nil = built-in sort via `tableSortOrder`.
    private(set) var customSortFieldId: UUID? {
        didSet {
            guard oldValue != customSortFieldId else { return }
            isRandomOrder = false
            recomputeFilteredVideos()
            savePreferences()
        }
    }

    /// Sort direction for custom field sorts. Built-in sort direction lives in `tableSortOrder.first?.order`.
    var customSortAscending: Bool = true {
        didSet {
            guard customSortFieldId != nil, oldValue != customSortAscending else { return }
            isRandomOrder = false
            recomputeFilteredVideos()
            savePreferences()
        }
    }

    /// True while List/Wall show the library in a randomized order (triggered by the Shuffle
    /// button). Cleared by any explicit sort action (column header, sort menu, custom field) since
    /// those signal the user wants a real ordering again. Deliberately not persisted — like
    /// "Surprise Me", shuffling is a "for right now" action, not a durable preference.
    var isRandomOrder: Bool = false

    /// When viewing an album, show the album's playlist order instead of the library sort.
    /// Cleared by picking a sort from the menu / column header; restored by drag-reorder or
    /// choosing **Album Order**. Entering an album turns it back on.
    var usesAlbumManualOrder: Bool = true

    /// Per-video random rank backing the current shuffle, keyed by `filePath` (matches `Video.id`).
    /// Regenerated fresh on every `shuffleOrder()` call so the order stays *stable* across the many
    /// unrelated `recomputeFilteredVideos()` calls that happen during normal use (selection, tag
    /// edits, scans, etc.) — without this, "random" would reshuffle under the user on every render
    /// instead of just once per explicit Shuffle click.
    private var randomOrderRanks: [String: Double] = [:]

    /// Shuffle — assigns every video a fresh random rank and switches to random order. Safe to call
    /// repeatedly (e.g. clicking Shuffle again while already in random order just re-shuffles).
    func shuffleOrder() {
        var ranks: [String: Double] = [:]
        ranks.reserveCapacity(videos.count)
        for video in videos {
            ranks[video.filePath] = Double.random(in: 0..<1)
        }
        randomOrderRanks = ranks
        isRandomOrder = true
        recomputeFilteredVideos()
    }
    var viewMode: ViewMode = .grid {
        didSet {
            guard !_applyingLayout else { return }
            updateCurrentLayoutFromLive()
        }
    }
    var gridSize: GridSize = .medium {
        didSet {
            guard !_applyingLayout else { return }
            updateCurrentLayoutFromLive()
        }
    }
    var sidebarFilter: SidebarFilter? = .all {
        didSet {
            if case .collection(let collection) = sidebarFilter, collection.isAlbum {
                usesAlbumManualOrder = true
            }
            recomputeFilteredVideos()
            if case .missing = sidebarFilter, !isRefreshingMissing {
                Task { await refreshMissingCount() }
            }
        }
    }

    /// True when the Quick Filter sidebar is showing an Album.
    var isViewingAlbum: Bool {
        if case .collection(let collection) = sidebarFilter { return collection.isAlbum }
        return false
    }

    /// True when viewing an album, using its playlist order, and not shuffled.
    var isShowingAlbumOrder: Bool {
        isViewingAlbum && usesAlbumManualOrder && !isRandomOrder
    }

    var activeAlbum: VideoCollection? {
        if case .collection(let collection) = sidebarFilter, collection.isAlbum { return collection }
        return nil
    }
    var selectedTagIds: Set<Int64> = [] {
        didSet { recomputeFilteredVideos() }
    }
    var tagFilterMode: MatchMode = .all {
        didSet { recomputeFilteredVideos() }
    }
    /// Per-star rating filter (1...5); independent of `sidebarFilter`, like `selectedTagIds`.
    var selectedRatingStars: Set<Int> = [] {
        didSet { recomputeFilteredVideos() }
    }
    /// When true, the Quick Filter rating match is "this star or higher" instead of exact.
    /// Session-only, like the other Quick Filters — not persisted.
    var ratingFilterOrHigher: Bool = false {
        didSet {
            if ratingFilterOrHigher != oldValue {
                recomputeFilteredVideos()
            }
        }
    }

    /// Duration range filter (in seconds). nil means no bound. Live updates wall.
    var minDurationSeconds: Double? = nil {
        didSet { recomputeFilteredVideos() }
    }
    var maxDurationSeconds: Double? = nil {
        didSet { recomputeFilteredVideos() }
    }

    /// Quick Filter quality buckets (`ResolutionBucket` raw values). OR within the set — a video
    /// matches if its `resolutionLabel` is any selected bucket. Empty = inactive.
    var selectedQualityBuckets: Set<String> = [] {
        didSet { recomputeFilteredVideos() }
    }

    /// The live Advanced Filter boolean tree. Exclusive with Quick Filter (sidebar / rating /
    /// duration / quality / tags) — only one mode owns matching at a time. Compiled through the shared
    /// `FilterMatcher`. nil or an empty group means "no advanced filter". Session-only.
    var advancedFilterGroup: FilterGroup? {
        didSet { recomputeFilteredVideos() }
    }

    /// Bumped whenever `advancedFilterGroup` is loaded or cleared from outside the editor so the
    /// drawer remounts and reloads rules (the editor keeps local `@State` while the drawer is hidden).
    private(set) var advancedFilterEditorSessionID = UUID()

    var hasActiveAdvancedFilter: Bool {
        if let g = advancedFilterGroup, !g.isEmpty { return true }
        return false
    }

    /// Clears the live Advanced Filter (drawer Clear / pill ✕) and the Quick stack that
    /// compiled into it, so sidebar smart-library picks do not linger after dismissing Advanced.
    func clearAdvancedFilter() {
        collectionFilterPreview = nil
        clearQuickFilters()
        resetAdvancedFilterEditorSession()
        filtersDrawerMode = .quick
    }

    /// Clears Quick Filter state (sidebar, tags, rating, duration, quality). Does not touch
    /// `advancedFilterGroup` or search. Used when entering Advanced Filter mode.
    func clearQuickFilters() {
        sidebarFilter = .all
        selectedTagIds = []
        clearRatingFilter()
        minDurationSeconds = nil
        maxDurationSeconds = nil
        selectedQualityBuckets = []
    }

    /// Short human-readable summary of the active Advanced Filter, for the closed-drawer pill.
    /// `nil` when no advanced filter is active.
    var activeAdvancedFilterSummary: String? {
        guard let group = advancedFilterGroup, !group.isEmpty else { return nil }
        return FilterSummaryFormatter.filterGroupSummary(
            group,
            customFields: customMetadataFieldDefinitionsById,
            collections: collections
        )
    }

    /// Short summary of the active smart collection's rules (capped). `nil` for albums or empty rules.
    var activeCollectionFilterSummary: String? {
        guard case .collection(let collection) = sidebarFilter else { return nil }
        return collectionFilterSummary(for: collection)
    }

    /// Compact rule synopsis for a smart collection — used by pills and the Quick Filter drawer.
    func collectionFilterSummary(for collection: VideoCollection) -> String? {
        filterGroupSummary(for: collection, maxConditions: FilterSummaryFormatter.collectionSynopsisMaxConditions)
    }

    /// Closed-drawer pill label for a smart collection (`"Name: rule"` or `"Name: rule ..."`).
    func collectionFilterPillLabel(for collection: VideoCollection) -> String? {
        guard collection.isSmart,
              let group = filterGroup(for: collection),
              !group.isEmpty else { return nil }
        return FilterSummaryFormatter.labeledCollectionPillText(
            collectionName: collection.name,
            group: group,
            customFields: customMetadataFieldDefinitionsById,
            collections: collections
        )
    }

    private func filterGroup(for collection: VideoCollection) -> FilterGroup? {
        guard collection.isSmart, let collectionId = collection.id else { return nil }
        let groups = cachedCollectionRuleGroups[collectionId] ?? []
        let rules = cachedCollectionRules[collectionId] ?? []
        let rulesByGroup = Dictionary(grouping: rules, by: \.groupId)
        return CollectionRepository.filterGroup(
            for: collection,
            groups: groups,
            rulesByGroup: rulesByGroup
        )
    }

    private func filterGroupSummary(for collection: VideoCollection, maxConditions: Int?) -> String? {
        guard let group = filterGroup(for: collection) else { return nil }
        return FilterSummaryFormatter.filterGroupSummary(
            group,
            customFields: customMetadataFieldDefinitionsById,
            collections: collections,
            maxConditions: maxConditions
        )
    }

    private var customMetadataFieldDefinitionsById: [UUID: CustomMetadataFieldDefinition] {
        Dictionary(uniqueKeysWithValues: customMetadataFieldDefinitions.map { ($0.id, $0) })
    }

    /// Which body the shared filters drawer shows, and which filter stack owns matching.
    enum FiltersDrawerMode: String, Equatable {
        case quick
        case advanced
    }

    /// When set, the Advanced Filter drawer was opened from a collection pill for inspection.
    /// Closing the drawer without edits restores the collection Quick Filter instead of leaving
    /// an Advanced Filter pill active.
    private var collectionFilterPreview: (collection: VideoCollection, snapshot: FilterGroup)?

    /// Controls the top-descending filters drawer. Always forced closed on appearance (not
    /// persisted). Toggle via header Filter (⌘⇧F).
    var isCuratedWallFiltersDrawerOpen: Bool = false {
        didSet {
            if oldValue, !isCuratedWallFiltersDrawerOpen {
                restoreCollectionFilterPreviewIfUnchanged()
            }
        }
    }

    /// Quick vs Advanced tab — persisted; also selects which filter stack owns matching.
    var filtersDrawerMode: FiltersDrawerMode = .quick {
        didSet {
            guard oldValue != filtersDrawerMode else { return }
            UserDefaults.standard.set(filtersDrawerMode.rawValue, forKey: Self.filtersDrawerModeKey)
            if filtersDrawerMode == .advanced, oldValue == .quick {
                collectionFilterPreview = nil
                // Mirror Quick into Advanced on tab switch; empty Quick clears stale compiled rules.
                if !compileQuickFiltersIntoAdvanced() {
                    resetAdvancedFilterEditorSession()
                }
            }
            recomputeFilteredVideos()
        }
    }

    /// True when the drawer is open in Advanced Filter mode.
    var isAdvancedFilterDrawerOpen: Bool {
        isCuratedWallFiltersDrawerOpen && filtersDrawerMode == .advanced
    }

    /// Filter drawer (header button / ⌘⇧F). Opens in the last-used Quick/Advanced mode.
    func toggleFiltersDrawer() {
        isCuratedWallFiltersDrawerOpen.toggle()
    }

    /// Opens the filter drawer, optionally switching Quick/Advanced tab first.
    func openFiltersDrawer(mode: FiltersDrawerMode? = nil) {
        if let mode { filtersDrawerMode = mode }
        isCuratedWallFiltersDrawerOpen = true
    }

    /// User-adjustable, persisted height of the filters drawer (drag handle at its bottom edge).
    /// `ContentView` clamps the *displayed* height against the current window size — this stored
    /// value is the user's preference, not necessarily what's currently on screen.
    static let filtersDrawerMinHeight: CGFloat = 110   // ~1.5in — fits a card header + one row; 1in (72pt) cut off too much
    static let filtersDrawerDefaultHeight: CGFloat = 320
    var filtersDrawerHeight: CGFloat = LibraryViewModel.filtersDrawerDefaultHeight {
        didSet {
            UserDefaults.standard.set(Double(filtersDrawerHeight), forKey: Self.filtersDrawerHeightKey)
        }
    }
    /// Whether the filters drawer opens at its natural content height (and hides the resize handle)
    /// or at the last user-dragged height. See `FilterDrawerHeightMode`.
    var filterDrawerHeightMode: FilterDrawerHeightMode = .lastUsed {
        didSet {
            UserDefaults.standard.set(filterDrawerHeightMode.rawValue, forKey: Self.filterDrawerHeightModeKey)
        }
    }

    /// User-adjustable, persisted height of the Inspector's hero (thumbnail/filmstrip) area.
    /// No maximum — the Inspector body scrolls, so an oversized hero just pushes the rest of the
    /// panel's content down rather than overflowing. The compact floating player matches this
    /// height exactly (`FloatingPlayerPanel.compactSize`), so resizing the hero also resizes what
    /// "Compact" playback snaps to.
    static let inspectorHeroMinHeight: CGFloat = 72   // 1in
    static let inspectorHeroDefaultHeight: CGFloat = 220
    var inspectorHeroHeight: CGFloat = LibraryViewModel.inspectorHeroDefaultHeight {
        didSet {
            UserDefaults.standard.set(Double(inspectorHeroHeight), forKey: Self.inspectorHeroHeightKey)
        }
    }
    /// Live value while the hero's resize handle is actively being dragged — deliberately *not*
    /// persisted (no `didSet`/`UserDefaults` write), so dragging stays cheap. Shared on the view
    /// model (not local `@State` on the Inspector) specifically so the compact floating player —
    /// a separate view — can track the resize in realtime instead of only snapping to the new size
    /// once the drag ends and `inspectorHeroHeight` commits. `nil` outside an active drag.
    var inspectorHeroLiveHeight: CGFloat?

    /// User-owned Inspector chrome (View menu / toolbar / ⌘I). Default on. Hide does **not**
    /// write a zero detail width — show restores the last dragged Inspector width.
    var isInspectorVisible: Bool = true {
        didSet {
            guard isInspectorVisible != oldValue else { return }
            UserDefaults.standard.set(isInspectorVisible, forKey: Self.inspectorVisibleKey)
        }
    }

    func toggleInspectorVisible() {
        // Capture viewport pin *before* width/columns change, then restore after layout so the
        // focused clip stays at the same on-screen position across show ↔ hide (no ⌘J jump).
        let pin = browserScrollPinStore.pin
        isInspectorVisible.toggle()
        guard let pin else { return }
        pendingBrowserScrollPinRestore = pin
        browserScrollPinRestoreToken &+= 1
    }

    /// Header collection pill: show Inspector at last width, in batch-inspect mode.
    func revealInspectorForCollectedSet() {
        guard selectedVideoIds.count > 1 else { return }
        activateBatchInspectIfMultiCollected()
        if !isInspectorVisible {
            isInspectorVisible = true
            scrollToSelected()
        }
    }

    /// Live viewport pin for the focused / selected clip (updated by `BrowserScrollPinController`).
    /// Not `@Observable`-tracked — mutated in place so scroll tracking does not thrash the UI.
    let browserScrollPinStore = BrowserScrollPinStore()

    /// Set just before an Inspector width change; consumed by the browser scroll pin controller.
    var pendingBrowserScrollPinRestore: BrowserScrollPinStore.Pin?
    private(set) var browserScrollPinRestoreToken: Int = 0

    var ffmpegUserPath: String = "" {
        didSet { UserDefaults.standard.set(ffmpegUserPath, forKey: Self.ffmpegPathKey) }
    }

    /// The ffmpeg binary to use: user-configured path first, then standard Homebrew/system locations.
    var resolvedFFmpegPath: String? {
        if !ffmpegUserPath.isEmpty {
            return FileManager.default.isExecutableFile(atPath: ffmpegUserPath) ? ffmpegUserPath : nil
        }
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var thumbnailsSettled: Bool = true

    var isScanning: Bool = false {
        didSet {
            if isScanning && !oldValue {
                thumbnailsSettled = false
            } else if !isScanning && oldValue {
                startThumbnailSettlingTask()
            }
        }
    }
    var scanProgress: String = ""
    var scanCurrent: Int = 0
    var scanTotal: Int = 0

    /// Surfaces a transient failure in the activity strip (same channel as scan progress/errors),
    /// auto-clearing after a few seconds unless a newer message has since replaced it.
    func reportTransientError(_ message: String) {
        let text = "Error: \(message)"
        scanProgress = text
        Task { [text] in
            try? await Task.sleep(for: .seconds(4))
            if scanProgress == text { scanProgress = "" }
        }
    }
    var selectedVideoIds: Set<String> = []
    var lastSelectedVideoId: String?
    /// Clip being reviewed (player + Inspector). May sit outside `selectedVideoIds`.
    /// Any assignment (grid plain click, list table selection, setReviewFocus, etc.) re-evaluates
    /// the Library folder missing banner — do not set focus without going through this property.
    var focusedVideoId: String? {
        didSet {
            if let focusedVideoId {
                noteMissingClipFocusIfNeeded(path: focusedVideoId)
            }
        }
    }

    var inspectorIsSetMode: Bool {
        guard selectedVideoIds.count > 1 else { return false }
        return focusedVideoId == nil
    }

    var inspectorActionIds: Set<String> {
        if inspectorIsSetMode { return selectedVideoIds }
        if let focusedVideoId { return [focusedVideoId] }
        return selectedVideoIds
    }

    var reviewVideoId: String? {
        if inspectorIsSetMode {
            if let lastSelectedVideoId, selectedVideoIds.contains(lastSelectedVideoId) {
                return lastSelectedVideoId
            }
            return selectedVideoIds.first
        }
        return focusedVideoId ?? lastSelectedVideoId ?? selectedVideoIds.first
    }
    var filmstripRefreshId: Int = 0

    /// The single shared inline-playback engine. One player instance backs the resizable player
    /// surface (in-window panel and the borderless full-screen window).
    @ObservationIgnored private(set) lazy var playback = InlinePlaybackController(viewModel: self)

    /// Bumped whenever a resume position is saved or cleared (`InlinePlaybackController`). Grid
    /// cards read this to know when to recompute their resume-progress bar — `PlaybackPositionStore`
    /// itself isn't `@Observable`, so this is what makes the read reactive.
    private(set) var resumePositionsRevision: Int = 0
    func notifyResumePositionsChanged() {
        resumePositionsRevision &+= 1
    }

    /// Bookmarks for the currently inspected single selection (empty when multi/none).
    private(set) var bookmarksForSelection: [VideoBookmark] = []
    /// Bookmarks for the video currently in the player (timeline ticks); may differ from selection.
    private(set) var bookmarksForPlayback: [VideoBookmark] = []
    /// Bumped when bookmark rows change so Inspector rows refresh reliably.
    private(set) var bookmarksRevision: Int = 0
    private func notifyBookmarksChanged() {
        bookmarksRevision &+= 1
    }

    /// After create, Inspector focuses this bookmark’s title field so it’s obvious you can rename.
    var pendingBookmarkTitleFocusId: Int64?

    /// Bumped when the floating player overlay dismisses so Storyboard seek gestures remount
    /// (stale hover/hit-testing after Esc under a stationary cursor).
    private(set) var browserPointerRefreshToken: Int = 0

    func notePlaybackOverlayDismissed() {
        browserPointerRefreshToken &+= 1
    }

    /// True while a video is playing in the resizable player. The player never reshapes the wall, so
    /// this no longer needs a layout didSet (the full-screen-exit grid repaint lives in ContentView).
    var isPlayingInline: Bool = false {
        didSet {
            if oldValue && !isPlayingInline {
                isPlayAllSession = false
                notePlaybackOverlayDismissed()
            }
        }
    }
    /// Set before `isPlayingInline = true` on filmstrip tap; consumed when creating the inline player (Space leaves nil → start at 0).
    var pendingFilmstripSeekSeconds: Double?
    /// Set before `isPlayingInline = true` on ⌥-Space ("Play from Beginning"); consumed when creating the player to skip the saved resume position.
    var pendingIgnoreResumeOnNextStart: Bool = false
    var pendingAutoPlay: Bool = false
    /// True while queue-advancing so the Inspector's selection-change handler does not stop playback.
    var isAdvancingPlayAllQueue: Bool = false
    /// Play All session: auto-advance and loop apply only while this is true.
    var isPlayAllSession: Bool = false
    /// Bumped when the inline player instance is replaced (playlist advance) so full-screen can retarget.
    private(set) var playbackItemEpoch: Int = 0
    func notifyPlaybackItemChanged() {
        playbackItemEpoch &+= 1
    }
    var isEditingText: Bool = false
    var renamingVideoId: String?
    var renameText: String = ""
    /// Inline edit of library title (does not rename the file on disk).
    var editingTitleVideoId: String?
    var titleEditText: String = ""
    var renamingTagId: Int64?
    var tagRenameText: String = ""
    var scrollToVideoId: String?
    var scrollToSelectedOnViewSwitch: Bool = false

    /// Imperative top/bottom/page scroll requests from the list/grid nav bar. The token de-dupes so the
    /// handler fires once per press and ignores its own replays on view re-mount / SwiftUI re-render.
    struct ScrollCommand: Equatable {
        enum Kind: Equatable {
            case top, bottom, pageUp, pageDown
            /// Jump so row `index` of `total` rows is revealed with minimal scroll — used to restore
            /// the selection on a List→Grid switch without SwiftUI instantiating every intermediate cell.
            case toRow(index: Int, total: Int)
            /// After Inspector show/hide, place row `index` so its midY sits `offsetFromVisibleTop`
            /// points below the visible top — same on-screen slot as before the width change.
            case pinRow(index: Int, total: Int, offsetFromVisibleTop: CGFloat)
            /// Force the scroll view to re-tile its visible cells *without* changing position — repaints a
            /// grid/list revealed after the edge-to-edge fullscreen player closes (occlusion can blank cells).
            case retile
        }
        let token: Int
        let kind: Kind
    }
    private(set) var scrollCommand: ScrollCommand?
    private var scrollCommandToken: Int = 0

    func issueScrollCommand(_ kind: ScrollCommand.Kind) {
        scrollCommandToken += 1
        scrollCommand = ScrollCommand(token: scrollCommandToken, kind: kind)
    }

    /// Bumped by the ⌘F global key monitor to request search-field focus. The FocusState it drives
    /// lives in ContentView, so this token bridges the same way `scrollCommand` does for scroll requests.
    private(set) var focusSearchFieldToken: Int = 0
    /// Mirrored from ContentView `@FocusState` so the key monitor can tell library search apart
    /// from Inspector text fields (which should keep arrow-key caret navigation).
    var isLibrarySearchFocused = false
    /// Bumped to resign library search, Inspector text fields, and other inputs so Space / arrow
    /// keys reach the browser again after the user selects a clip in the grid or list.
    private(set) var defocusTextInputsToken: Int = 0

    func requestFocusSearchField() {
        focusSearchFieldToken += 1
    }

    func requestDefocusTextInputs() {
        isLibrarySearchFocused = false
        isEditingText = false
        defocusTextInputsToken += 1
    }

    func requestDefocusSearchField() {
        requestDefocusTextInputs()
    }

    /// Set by renameVideo when sorted by name; consumed by applyFilteredVideos to scroll in same cycle as bump.
    var pendingScrollToAfterRename: String?
    /// Set when sort changes with exactly one selected row; consumed in `applyFilteredVideos` to scroll after reorder.
    private var pendingScrollAfterSortId: String?
    var pendingDeleteIds: Set<String> = []
    var showDeleteConfirmation: Bool = false

    // MARK: - Album name prompts

    enum AlbumNamePrompt: Identifiable, Equatable {
        case createFromSelection(Set<String>)
        case createEmpty
        case rename(VideoCollection)

        var id: String {
            switch self {
            case .createFromSelection: return "createFromSelection"
            case .createEmpty: return "createEmpty"
            case .rename(let c): return "rename-\(c.id ?? 0)"
            }
        }

        var title: String {
            switch self {
            case .createFromSelection: return "New Album from Selection"
            case .createEmpty: return "New Album"
            case .rename: return "Rename Album"
            }
        }

        var message: String {
            switch self {
            case .createFromSelection: return "Creates an album containing the selected videos."
            case .createEmpty: return "Creates an empty album. Add videos from the context menu."
            case .rename: return "Enter a new name for this album."
            }
        }
    }

    var albumNamePrompt: AlbumNamePrompt? = nil
    var albumNameDraft: String = ""

    func presentNewAlbumFromSelection(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        albumNameDraft = ""
        albumNamePrompt = .createFromSelection(paths)
    }

    func presentNewEmptyAlbum() {
        albumNameDraft = ""
        albumNamePrompt = .createEmpty
    }

    func presentRenameAlbum(_ album: VideoCollection) {
        guard album.isAlbum else { return }
        albumNameDraft = album.name
        albumNamePrompt = .rename(album)
    }

    func confirmAlbumNamePrompt() {
        let draft = albumNameDraft
        let prompt = albumNamePrompt
        albumNamePrompt = nil
        albumNameDraft = ""
        guard let prompt else { return }
        Task {
            switch prompt {
            case .createFromSelection(let paths):
                _ = await createAlbum(name: draft, fromVideoPaths: paths)
            case .createEmpty:
                _ = await createEmptyAlbum(name: draft)
            case .rename(let album):
                await renameCollection(album, to: draft)
            }
        }
    }

    // MARK: - Metadata export

    /// Non-nil while the Export Metadata sheet is presented. Scope is fixed by the entry point.
    var metadataExportPresentation: MetadataExportPresentation? = nil
    var metadataExportProgress: (current: Int, total: Int)? = nil
    var metadataExportErrorMessage: String? = nil
    private var metadataExportTask: Task<Void, Never>?

    private static let metadataExportFormatKey = "Skagway.metadataExportFormat"
    private static let metadataExportColumnOrderKey = "Skagway.metadataExportColumnOrder"
    private static let metadataExportIncludedColumnsKey = "Skagway.metadataExportIncludedColumns"

    struct MetadataExportPresentation: Identifiable, Equatable {
        let id = UUID()
        let scope: MetadataExportScope
        let videoCount: Int
    }

    func presentExportMetadata(scope: MetadataExportScope) {
        let videos = videosForMetadataExport(scope: scope)
        guard !videos.isEmpty else { return }
        metadataExportErrorMessage = nil
        metadataExportProgress = nil
        metadataExportPresentation = MetadataExportPresentation(scope: scope, videoCount: videos.count)
    }

    // MARK: - Bulk rename

    /// Non-nil while the Bulk Rename sheet is presented.
    var bulkRenamePresentation: BulkRenamePresentation? = nil
    /// Non-nil while a bulk rename apply is in progress.
    var bulkRenameProgress: BulkRenameApplyProgress? = nil
    /// Set while applying; checked between files so Cancel can stop the batch.
    private var bulkRenameCancelRequested = false

    enum BulkRenameApplyProgress: Equatable {
        case preparing(current: Int, total: Int)
        case finishing(current: Int, total: Int)
        case rollingBack(current: Int, total: Int)

        var current: Int {
            switch self {
            case .preparing(let c, _), .finishing(let c, _), .rollingBack(let c, _): return c
            }
        }

        var total: Int {
            switch self {
            case .preparing(_, let t), .finishing(_, let t), .rollingBack(_, let t): return t
            }
        }

        var statusText: String {
            switch self {
            case .preparing(let c, let t):
                return "Preparing \(c) of \(t)…"
            case .finishing(let c, let t):
                return "Renaming \(c) of \(t)…"
            case .rollingBack(let c, let t):
                return "Restoring \(c) of \(t)…"
            }
        }
    }

    struct BulkRenameFailure: Identifiable, Equatable {
        let id: String
        let currentFileName: String
        let proposedFileName: String
        let reason: String
        let videoDatabaseId: Int64?
    }

    /// Outcome of one apply pass — shown in the Bulk Rename sheet (no silent dismiss).
    struct BulkRenameApplyResult: Equatable {
        var renamedCount: Int
        var failed: [BulkRenameFailure]
        var wasCancelled: Bool
        var restoredCount: Int

        var hasFailures: Bool { !failed.isEmpty }
    }

    private static let bulkRenamePatternKey = PrefsKeys.bulkRenamePattern
    private static let bulkRenameTempPrefix = ".skagway-bulk-"

    struct BulkRenamePresentation: Identifiable, Equatable {
        let id = UUID()
        let scope: MetadataExportScope
        let videoCount: Int
    }

    // MARK: - Location Relink

    /// Non-nil while the Location Relink sheet is presented.
    var locationRelinkPresentation: LocationRelinkPresentation? = nil
    /// Last successful apply — powers Edit → Undo Repair Links.
    private(set) var locationRelinkUndo: LocationRelinkUndoPayload? = nil
    var isApplyingLocationRelink: Bool = false
    /// Determinate progress while Repair Links is running (`nil` when idle).
    private(set) var locationRelinkProgress: LocationRelinkApplyProgress? = nil

    struct LocationRelinkApplyProgress: Equatable {
        enum Phase: String, Equatable {
            case updatingPaths = "Updating paths"
            case updatingFolders = "Updating library folders"
            case movingThumbnails = "Moving thumbnails"
            case updatingLibrary = "Updating library"
            case checkingMissing = "Checking missing"
        }

        var phase: Phase
        var current: Int
        var total: Int

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(current) / Double(total))
        }

        var statusText: String {
            if total > 0 {
                return "\(phase.rawValue)… \(current)/\(total)"
            }
            return "\(phase.rawValue)…"
        }
    }

    struct LocationRelinkPresentation: Identifiable, Equatable {
        let id = UUID()
    }

    struct LocationRelinkUndoPayload: Equatable {
        var oldRoot: String
        var newRoot: String
        /// Applied newPath → oldPath (for undo).
        var reverseMappings: [(from: String, to: String, videoId: Int64)]
        var appliedCount: Int

        static func == (lhs: LocationRelinkUndoPayload, rhs: LocationRelinkUndoPayload) -> Bool {
            lhs.oldRoot == rhs.oldRoot
                && lhs.newRoot == rhs.newRoot
                && lhs.appliedCount == rhs.appliedCount
                && lhs.reverseMappings.map { "\($0.from)|\($0.to)|\($0.videoId)" }
                    == rhs.reverseMappings.map { "\($0.from)|\($0.to)|\($0.videoId)" }
        }
    }

    /// Shared missing folder when Missing has been scanned — quiet repair cue input.
    var inferredMissingLibraryRoot: String? {
        guard missingCountScanned, !missingVideoIds.isEmpty else { return nil }
        return LocationRelink.inferSharedMissingRoot(
            missingPaths: Array(missingVideoIds),
            dataSourceRoots: []
        )
    }

    /// True after focusing a missing clip — shows the Library folder missing banner outside the Missing filter.
    /// Idempotent: stays on across repeated missing clicks (no flicker / re-stack).
    private(set) var showRepairLinksBannerFromMissingClick: Bool = false
    /// Preferred old Location for Repair Links when opened from the banner (click or Missing filter).
    private(set) var repairLinksBannerPreferredRoot: String? = nil
    /// True while a focus-triggered full missing scan is pending/running (banner shows “Checking…”).
    private(set) var isMissingBannerScanPending: Bool = false

    /// Banner visibility: Missing filter with misses, or a missing clip was focused.
    var shouldShowLibraryFolderMissingBanner: Bool {
        showRepairLinksBannerFromMissingClick
            || (sidebarFilter == .missing && missingCountScanned && !missingVideoIds.isEmpty)
    }

    /// Preferred root for the banner’s Reconnect… button.
    var libraryFolderMissingBannerPreferredRoot: String? {
        repairLinksBannerPreferredRoot ?? inferredMissingLibraryRoot
    }

    /// Situational banner classification (parent gone / parent present / scattered).
    /// Count for parentPresent is always the full `missingVideoIds` set.
    var libraryFolderMissingBannerSituation: LocationRelink.MissingBannerSituation {
        let paths = Array(missingVideoIds)
        let focus: String? = showRepairLinksBannerFromMissingClick ? focusedVideoId : nil
        return LocationRelink.classifyMissingSituation(
            missingPaths: paths.isEmpty && focus != nil ? [focus!] : paths,
            focusPath: focus
        )
    }

    /// Exact customer-facing banner copy for the current situation.
    /// While a full missing scan is in flight after focusing an orphan, show “Checking…”.
    var libraryFolderMissingBannerCopy: LocationRelink.BannerCopy {
        if showRepairLinksBannerFromMissingClick
            && (isRefreshingMissing || isMissingBannerScanPending)
        {
            return LocationRelink.bannerCopyChecking
        }
        return LocationRelink.bannerCopy(for: libraryFolderMissingBannerSituation)
    }

    /// Missing-clip count for Reconnect Destinations UI (avoids exposing private set).
    var reconnectMissingClipCount: Int { missingVideoIds.count }

    /// Sample basenames for the Destinations missing-set summary.
    var reconnectMissingSampleNames: [String] {
        Array(
            missingVideoIds
                .prefix(8)
                .map { URL(fileURLWithPath: $0).lastPathComponent }
        )
    }

    /// Async variant that also considers Data Source roots.
    func resolveSharedMissingRoot() async -> String? {
        if !missingCountScanned && missingVideoIds.isEmpty {
            await refreshMissingCount()
        }
        let sources = (try? await dataSourceRepo.fetchAll()) ?? []
        return LocationRelink.inferSharedMissingRoot(
            missingPaths: Array(missingVideoIds),
            dataSourceRoots: sources.map(\.folderPath)
        )
    }

    /// Known Location A options from catalog paths + data sources (never a filesystem picker).
    /// Heavy path-prefix work runs off the main actor so opening Repair Links stays responsive.
    func locationRelinkOldRootCandidates(
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> [LocationRelink.OldRootCandidate] {
        let sources = (try? await dataSourceRepo.fetchAll()) ?? []
        let sourcePaths = sources.map(\.folderPath)
        // Snapshot paths on the main actor, then leave immediately for the detached collect.
        let videoPaths = videos.map(\.filePath)
        return await Task.detached(priority: .userInitiated) {
            LocationRelink.collectOldRootCandidates(
                videoPaths: videoPaths,
                dataSourceRoots: sourcePaths,
                onProgress: onProgress
            )
        }.value
    }

    /// Opens the unified Reconnect sheet (Evidence Destinations). Refreshes the full missing
    /// set so the sheet covers every missing clip. Banner and File → Reconnect… share this entry.
    func beginLocationRelink(
        preferredOldRoot: String? = nil,
        initialMode: LocationRelink.ReconnectMode? = nil,
        startAtNewFolder: Bool = false
    ) {
        // preferredOldRoot / initialMode / startAtNewFolder kept for call-site compatibility;
        // UI is Destinations-only (no Whole folder tab).
        _ = preferredOldRoot
        _ = initialMode
        _ = startAtNewFolder
        guard locationRelinkPresentation == nil else { return }
        guard !isApplyingLocationRelink else { return }
        locationRelinkPresentation = LocationRelinkPresentation()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshMissingCount()
            }
        }
    }

    /// Banner CTA — same Reconnect product; awaits a full missing scan first so the sheet
    /// opens already scoped to every missing clip.
    func beginReconnectFromBanner() {
        guard locationRelinkPresentation == nil else { return }
        guard !isApplyingLocationRelink else { return }
        Task { @MainActor in
            await refreshMissingCount()
            guard locationRelinkPresentation == nil else { return }
            beginLocationRelink()
        }
    }

    /// Pick an Evidence Destination folder.
    func pickEvidenceDestination() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder that contains some of the missing clips"
        panel.prompt = "Add Destination"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return LocationRelink.normalizeRoot(url.path)
    }

    /// Index video files under a user-chosen Evidence Destination (bounded, local only).
    func indexEvidenceDestination(at path: String) async -> LocationRelink.DestinationIndex {
        let root = LocationRelink.normalizeRoot(path)
        let extensions = VideoExtensionManager.shared.enabledExtensions
        return await Task.detached(priority: .userInitiated) {
            if extensions.isEmpty {
                return LocationRelink.indexEvidenceDestination(root: root)
            }
            return LocationRelink.indexEvidenceDestination(
                root: root,
                videoExtensions: extensions
            )
        }.value
    }

    /// Session preview: optional whole-folder remap + Evidence Destination basename matches.
    /// When destinations are present, scopes unmatched work to currently missing clips
    /// (plus anything under the whole-folder old root).
    func buildReconnectSessionPreview(
        wholeFolder: (oldRoot: String, newRoot: String)?,
        destinationIndexes: [LocationRelink.DestinationIndex]
    ) -> LocationRelink.Preview {
        let existing = Set(videos.map(\.filePath))
        var scoped = videos
        if !missingVideoIds.isEmpty {
            let missing = missingVideoIds
            if let old = wholeFolder?.oldRoot, !old.isEmpty {
                scoped = videos.filter {
                    missing.contains($0.filePath)
                        || LocationRelink.isUnder(root: old, path: $0.filePath)
                }
            } else {
                scoped = videos.filter { missing.contains($0.filePath) }
            }
        } else if let old = wholeFolder?.oldRoot, !old.isEmpty {
            scoped = videos.filter { LocationRelink.isUnder(root: old, path: $0.filePath) }
        }
        let tuples = scoped.map {
            (databaseId: $0.databaseId, filePath: $0.filePath, fileSize: $0.fileSize)
        }
        return LocationRelink.buildSessionPreview(
            videos: tuples,
            wholeFolder: wholeFolder,
            destinationIndexes: destinationIndexes,
            existingLibraryPaths: existing
        )
    }

    /// Banner / legacy Find missing entry — opens the unified Reconnect sheet (same product).
    func beginFindMissingFile(for orphanPath: String? = nil) {
        if let orphan = orphanPath {
            noteLibraryFileMissing(path: orphan)
            updateRepairLinksBannerPreferredRoot(forMissingPath: orphan)
        }
        beginReconnectFromBanner()
    }

    func buildLocationRelinkPreview(oldRoot: String, newRoot: String) -> LocationRelink.Preview {
        let old = LocationRelink.normalizeRoot(oldRoot)
        let videosUnder = videos
            .filter { LocationRelink.isUnder(root: old, path: $0.filePath) }
            .map { (databaseId: $0.databaseId, filePath: $0.filePath, fileSize: $0.fileSize) }
        let existing = Set(videos.map(\.filePath))
        return LocationRelink.buildPreview(
            videos: videosUnder,
            oldRoot: old,
            newRoot: newRoot,
            existingLibraryPaths: existing
        )
    }

    /// Apply reconnect (and optionally flagged) mappings.
    /// Progress covers every phase through missing refresh — bar reaches 100% only when Done-ready.
    /// Identical old/new roots are allowed; thumb renames are skipped when paths are unchanged.
    @discardableResult
    func applyLocationRelink(
        preview: LocationRelink.Preview,
        includeNeedsAttention: Bool
    ) async -> Int {
        let mappings = LocationRelink.mappingsToApply(
            preview: preview,
            includeNeedsAttention: includeNeedsAttention
        )
        guard !mappings.isEmpty else { return 0 }
        isApplyingLocationRelink = true
        let total = mappings.count
        defer {
            isApplyingLocationRelink = false
            locationRelinkProgress = nil
        }

        let dbMappings: [(videoId: Int64, newFilePath: String)] = mappings.compactMap { m in
            guard let id = m.videoDatabaseId else { return nil }
            return (id, m.newPath)
        }
        guard dbMappings.count == mappings.count else {
            reportTransientError("Couldn't reconnect — some clips are missing a library id")
            return 0
        }

        // Phase 1 — DB path updates
        locationRelinkProgress = LocationRelinkApplyProgress(
            phase: .updatingPaths, current: 0, total: total
        )
        do {
            let chunkSize = 40
            var done = 0
            while done < dbMappings.count {
                let end = min(done + chunkSize, dbMappings.count)
                try await videoRepo.relinkFilePaths(mappings: Array(dbMappings[done..<end]))
                done = end
                locationRelinkProgress = LocationRelinkApplyProgress(
                    phase: .updatingPaths, current: done, total: total
                )
                await Task.yield()
            }
        } catch {
            reportTransientError("Couldn't reconnect: \(error.localizedDescription)")
            return 0
        }

        // Phase 2 — data sources / excludes (whole-folder remount only)
        locationRelinkProgress = LocationRelinkApplyProgress(
            phase: .updatingFolders, current: 0, total: 2
        )
        if preview.hasWholeFolderRemap {
            _ = try? await dataSourceRepo.remapPathsUnder(
                oldRoot: preview.oldRoot,
                newRoot: preview.newRoot
            )
            locationRelinkProgress = LocationRelinkApplyProgress(
                phase: .updatingFolders, current: 1, total: 2
            )
            let excludeRepo = ExcludedFolderRepository(dbPool: dbPool)
            _ = try? await excludeRepo.remapPathsUnder(
                oldRoot: preview.oldRoot,
                newRoot: preview.newRoot
            )
        }
        locationRelinkProgress = LocationRelinkApplyProgress(
            phase: .updatingFolders, current: 2, total: 2
        )
        await Task.yield()

        let pathPairs = mappings.map { (from: $0.oldPath, to: $0.newPath) }
        let changedPairs = pathPairs.filter { $0.from != $0.to }

        // Phase 3 — thumb/filmstrip cache (one directory listing; skip same-path)
        if changedPairs.isEmpty {
            locationRelinkProgress = LocationRelinkApplyProgress(
                phase: .movingThumbnails, current: 0, total: 0
            )
        } else {
            locationRelinkProgress = LocationRelinkApplyProgress(
                phase: .movingThumbnails, current: 0, total: changedPairs.count
            )
            let progressBox = RelinkThumbProgressBox()
            let thumbService = thumbnailService
            let migrateTask = Task.detached(priority: .userInitiated) {
                thumbService.migrateCacheKeys(changedPairs) { current, _ in
                    progressBox.set(current)
                }
            }
            var migrateFinished = false
            while !migrateFinished {
                locationRelinkProgress = LocationRelinkApplyProgress(
                    phase: .movingThumbnails,
                    current: progressBox.get(),
                    total: changedPairs.count
                )
                migrateFinished = await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(50))
                        return false
                    }
                    group.addTask {
                        _ = await migrateTask.value
                        return true
                    }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
            }
            locationRelinkProgress = LocationRelinkApplyProgress(
                phase: .movingThumbnails, current: changedPairs.count, total: changedPairs.count
            )
        }
        await Task.yield()

        // Phase 4a — in-memory bookkeeping (+ thumbnailPath remap onto new cache keys)
        locationRelinkProgress = LocationRelinkApplyProgress(
            phase: .updatingLibrary, current: 0, total: 1
        )
        let pathMap = Dictionary(uniqueKeysWithValues: pathPairs.map { ($0.from, $0.to) })
        var thumbPathUpdates: [(videoId: Int64, path: String)] = []
        var updated = videos
        for i in updated.indices {
            guard let neu = pathMap[updated[i].filePath], neu != updated[i].filePath else { continue }
            let remappedThumb = thumbnailService.remappedThumbnailPath(
                updated[i].thumbnailPath,
                newFilePath: neu
            )
            updated[i].filePath = neu
            if let remappedThumb {
                updated[i].thumbnailPath = remappedThumb
                if let dbId = updated[i].databaseId {
                    thumbPathUpdates.append((dbId, remappedThumb))
                }
            }
        }
        videos = updated
        if !thumbPathUpdates.isEmpty {
            try? await videoRepo.updateThumbnailPaths(updates: thumbPathUpdates)
        }

        for (old, neu) in pathMap where old != neu {
            remapVideoPathInSelection(from: old, to: neu)
        }
        let positionRemaps = pathPairs.filter { $0.from != $0.to }
        if !positionRemaps.isEmpty {
            PlaybackPositionStore.remapPaths(positionRemaps)
            notifyResumePositionsChanged()
        }

        recentlyAppliedPaths = Set(recentlyAppliedPaths.map { pathMap[$0] ?? $0 })
        lastAddedPaths = Set(lastAddedPaths.map { pathMap[$0] ?? $0 })

        locationRelinkUndo = LocationRelinkUndoPayload(
            oldRoot: preview.oldRoot,
            newRoot: preview.newRoot,
            reverseMappings: mappings.compactMap { m in
                guard let id = m.videoDatabaseId else { return nil }
                return (from: m.newPath, to: m.oldPath, videoId: id)
            },
            appliedCount: mappings.count
        )
        // Refresh grid/list immediately — don't wait for the missing scan. Cache files already
        // moved off the old hashes; filtered rows must use new paths + busted thumbnailPath now.
        if !changedPairs.isEmpty {
            filmstripRefreshId &+= 1
            filteredVideosVersion &+= 1
        }
        recomputeFilteredVideos()
        locationRelinkProgress = LocationRelinkApplyProgress(
            phase: .updatingLibrary, current: 1, total: 1
        )
        await Task.yield()

        // Phase 4b — missing refresh with clip progress
        let snapshot = videos
        let missingTotal = snapshot.count
        locationRelinkProgress = LocationRelinkApplyProgress(
            phase: .checkingMissing, current: 0, total: max(missingTotal, 1)
        )
        var missIds = Set<String>()
        let missChunk = 250
        var missDone = 0
        while missDone < snapshot.count {
            let end = min(missDone + missChunk, snapshot.count)
            let slice = Array(snapshot[missDone..<end])
            let chunkMiss = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                return Set(slice.filter { !fm.fileExists(atPath: $0.filePath) }.map(\.id))
            }.value
            missIds.formUnion(chunkMiss)
            missDone = end
            locationRelinkProgress = LocationRelinkApplyProgress(
                phase: .checkingMissing, current: missDone, total: missingTotal
            )
            await Task.yield()
        }
        missingVideoIds = missIds
        missingCountScanned = true
        UserDefaults.standard.set(true, forKey: Self.missingCountScannedKey)
        UserDefaults.standard.set(Array(missIds), forKey: Self.missingVideoIdsKey)
        libraryCounts = LibraryCounts(
            all: libraryCounts.all,
            recentlyAdded: libraryCounts.recentlyAdded,
            recentlyPlayed: libraryCounts.recentlyPlayed,
            topRated: libraryCounts.topRated,
            duplicates: libraryCounts.duplicates,
            corrupt: libraryCounts.corrupt,
            missing: missIds.count,
            recentlyConverted: libraryCounts.recentlyConverted,
            recentlyApplied: libraryCounts.recentlyApplied,
            lastAdded: libraryCounts.lastAdded,
            byRating: libraryCounts.byRating
        )
        recomputeFilteredVideos()

        // Hold 100% briefly so the UI can paint Done-ready state.
        locationRelinkProgress = LocationRelinkApplyProgress(
            phase: .checkingMissing, current: missingTotal, total: max(missingTotal, 1)
        )
        await Task.yield()

        let text = "Reconnected \(mappings.count) clip\(mappings.count == 1 ? "" : "s")"
        scanProgress = text
        showRepairLinksBannerFromMissingClick = false
        repairLinksBannerPreferredRoot = nil
        Task {
            try? await Task.sleep(for: .seconds(5))
            if self.scanProgress == text { self.scanProgress = "" }
        }
        return mappings.count
    }

    /// Reverse the last Reconnect apply.
    @discardableResult
    func undoLocationRelink() async -> Int {
        guard let payload = locationRelinkUndo, !payload.reverseMappings.isEmpty else { return 0 }
        isApplyingLocationRelink = true
        defer { isApplyingLocationRelink = false }

        let dbMappings = payload.reverseMappings.map { (videoId: $0.videoId, newFilePath: $0.to) }
        do {
            try await videoRepo.relinkFilePaths(mappings: dbMappings)
            let canRemapFolders = !payload.oldRoot.isEmpty && !payload.newRoot.isEmpty
                && payload.oldRoot.caseInsensitiveCompare(payload.newRoot) != .orderedSame
            if canRemapFolders {
                _ = try? await dataSourceRepo.remapPathsUnder(
                    oldRoot: payload.newRoot,
                    newRoot: payload.oldRoot
                )
                let excludeRepo = ExcludedFolderRepository(dbPool: dbPool)
                _ = try? await excludeRepo.remapPathsUnder(
                    oldRoot: payload.newRoot,
                    newRoot: payload.oldRoot
                )
            }
        } catch {
            reportTransientError("Couldn't undo reconnect: \(error.localizedDescription)")
            return 0
        }

        let pathMap = Dictionary(uniqueKeysWithValues: payload.reverseMappings.map { ($0.from, $0.to) })
        let undoPairs = payload.reverseMappings.map { (from: $0.from, to: $0.to) }
        let changedUndo = undoPairs.filter { $0.from != $0.to }
        if !changedUndo.isEmpty {
            await Task.detached(priority: .userInitiated) { [thumbnailService] in
                thumbnailService.migrateCacheKeys(changedUndo, onProgress: nil)
            }.value
        }
        var thumbPathUpdates: [(videoId: Int64, path: String)] = []
        var updated = videos
        for i in updated.indices {
            guard let old = pathMap[updated[i].filePath], old != updated[i].filePath else { continue }
            let remappedThumb = thumbnailService.remappedThumbnailPath(
                updated[i].thumbnailPath,
                newFilePath: old
            )
            updated[i].filePath = old
            if let remappedThumb {
                updated[i].thumbnailPath = remappedThumb
                if let dbId = updated[i].databaseId {
                    thumbPathUpdates.append((dbId, remappedThumb))
                }
            }
        }
        videos = updated
        if !thumbPathUpdates.isEmpty {
            try? await videoRepo.updateThumbnailPaths(updates: thumbPathUpdates)
        }
        for (neu, old) in pathMap where neu != old {
            remapVideoPathInSelection(from: neu, to: old)
        }
        if !changedUndo.isEmpty {
            PlaybackPositionStore.remapPaths(changedUndo)
            notifyResumePositionsChanged()
            filmstripRefreshId &+= 1
            filteredVideosVersion &+= 1
        }
        recentlyAppliedPaths = Set(recentlyAppliedPaths.map { pathMap[$0] ?? $0 })
        lastAddedPaths = Set(lastAddedPaths.map { pathMap[$0] ?? $0 })

        let count = payload.appliedCount
        locationRelinkUndo = nil
        recomputeFilteredVideos()
        await refreshMissingCount()
        let text = "Undid reconnect (\(count) clip\(count == 1 ? "" : "s"))"
        scanProgress = text
        Task {
            try? await Task.sleep(for: .seconds(5))
            if self.scanProgress == text { self.scanProgress = "" }
        }
        return count
    }

    func presentBulkRename(scope: MetadataExportScope) {
        let videos = videosForMetadataExport(scope: scope)
        guard !videos.isEmpty else { return }
        bulkRenameProgress = nil
        bulkRenameCancelRequested = false
        bulkRenamePresentation = BulkRenamePresentation(scope: scope, videoCount: videos.count)
    }

    func loadBulkRenamePattern() -> String {
        let stored = UserDefaults.standard.string(forKey: Self.bulkRenamePatternKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return BulkRenameTokenCatalog.defaultPattern
    }

    func saveBulkRenamePattern(_ pattern: String) {
        UserDefaults.standard.set(pattern, forKey: Self.bulkRenamePatternKey)
    }

    func cancelBulkRename() {
        guard bulkRenameProgress != nil else { return }
        bulkRenameCancelRequested = true
    }

    /// Two-phase rename so in-batch swaps/collisions that clear after a peer moves still succeed.
    /// Supports Cancel (rolls back staged temps). Does not auto-dismiss — caller shows the result.
    @discardableResult
    func applyBulkRename(_ rows: [BulkRenamePlanRow]) async -> BulkRenameApplyResult {
        let actionable = rows.filter(\.status.isActionable)
        guard !actionable.isEmpty else {
            return BulkRenameApplyResult(renamedCount: 0, failed: [], wasCancelled: false, restoredCount: 0)
        }

        let total = actionable.count
        bulkRenameCancelRequested = false
        bulkRenameProgress = .preparing(current: 0, total: total)
        defer {
            bulkRenameProgress = nil
            bulkRenameCancelRequested = false
        }

        struct Phase1 {
            let video: Video
            let originalName: String
            let finalName: String
            let sourceId: String
        }

        var phase1: [Phase1] = []
        phase1.reserveCapacity(actionable.count)
        var failed: [BulkRenameFailure] = []
        var wasCancelled = false

        for (index, row) in actionable.enumerated() {
            if bulkRenameCancelRequested {
                wasCancelled = true
                break
            }
            guard let live = videos.first(where: { $0.databaseId == row.video.databaseId })
                    ?? videos.first(where: { $0.filePath == row.video.filePath })
            else {
                failed.append(BulkRenameFailure(
                    id: row.id,
                    currentFileName: row.currentFileName,
                    proposedFileName: row.proposedFileName,
                    reason: "Video is no longer in the library",
                    videoDatabaseId: row.video.databaseId
                ))
                bulkRenameProgress = .preparing(current: index + 1, total: total)
                continue
            }
            let originalName = live.fileName
            let tempName = "\(Self.bulkRenameTempPrefix)\(UUID().uuidString)-\(originalName)"
            let outcome = await renameVideo(live, to: tempName, reportErrors: false)
            bulkRenameProgress = .preparing(current: index + 1, total: total)
            switch outcome {
            case .success:
                let afterTemp = videos.first(where: { $0.databaseId == live.databaseId })
                    ?? videos.first(where: { $0.fileName == tempName })
                guard let afterTemp else {
                    failed.append(BulkRenameFailure(
                        id: row.id,
                        currentFileName: originalName,
                        proposedFileName: row.proposedFileName,
                        reason: "Staged rename, but library state didn't update",
                        videoDatabaseId: live.databaseId
                    ))
                    continue
                }
                phase1.append(Phase1(
                    video: afterTemp,
                    originalName: originalName,
                    finalName: row.proposedFileName,
                    sourceId: row.id
                ))
            case .failure(let reason):
                failed.append(BulkRenameFailure(
                    id: row.id,
                    currentFileName: originalName,
                    proposedFileName: row.proposedFileName,
                    reason: reason,
                    videoDatabaseId: live.databaseId
                ))
            }
        }

        if wasCancelled || bulkRenameCancelRequested {
            wasCancelled = true
            let restored = await restoreBulkRenameStaged(phase1.map { ($0.video, $0.originalName) })
            recomputeFilteredVideos()
            return BulkRenameApplyResult(
                renamedCount: 0,
                failed: failed,
                wasCancelled: true,
                restoredCount: restored
            )
        }

        var renamedCount = 0
        bulkRenameProgress = .finishing(current: 0, total: max(phase1.count, 1))
        for (index, item) in phase1.enumerated() {
            if bulkRenameCancelRequested {
                wasCancelled = true
                let remaining = Array(phase1.suffix(from: index))
                let restored = await restoreBulkRenameStaged(remaining.map { ($0.video, $0.originalName) })
                recomputeFilteredVideos()
                return BulkRenameApplyResult(
                    renamedCount: renamedCount,
                    failed: failed,
                    wasCancelled: true,
                    restoredCount: restored
                )
            }
            guard let live = videos.first(where: { $0.databaseId == item.video.databaseId })
                    ?? videos.first(where: { $0.filePath == item.video.filePath })
            else {
                failed.append(BulkRenameFailure(
                    id: item.sourceId,
                    currentFileName: item.originalName,
                    proposedFileName: item.finalName,
                    reason: "Video is no longer in the library",
                    videoDatabaseId: item.video.databaseId
                ))
                bulkRenameProgress = .finishing(current: index + 1, total: phase1.count)
                continue
            }
            let outcome = await renameVideo(live, to: item.finalName, reportErrors: false)
            bulkRenameProgress = .finishing(current: index + 1, total: phase1.count)
            switch outcome {
            case .success:
                renamedCount += 1
            case .failure(let reason):
                if let stillTemp = videos.first(where: { $0.databaseId == item.video.databaseId }) {
                    _ = await renameVideo(stillTemp, to: item.originalName, reportErrors: false)
                }
                failed.append(BulkRenameFailure(
                    id: item.sourceId,
                    currentFileName: item.originalName,
                    proposedFileName: item.finalName,
                    reason: reason,
                    videoDatabaseId: item.video.databaseId
                ))
            }
        }

        recomputeFilteredVideos()
        return BulkRenameApplyResult(
            renamedCount: renamedCount,
            failed: failed,
            wasCancelled: wasCancelled,
            restoredCount: 0
        )
    }

    /// Restores staged `.skagway-bulk-…` names back to their pre-batch originals.
    private func restoreBulkRenameStaged(_ items: [(video: Video, originalName: String)]) async -> Int {
        guard !items.isEmpty else { return 0 }
        var restored = 0
        bulkRenameProgress = .rollingBack(current: 0, total: items.count)
        for (index, item) in items.enumerated() {
            let live = videos.first(where: { $0.databaseId == item.video.databaseId })
                ?? videos.first(where: { $0.filePath == item.video.filePath })
                ?? item.video
            if case .success = await renameVideo(live, to: item.originalName, reportErrors: false) {
                restored += 1
            }
            bulkRenameProgress = .rollingBack(current: index + 1, total: items.count)
        }
        return restored
    }

    /// Recovers library rows left at `.skagway-bulk-<uuid>-<original>` after an interrupted batch.
    func sweepInterruptedBulkRenameTemps() async {
        let candidates = videos.filter { $0.fileName.hasPrefix(Self.bulkRenameTempPrefix) }
        guard !candidates.isEmpty else { return }
        for video in candidates {
            guard let original = Self.originalNameFromBulkRenameTemp(video.fileName) else { continue }
            _ = await renameVideo(video, to: original, reportErrors: false)
        }
        recomputeFilteredVideos()
    }

    /// `.skagway-bulk-<uuid>-<originalName>` → `originalName` (UUID is always 36 characters).
    private static func originalNameFromBulkRenameTemp(_ fileName: String) -> String? {
        guard fileName.hasPrefix(bulkRenameTempPrefix) else { return nil }
        let rest = String(fileName.dropFirst(bulkRenameTempPrefix.count))
        guard rest.count > 37 else { return nil }
        let uuidEnd = rest.index(rest.startIndex, offsetBy: 36)
        guard rest[uuidEnd] == "-" else { return nil }
        let original = String(rest[rest.index(after: uuidEnd)...])
        return original.isEmpty ? nil : original
    }

    func videosForMetadataExport(scope: MetadataExportScope) -> [Video] {
        switch scope {
        case .filtered:
            return filteredVideos
        case .selection:
            return filteredVideos(forPaths: selectedVideoIds)
        }
    }

    func loadMetadataExportFormat() -> MetadataExportFormat {
        if let raw = UserDefaults.standard.string(forKey: Self.metadataExportFormatKey),
           let format = MetadataExportFormat(rawValue: raw)
        {
            return format
        }
        return .csv
    }

    func saveMetadataExportFormat(_ format: MetadataExportFormat) {
        UserDefaults.standard.set(format.rawValue, forKey: Self.metadataExportFormatKey)
    }

    /// Full field list order for the export sheet (checked and unchecked).
    func loadMetadataExportColumnOrder() -> [String] {
        let custom = customMetadataFieldDefinitions
        if let saved = UserDefaults.standard.array(forKey: Self.metadataExportColumnOrderKey) as? [String] {
            let sanitized = MetadataExportColumnRegistry.sanitizeFullListOrder(saved, customFields: custom)
            if !sanitized.isEmpty { return sanitized }
        }
        return MetadataExportColumnRegistry.defaultFullListOrder(customFields: custom)
    }

    func saveMetadataExportColumnOrder(_ ids: [String]) {
        let sanitized = MetadataExportColumnRegistry.sanitizeFullListOrder(
            ids,
            customFields: customMetadataFieldDefinitions
        )
        UserDefaults.standard.set(sanitized, forKey: Self.metadataExportColumnOrderKey)
    }

    func loadMetadataExportIncludedColumnIDs() -> Set<String> {
        let custom = customMetadataFieldDefinitions
        if let saved = UserDefaults.standard.array(forKey: Self.metadataExportIncludedColumnsKey) as? [String] {
            let sanitized = MetadataExportColumnRegistry.sanitizeIncludedIDs(saved, customFields: custom)
            if !sanitized.isEmpty { return sanitized }
        }
        // Migrate older prefs that only stored the included-ordered list.
        if let legacy = UserDefaults.standard.array(forKey: Self.metadataExportColumnOrderKey) as? [String],
           UserDefaults.standard.object(forKey: Self.metadataExportIncludedColumnsKey) == nil
        {
            let legacyIncluded = MetadataExportColumnRegistry.sanitizeOrderedIDs(legacy, customFields: custom)
            if !legacyIncluded.isEmpty {
                return Set(legacyIncluded)
            }
        }
        return MetadataExportColumnRegistry.defaultIncludedIDs(customFields: custom)
    }

    func saveMetadataExportIncludedColumnIDs(_ ids: Set<String>) {
        let sanitized = MetadataExportColumnRegistry.sanitizeIncludedIDs(
            Array(ids),
            customFields: customMetadataFieldDefinitions
        )
        UserDefaults.standard.set(Array(sanitized), forKey: Self.metadataExportIncludedColumnsKey)
    }

    // MARK: - Import Metadata

    struct MetadataApplySummary: Identifiable, Equatable {
        let id = UUID()
        let sourceURL: URL
        let format: MetadataApplyFormat
        let matchedCount: Int
        let updatedVideoCount: Int
        let unmatchedCount: Int
        let skippedUnknownColumns: [String]
        let ignoredReadOnlyColumns: [String]
        let rowErrors: [String]
    }

    /// Presented when Import Metadata finds columns that are not built-ins or existing custom fields.
    struct MetadataApplyUnknownColumnsPrompt: Identifiable, Equatable {
        let id = UUID()
        let sourceURL: URL
        let format: MetadataApplyFormat
        let columns: [UnknownImportColumn]
    }

    var metadataApplySummary: MetadataApplySummary? = nil
    var metadataApplyUnknownColumnsPrompt: MetadataApplyUnknownColumnsPrompt? = nil
    var metadataApplyProgress: (current: Int, total: Int)? = nil
    var metadataApplyErrorMessage: String? = nil
    var metadataApplyUnmatchedRows: [MetadataApplyUnmatchedRow]? = nil
    /// Bytes of the file chosen for Apply (kept so Pass 2 / unknown-column resume does not re-open the URL).
    private var metadataApplySourceData: Data? = nil
    private var metadataApplyPendingURL: URL? = nil
    private var metadataApplyTask: Task<Void, Never>?

    func presentApplyMetadata(from url: URL, data: Data) {
        metadataApplyErrorMessage = nil
        metadataApplyUnmatchedRows = nil
        metadataApplyProgress = nil
        metadataApplyUnknownColumnsPrompt = nil
        metadataApplySourceData = data
        metadataApplyPendingURL = url
        runMetadataApply(from: url, data: data, offerUnknownColumns: true)
    }

    func presentApplyMetadataReadError(_ message: String) {
        metadataApplyErrorMessage = message
        metadataApplySummary = MetadataApplySummary(
            sourceURL: URL(fileURLWithPath: "/"),
            format: .jsonl,
            matchedCount: 0,
            updatedVideoCount: 0,
            unmatchedCount: 0,
            skippedUnknownColumns: [],
            ignoredReadOnlyColumns: [],
            rowErrors: [message]
        )
    }

    func dismissMetadataApplySummary() {
        metadataApplySummary = nil
        metadataApplyUnmatchedRows = nil
        metadataApplyErrorMessage = nil
        metadataApplyProgress = nil
        metadataApplySourceData = nil
        metadataApplyPendingURL = nil
        metadataApplyUnknownColumnsPrompt = nil
    }

    /// Create selected unknown columns as custom metadata fields, then continue the import.
    func confirmImportUnknownColumns(_ selections: [(key: String, valueType: CustomMetadataValueType)]) {
        for sel in selections {
            addCustomMetadataField(name: sel.key, valueType: sel.valueType)
        }
        metadataApplyUnknownColumnsPrompt = nil
        guard let url = metadataApplyPendingURL, let data = metadataApplySourceData else { return }
        runMetadataApply(from: url, data: data, offerUnknownColumns: false)
    }

    /// Continue import without creating custom fields for unknown columns.
    func skipImportUnknownColumns() {
        metadataApplyUnknownColumnsPrompt = nil
        guard let url = metadataApplyPendingURL, let data = metadataApplySourceData else { return }
        runMetadataApply(from: url, data: data, offerUnknownColumns: false)
    }

    /// Abort import after the unknown-columns prompt.
    func cancelImportUnknownColumns() {
        metadataApplyTask?.cancel()
        metadataApplyUnknownColumnsPrompt = nil
        metadataApplyProgress = nil
        metadataApplySourceData = nil
        metadataApplyPendingURL = nil
    }

    /// - Parameter offerUnknownColumns: When true (first pass), pause for a dialog if unknowns exist.
    ///   After the user confirms or skips, call again with `false` so remaining unknowns only appear in the summary.
    func runMetadataApply(from url: URL, data: Data, offerUnknownColumns: Bool = true) {
        metadataApplyTask?.cancel()
        let videosSnapshot = videos
        let tagsSnapshot = tagsByVideoId
        let customSnapshot = listCustomMetadataByVideoId
        let customDefs = customMetadataFieldDefinitions
        let videoRepo = videoRepo
        let tagRepo = tagRepo
        var resumeById: [Int64: Double] = [:]
        resumeById.reserveCapacity(videosSnapshot.count)
        for v in videosSnapshot {
            guard let id = v.databaseId,
                  let seconds = PlaybackPositionStore.loadSeconds(filePath: v.filePath)
            else { continue }
            resumeById[id] = seconds
        }

        metadataApplyProgress = (0, 1)
        metadataApplyTask = Task { [weak self] in
            do {
                let format = try MetadataApplyParser.detectFormat(url: url, data: data)
                let (rows, unknownColumns, resolved) = try MetadataApplyParser.parse(
                    data: data,
                    format: format,
                    customFields: customDefs
                )

                if offerUnknownColumns, !unknownColumns.isEmpty {
                    await MainActor.run {
                        guard let self else { return }
                        self.metadataApplyProgress = nil
                        self.metadataApplyPendingURL = url
                        self.metadataApplyUnknownColumnsPrompt = MetadataApplyUnknownColumnsPrompt(
                            sourceURL: url,
                            format: format,
                            columns: unknownColumns
                        )
                    }
                    return
                }

                let skippedKeys = unknownColumns.map(\.key)
                let index = MetadataApplier.buildIndex(
                    videos: videosSnapshot,
                    tagsByVideoId: tagsSnapshot,
                    customByVideoId: customSnapshot,
                    customFieldDefinitions: customDefs,
                    resumeSecondsByVideoId: resumeById
                )
                let pass1 = try MetadataApplier.pass1(
                    rows: rows,
                    resolvedColumnIDs: resolved,
                    skippedUnknownColumns: skippedKeys,
                    index: index
                )

                // Persist updates on main actor via existing repo APIs.
                await MainActor.run { self?.metadataApplyProgress = (1, max(pass1.matchedCount, 1)) }

                for (dbId, rating) in pass1.ratingUpdates {
                    try? await videoRepo.updateRating(videoId: dbId, rating: rating)
                }
                for (dbId, title) in pass1.titleUpdates {
                    try? await videoRepo.updateTitle(videoId: dbId, title: title)
                }
                if !pass1.subtitleUpdates.isEmpty {
                    let subtitleBulk = pass1.subtitleUpdates.map { (videoId: $0.key, presence: $0.value) }
                    try? await videoRepo.updateSubtitlePresence(updates: subtitleBulk)
                }
                if !pass1.playCountUpdates.isEmpty {
                    let playCountBulk = pass1.playCountUpdates.map { (videoId: $0.key, playCount: $0.value) }
                    try? await videoRepo.updatePlayCount(updates: playCountBulk)
                }
                for (fieldId, byVideo) in pass1.customUpdates {
                    for (dbId, value) in byVideo {
                        try? await videoRepo.upsertCustomMetadata(videoId: dbId, fieldId: fieldId, value: value)
                    }
                }
                for (dbId, tagNames) in pass1.tagMerges {
                    for name in tagNames {
                        if let tag = try? await tagRepo.findOrCreate(name: name), let tagId = tag.id {
                            try? await tagRepo.addTag(tagId, to: dbId)
                        }
                    }
                }

                await MainActor.run {
                    guard let self else { return }
                    // Reflect rating / title / subtitle / play-count updates in memory
                    if !pass1.ratingUpdates.isEmpty
                        || !pass1.titleUpdates.isEmpty
                        || !pass1.subtitleUpdates.isEmpty
                        || !pass1.playCountUpdates.isEmpty
                    {
                        var updated = self.videos
                        for i in updated.indices {
                            guard let id = updated[i].databaseId else { continue }
                            if let r = pass1.ratingUpdates[id] {
                                updated[i].rating = r
                            }
                            if let t = pass1.titleUpdates[id] {
                                updated[i].title = t
                            }
                            if let s = pass1.subtitleUpdates[id] {
                                updated[i].subtitlePresence = s
                            }
                            if let c = pass1.playCountUpdates[id] {
                                updated[i].playCount = c
                            }
                        }
                        self.videos = updated
                    }
                    if !pass1.resumeUpdates.isEmpty {
                        var byPath: [String: Double] = [:]
                        byPath.reserveCapacity(pass1.resumeUpdates.count)
                        for video in self.videos {
                            guard let id = video.databaseId,
                                  let seconds = pass1.resumeUpdates[id]
                            else { continue }
                            byPath[video.filePath] = seconds
                        }
                        PlaybackPositionStore.saveSecondsBatch(byPath)
                        self.notifyResumePositionsChanged()
                    }
                    for (fieldId, byVideo) in pass1.customUpdates {
                        for (dbId, value) in byVideo {
                            self.mergeListCustomMetadataCache(videoId: dbId, fieldId: fieldId, value: value)
                        }
                    }
                    if !pass1.tagMerges.isEmpty {
                        Task { await self.refreshTagsByVideoId() }
                    }

                    self.recentlyAppliedPaths = Set(pass1.matchedPaths)
                    self.sidebarFilter = .recentlyApplied
                    self.updateLibraryCounts()
                    // Tag / custom-metadata writes don't go through `videos` didSet; refresh
                    // search matches so an active query picks up imported Featuring/tags/etc.
                    if !self.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        self.refreshSearchIfActive()
                    } else {
                        self.recomputeFilteredVideos()
                    }

                    self.metadataApplyProgress = nil
                    self.metadataApplySummary = MetadataApplySummary(
                        sourceURL: url,
                        format: format,
                        matchedCount: pass1.matchedCount,
                        updatedVideoCount: pass1.updatedVideoCount,
                        unmatchedCount: pass1.unmatchedCount,
                        skippedUnknownColumns: pass1.skippedUnknownColumns,
                        ignoredReadOnlyColumns: pass1.ignoredReadOnlyColumns,
                        rowErrors: pass1.rowErrors
                    )
                    let text = "Imported metadata: \(pass1.matchedCount) matched, \(pass1.updatedVideoCount) updated"
                    self.scanProgress = text
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(4))
                        if self?.scanProgress == text { self?.scanProgress = "" }
                    }
                }
            } catch {
                let ext = url.pathExtension.lowercased()
                let formatHint: MetadataApplyFormat =
                    (ext == "jsonl" || ext == "json") ? .jsonl : .csv
                await MainActor.run {
                    self?.metadataApplyProgress = nil
                    self?.metadataApplyErrorMessage = error.localizedDescription
                    // Still present an empty summary shell so the user sees the error in-sheet
                    self?.metadataApplySummary = MetadataApplySummary(
                        sourceURL: url,
                        format: formatHint,
                        matchedCount: 0,
                        updatedVideoCount: 0,
                        unmatchedCount: 0,
                        skippedUnknownColumns: [],
                        ignoredReadOnlyColumns: [],
                        rowErrors: [error.localizedDescription]
                    )
                }
            }
        }
    }

    func loadUnmatchedForCurrentApply() {
        guard let summary = metadataApplySummary,
              let data = metadataApplySourceData else { return }
        let url = summary.sourceURL
        let videosSnapshot = videos
        let tagsSnapshot = tagsByVideoId
        let customSnapshot = listCustomMetadataByVideoId
        let customDefs = customMetadataFieldDefinitions
        Task { [weak self] in
            do {
                let format = try MetadataApplyParser.detectFormat(url: url, data: data)
                let (rows, _, _) = try MetadataApplyParser.parse(
                    data: data,
                    format: format,
                    customFields: customDefs
                )
                let index = MetadataApplier.buildIndex(
                    videos: videosSnapshot,
                    tagsByVideoId: tagsSnapshot,
                    customByVideoId: customSnapshot,
                    customFieldDefinitions: customDefs
                )
                let unmatched = MetadataApplier.pass2Unmatched(rows: rows, index: index)
                await MainActor.run {
                    self?.metadataApplyUnmatchedRows = unmatched
                }
            } catch {
                await MainActor.run {
                    self?.metadataApplyErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func makeMetadataExportContext() -> MetadataExportContext {
        MetadataExportContext(
            tagsByVideoId: tagsByVideoId,
            customValuesByVideoId: listCustomMetadataByVideoId,
            customFieldDefinitions: Dictionary(
                uniqueKeysWithValues: customMetadataFieldDefinitions.map { ($0.id, $0) }
            ),
            missingVideoIds: missingVideoIds,
            duplicateVideoIds: duplicateVideoIds,
            convertedDatesByPath: recentlyConvertedDates,
            thumbnailsSettled: thumbnailsSettled
        )
    }

    func cancelMetadataExport() {
        metadataExportTask?.cancel()
        metadataExportTask = nil
        metadataExportProgress = nil
    }

    func runMetadataExport(
        scope: MetadataExportScope,
        format: MetadataExportFormat,
        orderedColumnIDs: [String],
        destinationURL: URL
    ) {
        cancelMetadataExport()
        let videos = videosForMetadataExport(scope: scope)
        guard !videos.isEmpty, !orderedColumnIDs.isEmpty else {
            metadataExportErrorMessage = MetadataExportError.emptySelection.localizedDescription
            return
        }
        saveMetadataExportFormat(format)

        let columns = MetadataExportColumnRegistry.allColumns(customFields: customMetadataFieldDefinitions)
        let columnsByID = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0) })
        let context = makeMetadataExportContext()
        let request = MetadataExporter.Request(
            videos: videos,
            orderedColumnIDs: orderedColumnIDs,
            columnsByID: columnsByID,
            format: format,
            context: context,
            destinationURL: destinationURL
        )

        metadataExportErrorMessage = nil
        metadataExportProgress = (0, videos.count)
        metadataExportTask = Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try MetadataExporter.export(request) { current, total in
                        Task { @MainActor [weak self] in
                            self?.metadataExportProgress = (current, total)
                        }
                    }
                }.value
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.metadataExportProgress = nil
                    self.metadataExportTask = nil
                    self.metadataExportPresentation = nil
                    let text = "Exported \(videos.count) video\(videos.count == 1 ? "" : "s")"
                    self.scanProgress = text
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(3))
                        if self?.scanProgress == text { self?.scanProgress = "" }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.metadataExportProgress = nil
                    self?.metadataExportTask = nil
                }
            } catch {
                await MainActor.run {
                    self?.metadataExportProgress = nil
                    self?.metadataExportTask = nil
                    self?.metadataExportErrorMessage = error.localizedDescription
                }
            }
        }
    }

    var isSortedByName: Bool {
        guard let first = tableSortOrder.first else { return false }
        return VideoSort.from(keyPath: first.keyPath) == .name
    }

    private(set) var filteredVideos: [Video] = []
    private(set) var filteredVideosVersion: Int = 0
    var libraryCounts = LibraryCounts()
    private var cachedCollectionRules: [Int64: [CollectionRule]] = [:]
    private var cachedCollectionRuleGroups: [Int64: [CollectionRuleGroup]] = [:]
    /// Album membership in playlist order: collectionId → video database ids.
    private var cachedAlbumVideoIds: [Int64: [Int64]] = [:]
    private var collectionCountTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var ftsMatchIds: Set<String>?
    private var duplicateVideoIds: Set<String> = []
    private var missingVideoIds: Set<String> = []
    /// Paths matched by the last successful Import Metadata run (Last Metadata Import smart library).
    private(set) var recentlyAppliedPaths: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(recentlyAppliedPaths), forKey: Self.recentlyAppliedPathsKey)
        }
    }
    /// Paths imported by the most recent media-add scan (Last Added smart library).
    private(set) var lastAddedPaths: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(lastAddedPaths), forKey: Self.lastAddedPathsKey)
        }
    }
    private(set) var missingCountScanned: Bool = false
    private(set) var isRefreshingMissing: Bool = false
    private var filterGeneration: Int = 0

    /// Normalized (`lo`, `hi`) key for a confirmed "not a duplicate" pair of video database ids.
    struct NotDuplicateKey: Hashable {
        let lo: Int64
        let hi: Int64
        init(_ a: Int64, _ b: Int64) { lo = min(a, b); hi = max(a, b) }
    }
    /// In-memory copy of the `video_not_duplicate` table, loaded on `startObserving`. A pair here
    /// means the user marked those two videos as not duplicates of each other; the Duplicates
    /// recompute treats them as a confirmed-distinct edge. See `updateLibraryCounts`.
    private var notDuplicatePairs: Set<NotDuplicateKey> = []
    /// Guards the one-time content-fingerprint backfill from running concurrently.
    private var isBackfillingFingerprints = false
    /// Ensures the backfill is kicked off only once per session (see `kickOffFingerprintBackfillIfNeeded`).
    private var didKickOffFingerprintBackfill = false
    /// Live progress of the fingerprint backfill, surfaced in the activity strip while it runs.
    /// `total == 0` means not currently running.
    private(set) var fingerprintBackfillTotal: Int = 0
    private(set) var fingerprintBackfillDone: Int = 0
    var isFingerprintingInProgress: Bool { fingerprintBackfillTotal > 0 }

    /// Bulk delete / remove-from-library progress for the activity strip.
    private(set) var isDeleting = false
    private(set) var deleteCurrent = 0
    private(set) var deleteTotal = 0
    private(set) var deleteKindLabel = "Deleting"

    /// Bottom activity strip snapshot (Option B). Priority: errors → queues → scans/import-export → fingerprint → messages.
    var activityStripState: ActivityStripState {
        var candidates: [AppActivity] = []

        if isDeleting, deleteTotal > 0 {
            let fraction = Double(deleteCurrent) / Double(max(deleteTotal, 1))
            candidates.append(AppActivity(
                id: "delete",
                kind: .deleting,
                title: "\(deleteKindLabel) \(deleteCurrent)/\(deleteTotal)",
                fraction: fraction
            ))
        }

        // Find missing folder (no wizard sheet) — show Repair Links apply progress in the strip.
        // When the Repair Links sheet is open it renders its own bar; skip the strip then.
        if isApplyingLocationRelink,
           locationRelinkPresentation == nil,
           let progress = locationRelinkProgress
        {
            candidates.append(AppActivity(
                id: "repair-links",
                kind: .repairingLinks,
                title: progress.statusText,
                fraction: progress.total > 0 ? progress.fraction : nil
            ))
        }

        if isScanning {
            let title: String = {
                if scanTotal > 0 { return "Scanning \(scanCurrent)/\(scanTotal)" }
                return scanProgress.isEmpty ? "Scanning…" : scanProgress
            }()
            let fraction = scanTotal > 0 ? Double(scanCurrent) / Double(scanTotal) : nil
            candidates.append(AppActivity(
                id: "scan",
                kind: .scanning,
                title: title,
                fraction: fraction
            ))
        } else if !scanProgress.isEmpty {
            let isError = scanProgress.hasPrefix("Error:")
            candidates.append(AppActivity(
                id: "scan-message",
                kind: isError ? .error : .message,
                title: isError ? String(scanProgress.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces) : scanProgress,
                isError: isError
            ))
        }

        if let apply = metadataApplyProgress, apply.total > 0 {
            candidates.append(AppActivity(
                id: "metadata-apply",
                kind: .importingMetadata,
                title: "Importing metadata \(apply.current)/\(apply.total)",
                fraction: Double(apply.current) / Double(apply.total)
            ))
        }

        if let export = metadataExportProgress, export.total > 0 {
            candidates.append(AppActivity(
                id: "metadata-export",
                kind: .exportingMetadata,
                title: "Exporting metadata \(export.current)/\(export.total)",
                fraction: Double(export.current) / Double(export.total)
            ))
        }

        if isFingerprintingInProgress {
            candidates.append(AppActivity(
                id: "fingerprint",
                kind: .fingerprinting,
                title: "Fingerprinting for duplicates \(fingerprintBackfillDone)/\(fingerprintBackfillTotal)",
                fraction: Double(fingerprintBackfillDone) / Double(max(fingerprintBackfillTotal, 1))
            ))
        }

        let conversionActive = conversionJobs.contains { $0.isActive }
        let conversionFailed = !conversionActive && conversionJobs.contains { if case .failed = $0.status { return true }; return false }
        let conversionQueued = conversionJobs.contains { $0.status == .queued }
        if conversionActive || conversionFailed || conversionQueued {
            let fraction: Double? = {
                guard let running = conversionJobs.first(where: { if case .converting = $0.status { return true }; return false }),
                      case .converting(let pct) = running.status else { return nil }
                return Double(pct) / 100.0
            }()
            let shortTitle: String = {
                if conversionFailed {
                    let n = conversionJobs.filter { if case .failed = $0.status { return true }; return false }.count
                    return n == 1 ? "Re-encode failed" : "\(n) re-encodes failed"
                }
                if let running = conversionJobs.first(where: { if case .converting = $0.status { return true }; return false }),
                   case .converting(let pct) = running.status {
                    let queued = conversionJobs.filter { $0.status == .queued }.count
                    let base = "Re-encode \(pct)%"
                    return queued > 0 ? "\(base) · +\(queued)" : base
                }
                let queued = conversionJobs.filter { $0.status == .queued }.count
                return queued == 1 ? "1 queued to re-encode" : "\(queued) queued to re-encode"
            }()
            candidates.append(AppActivity(
                id: "reencode",
                kind: .reencoding,
                title: shortTitle,
                fraction: fraction,
                isError: conversionFailed,
                action: .openConversionQueue
            ))
        }

        let moveActive = moveJobs.contains { $0.isActive }
        let moveFailed = !moveActive && moveJobs.contains { if case .failed = $0.status { return true }; return false }
        let moveQueued = moveJobs.contains { $0.status == .queued }
        if moveActive || moveFailed || moveQueued {
            let fraction: Double? = {
                guard let running = moveJobs.first(where: { if case .moving = $0.status { return true }; return false }),
                      case .moving(let f) = running.status else { return nil }
                return f
            }()
            let shortTitle: String = {
                if moveFailed {
                    let n = moveJobs.filter { if case .failed = $0.status { return true }; return false }.count
                    return n == 1 ? "Move failed" : "\(n) moves failed"
                }
                if let running = moveJobs.first(where: { if case .moving = $0.status { return true }; return false }),
                   case .moving(let f) = running.status {
                    let pct = Int(f * 100)
                    let queued = moveJobs.filter { $0.status == .queued }.count
                    let base = "Moving \(pct)%"
                    return queued > 0 ? "\(base) · +\(queued)" : base
                }
                let queued = moveJobs.filter { $0.status == .queued }.count
                return queued == 1 ? "1 queued to move" : "\(queued) queued to move"
            }()
            candidates.append(AppActivity(
                id: "move",
                kind: .moving,
                title: shortTitle,
                fraction: fraction,
                isError: moveFailed,
                action: .openMoveQueue
            ))
        }

        guard !candidates.isEmpty else { return .empty }

        func priority(_ a: AppActivity) -> Int {
            if a.isError { return 0 }
            switch a.kind {
            case .moving: return 1
            case .reencoding: return 2
            case .deleting: return 3
            case .repairingLinks: return 4
            case .scanning: return 5
            case .importingMetadata, .exportingMetadata: return 6
            case .fingerprinting: return 7
            case .message: return 8
            case .error: return 0
            }
        }

        let sorted = candidates.sorted { priority($0) < priority($1) }
        let primary = sorted.first
        let secondaries = Array(sorted.dropFirst().prefix(2))
        return ActivityStripState(primary: primary, secondaries: secondaries)
    }

    let dbPool: DatabasePool
    let videoRepo: VideoRepository
    let tagRepo: TagRepository
    let bookmarkRepo: VideoBookmarkRepository
    let collectionRepo: CollectionRepository
    let dataSourceRepo: DataSourceRepository
    let customMetadataFieldRepo: CustomMetadataFieldRepository
    let thumbnailService: ThumbnailService
    private let scanner: LibraryScanner
    private var observationTask: Task<Void, Never>?

    init(dbPool: DatabasePool, thumbnailService: ThumbnailService) {
        self.dbPool = dbPool
        self.videoRepo = VideoRepository(dbPool: dbPool)
        self.tagRepo = TagRepository(dbPool: dbPool)
        self.bookmarkRepo = VideoBookmarkRepository(dbPool: dbPool)
        self.collectionRepo = CollectionRepository(dbPool: dbPool)
        self.dataSourceRepo = DataSourceRepository(dbPool: dbPool)
        self.customMetadataFieldRepo = CustomMetadataFieldRepository(dbPool: dbPool)
        self.thumbnailService = thumbnailService
        self.scanner = LibraryScanner(dbPool: dbPool, thumbnailService: thumbnailService)
        loadPreferences()
        Task { await refreshListCustomMetadataCacheIfNeeded() }
    }

    // MARK: - Preferences Persistence

    private static let viewModeKey = "Skagway.viewMode"
    /// Legacy nested Poster/Storyboard toggle; migrated into `ViewMode.storyboard` on load.
    private static let gridDisplayModeKey = PrefsKeys.gridDisplayMode
    private static let gridSizeKey = "Skagway.gridSize"
    private static let sortColumnKey = "Skagway.sortColumn"
    private static let sortAscendingKey = "Skagway.sortAscending"
    private static let excludeCorruptKey = "Skagway.excludeCorrupt"
    private static let confirmDeletionsKey = "Skagway.confirmDeletions"
    private static let showThumbnailInDetailKey = "Skagway.showThumbnailInDetail"
    private static let browsingLayoutKey = "Skagway.browsingLayout"
    private static let filmstripRowsKey = "Skagway.filmstripRows"
    private static let filmstripColumnsKey = "Skagway.filmstripColumns"
    private static let lastAppliedFilmstripRowsKey = "Skagway.lastAppliedFilmstripRows"
    private static let lastAppliedFilmstripColumnsKey = "Skagway.lastAppliedFilmstripColumns"
    private static let surpriseMeAutoPlaysKey = "Skagway.surpriseMeAutoPlays"
    private static let playAllLoopsKey = "Skagway.playAllLoops"
    private static let gridHoverPreviewEnabledKey = "Skagway.gridHoverPreviewEnabled"
    private static let storyboardDensityKey = PrefsKeys.storyboardDensity
    private static let playerFloatingWidthKey = "Skagway.playerFloatingWidth"
    private static let playerFloatingHeightKey = "Skagway.playerFloatingHeight"
    private static let playerFloatingPositionXKey = "Skagway.playerFloatingPositionX"
    private static let playerFloatingPositionYKey = "Skagway.playerFloatingPositionY"
    private static let playerStartPreferenceKey = "Skagway.playerStartPreference"
    private static let playerSizeIsCompactKey = "Skagway.playerSizeIsCompact"
    private static let playerLastWasFullScreenKey = "Skagway.playerLastWasFullScreen"
    private static let fadeResumeBannerAutomaticallyKey = "Skagway.fadeResumeBannerAutomatically"
    private static let resumeBannerFadeDelaySecondsKey = "Skagway.resumeBannerFadeDelaySeconds"
    private static let tagBlindDefaultStateKey = "Skagway.tagBlindDefaultState"
    private static let recentlyAddedDaysKey = "Skagway.recentlyAddedDays"
    private static let recentlyPlayedDaysKey = "Skagway.recentlyPlayedDays"
    private static let topRatedMinRatingKey = "Skagway.topRatedMinRating"
    private static let showRecentlyAddedKey = "Skagway.showRecentlyAdded"
    private static let showRecentlyPlayedKey = "Skagway.showRecentlyPlayed"
    private static let showTopRatedKey = "Skagway.showTopRated"
    private static let showDuplicatesKey = "Skagway.showDuplicates"
    private static let showCorruptKey = "Skagway.showCorrupt"
    private static let showMissingKey = "Skagway.showMissing"
    private static let showRecentlyConvertedKey = "Skagway.showRecentlyConverted"
    private static let recentlyConvertedEntriesKey = "Skagway.recentlyConvertedEntries"
    private static let recentlyAppliedPathsKey = "Skagway.recentlyAppliedPaths"
    private static let lastAddedPathsKey = "Skagway.lastAddedPaths"
    private static let conversionJobsKey = "Skagway.conversionJobs"
    private static let moveJobsKey = "Skagway.moveJobs"
    private static let ffmpegPathKey = "Skagway.ffmpegPath"
    private static let customMetadataFieldDefinitionsKey = "Skagway.customMetadataFieldDefinitions"
    private static let missingCountScannedKey = "Skagway.missingCountScanned"
    private static let filtersDrawerHeightKey = "Skagway.filtersDrawerHeight"
    private static let filterDrawerHeightModeKey = "Skagway.filterDrawerHeightMode"
    private static let filtersDrawerModeKey = "Skagway.filtersDrawerMode"
    private static let inspectorHeroHeightKey = "Skagway.inspectorHeroHeight"
    private static let inspectorVisibleKey = PrefsKeys.inspectorVisible
    private static let missingVideoIdsKey = "Skagway.missingVideoIds"
    private static let listColumnPreferencesKey = "Skagway.listColumnPreferences"

    var excludeCorrupt: Bool = false {
        didSet {
            UserDefaults.standard.set(excludeCorrupt, forKey: Self.excludeCorruptKey)
            updateLibraryCounts()
            recomputeFilteredVideos()
            scheduleCollectionCountRefresh()
        }
    }

    var confirmDeletions: Bool = true {
        didSet {
            UserDefaults.standard.set(confirmDeletions, forKey: Self.confirmDeletionsKey)
        }
    }

    var recentlyAddedDays: Int = 7 {
        didSet {
            UserDefaults.standard.set(recentlyAddedDays, forKey: Self.recentlyAddedDaysKey)
            updateLibraryCounts()
            recomputeFilteredVideos()
        }
    }

    var recentlyPlayedDays: Int = 30 {
        didSet {
            UserDefaults.standard.set(recentlyPlayedDays, forKey: Self.recentlyPlayedDaysKey)
            updateLibraryCounts()
            recomputeFilteredVideos()
        }
    }

    var topRatedMinRating: Int = 4 {
        didSet {
            UserDefaults.standard.set(topRatedMinRating, forKey: Self.topRatedMinRatingKey)
            updateLibraryCounts()
            recomputeFilteredVideos()
        }
    }

    var showRecentlyAdded: Bool = true {
        didSet {
            UserDefaults.standard.set(showRecentlyAdded, forKey: Self.showRecentlyAddedKey)
            resetFilterIfHidden()
        }
    }

    var showRecentlyPlayed: Bool = true {
        didSet {
            UserDefaults.standard.set(showRecentlyPlayed, forKey: Self.showRecentlyPlayedKey)
            resetFilterIfHidden()
        }
    }

    var showTopRated: Bool = true {
        didSet {
            UserDefaults.standard.set(showTopRated, forKey: Self.showTopRatedKey)
            resetFilterIfHidden()
        }
    }

    var showDuplicates: Bool = true {
        didSet {
            UserDefaults.standard.set(showDuplicates, forKey: Self.showDuplicatesKey)
            resetFilterIfHidden()
        }
    }

    var showCorrupt: Bool = true {
        didSet {
            UserDefaults.standard.set(showCorrupt, forKey: Self.showCorruptKey)
            resetFilterIfHidden()
        }
    }

    var showMissing: Bool = true {
        didSet {
            UserDefaults.standard.set(showMissing, forKey: Self.showMissingKey)
            resetFilterIfHidden()
        }
    }

    var showRecentlyConverted: Bool = true {
        didSet {
            UserDefaults.standard.set(showRecentlyConverted, forKey: Self.showRecentlyConvertedKey)
            resetFilterIfHidden()
        }
    }

    // Legacy shape kept only to migrate the old UserDefaults key into `conversionJobs`.
    private struct ConvertedEntry: Codable {
        var path: String
        var date: Date
    }

    /// The re-encode queue + history, persisted so it survives relaunch. Views read this;
    /// only the view model mutates it (always via `persistConversionJobs()` on transitions).
    private(set) var conversionJobs: [ConversionJob] = []
    /// True while `drainConversionQueue()` is running so we never start a second drain loop.
    private var isDrainingConversions = false
    /// The currently running ffmpeg process, held so an in-progress job can be aborted.
    private var currentConversionProcess: Process?

    /// The move queue + history, persisted so it survives relaunch. Only cross-volume moves
    /// (real copy + delete) enter this queue — same-volume moves are an instant atomic rename
    /// and run inline. Views read this; only the view model mutates it.
    private(set) var moveJobs: [MoveJob] = []
    /// True while `drainMoveQueue()` is running so we never start a second drain loop.
    private var isDrainingMoves = false
    /// In-flight copy task + abort latch (cooperative; `Task.cancel` alone is not enough).
    private var currentMoveTask: Task<Void, Error>?
    private var currentMoveAbortLatch: MoveAbortLatch?
    private func resetFilterIfHidden() {
        switch sidebarFilter {
        case .recentlyAdded where !showRecentlyAdded,
             .recentlyPlayed where !showRecentlyPlayed,
             .topRated where !showTopRated,
             .duplicates where !showDuplicates,
             .corrupt where !showCorrupt,
             .missing where !showMissing,
             .recentlyConverted where !showRecentlyConverted:
            sidebarFilter = .all
        default:
            break
        }
    }

    var surpriseMeAutoPlays: Bool = true {
        didSet {
            UserDefaults.standard.set(surpriseMeAutoPlays, forKey: Self.surpriseMeAutoPlaysKey)
        }
    }

    /// When true, a Play All session wraps from the last video back to the first. Ignored unless Play All is running.
    var playAllLoops: Bool = false {
        didSet {
            UserDefaults.standard.set(playAllLoops, forKey: Self.playAllLoopsKey)
        }
    }

    /// Live muted hover scrub on Grid cards. Off by preference or while the floating player is open.
    var gridHoverPreviewEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(gridHoverPreviewEnabled, forKey: Self.gridHoverPreviewEnabledKey)
        }
    }

    /// Storyboard View packing only (Normal = roomier default; Compact = tighter).
    var storyboardDensity: StoryboardDensity = .normal {
        didSet {
            guard storyboardDensity != oldValue else { return }
            UserDefaults.standard.set(storyboardDensity.rawValue, forKey: Self.storyboardDensityKey)
        }
    }

    // MARK: - Single resizable player (redesign — see Playback_Redesign_Plan_2026-06-30.md)

    /// Current in-window size of the single floating player. Persisted as the last size so the player
    /// reopens where the user left it.
    var playerFloatingSize: CGSize = CGSize(width: 480, height: 300) {
        didSet {
            guard playerFloatingSize != oldValue else { return }
            UserDefaults.standard.set(Double(playerFloatingSize.width), forKey: Self.playerFloatingWidthKey)
            UserDefaults.standard.set(Double(playerFloatingSize.height), forKey: Self.playerFloatingHeightKey)
        }
    }

    /// Center point of the floating player within the available area, in points. `nil` = use the
    /// default position for the current size mode (top-right for Compact, center for S/M/L). Persisted
    /// so the player reopens at the same position; clamping at display time handles window resizes.
    var playerFloatingPosition: CGPoint? = nil {
        didSet {
            guard playerFloatingPosition != oldValue else { return }
            if let p = playerFloatingPosition {
                UserDefaults.standard.set(Double(p.x), forKey: Self.playerFloatingPositionXKey)
                UserDefaults.standard.set(Double(p.y), forKey: Self.playerFloatingPositionYKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.playerFloatingPositionXKey)
                UserDefaults.standard.removeObject(forKey: Self.playerFloatingPositionYKey)
            }
        }
    }

    /// True while the player is in true (borderless, edge-to-edge) full-screen.
    var isPlayerFullScreen: Bool = false {
        didSet {
            if isPlayerFullScreen {
                // Entering full-screen: remember it for "Last used size".
                playerLastWasFullScreen = true
            } else if isPlayingInline {
                // Exiting full-screen while still playing means the user explicitly shifted back to
                // windowed — clear the flag so the next session doesn't re-open full-screen.
                // (When playback stops, isPlayingInline is already false before this fires, so
                // stopping from full-screen still reopens full-screen under "Last used size".)
                playerLastWasFullScreen = false
            }
        }
    }

    /// Persisted: was the player last in full-screen (for the "Last used size" start preference)?
    var playerLastWasFullScreen: Bool = false {
        didSet {
            guard playerLastWasFullScreen != oldValue else { return }
            UserDefaults.standard.set(playerLastWasFullScreen, forKey: Self.playerLastWasFullScreenKey)
        }
    }

    /// Sticky "compact" mode preference: while active *and* the Inspector is visible, the player's
    /// size is the live inspector still/filmstrip footprint. Cleared when the user picks Windowed
    /// or resizes. Persisted. Compact does not apply while the Inspector is hidden — see
    /// `isPlayerCompactMode`.
    var playerSizeIsCompact: Bool = false {
        didSet {
            guard playerSizeIsCompact != oldValue else { return }
            UserDefaults.standard.set(playerSizeIsCompact, forKey: Self.playerSizeIsCompactKey)
        }
    }

    /// Effective Compact layout: Inspector footprint only while the Inspector pane is showing.
    /// Hiding the Inspector promotes the on-screen player to Windowed without clearing the
    /// Compact preference, so showing the Inspector again restores Compact.
    var isPlayerCompactMode: Bool {
        playerSizeIsCompact && isInspectorVisible
    }

    /// Enter or leave Compact. No-ops entering Compact while the Inspector is hidden.
    func setPlayerCompactMode(_ compact: Bool) {
        guard compact else {
            playerSizeIsCompact = false
            return
        }
        guard isInspectorVisible else { return }
        playerSizeIsCompact = true
        playerFloatingPosition = nil
        playerLastWasFullScreen = false
    }

    /// Preferred size the player opens at when playback starts.
    var playerStartPreference: PlayerStartPreference = .lastSize {
        didSet {
            guard playerStartPreference != oldValue else { return }
            UserDefaults.standard.set(playerStartPreference.rawValue, forKey: Self.playerStartPreferenceKey)
        }
    }

    /// How the Inspector's "Add tags" blind behaves on each new selection.
    var tagBlindDefaultState: TagBlindDefaultState = .alwaysClosed {
        didSet {
            guard tagBlindDefaultState != oldValue else { return }
            UserDefaults.standard.set(tagBlindDefaultState.rawValue, forKey: Self.tagBlindDefaultStateKey)
        }
    }

    /// When true, the “Resumed at … / Start at beginning” banner in inline playback fades out after `resumeBannerFadeDelaySeconds`.
    var fadeResumeBannerAutomatically: Bool = false {
        didSet {
            UserDefaults.standard.set(fadeResumeBannerAutomatically, forKey: Self.fadeResumeBannerAutomaticallyKey)
        }
    }

    /// Delay before the resume banner begins its fade (seconds). Clamped 1…120 when set.
    var resumeBannerFadeDelaySeconds: Int = 5 {
        didSet {
            let clamped = min(max(resumeBannerFadeDelaySeconds, 1), 120)
            if clamped != resumeBannerFadeDelaySeconds {
                resumeBannerFadeDelaySeconds = clamped
            } else {
                UserDefaults.standard.set(clamped, forKey: Self.resumeBannerFadeDelaySecondsKey)
            }
        }
    }

    var defaultFilmstripRows: Int = 2 {
        didSet {
            UserDefaults.standard.set(defaultFilmstripRows, forKey: Self.filmstripRowsKey)
        }
    }

    var defaultFilmstripColumns: Int = 5 {
        didSet {
            UserDefaults.standard.set(defaultFilmstripColumns, forKey: Self.filmstripColumnsKey)
        }
    }

    private(set) var lastAppliedFilmstripRows: Int = 2
    private(set) var lastAppliedFilmstripColumns: Int = 5

    var filmstripLayoutChanged: Bool {
        defaultFilmstripRows != lastAppliedFilmstripRows || defaultFilmstripColumns != lastAppliedFilmstripColumns
    }

    var showThumbnailInDetail: Bool = true {
        didSet {
            UserDefaults.standard.set(showThumbnailInDetail, forKey: Self.showThumbnailInDetailKey)
        }
    }

    /// Schema for per-video custom metadata — scoped to the active library database.
    var customMetadataFieldDefinitions: [CustomMetadataFieldDefinition] = [] {
        didSet {
            guard !_loadingCustomMetadataFieldDefinitions else { return }
            saveCustomMetadataFieldDefinitions()
        }
    }

    private var _loadingCustomMetadataFieldDefinitions = false

    /// Which standard/custom columns appear in list view (Name is always shown).
    var listColumnPreferences: ListColumnPreferences = .default {
        didSet {
            guard !_loadingListColumnPreferences else { return }
            saveListColumnPreferences()
            scheduleListCustomMetadataRefresh()
        }
    }

    /// Cached custom metadata for list cells, keyed by `Video.databaseId` then field UUID.
    private(set) var listCustomMetadataByVideoId: [Int64: [UUID: String]] = [:]

    private var _loadingListColumnPreferences = false
    private var listCustomMetadataRefreshTask: Task<Void, Never>?

    func isStandardListColumnVisible(_ id: String) -> Bool {
        listColumnPreferences.visibleStandardColumnIDs.contains(id)
    }

    func setStandardListColumnVisible(_ id: String, visible: Bool) {
        guard ListColumnPreferences.optionalStandardColumnIDs.contains(id) else { return }
        var p = listColumnPreferences
        if visible {
            p.visibleStandardColumnIDs.insert(id)
        } else {
            p.visibleStandardColumnIDs.remove(id)
        }
        listColumnPreferences = p
    }

    func setCustomListFieldVisible(fieldId: UUID, visible: Bool) {
        var p = listColumnPreferences
        if visible {
            p.visibleCustomFieldIDs.insert(fieldId)
        } else {
            p.visibleCustomFieldIDs.remove(fieldId)
        }
        listColumnPreferences = p
    }

    func isCustomListFieldVisible(_ fieldId: UUID) -> Bool {
        listColumnPreferences.visibleCustomFieldIDs.contains(fieldId)
    }

    /// All non-text custom fields available as list columns (alphabetical; at most 16 — SwiftUI `Table` limit).
    /// Used to emit all columns so they appear in the column header right-click menu.
    var allCustomFieldsForList: [CustomMetadataFieldDefinition] {
        Array(
            customMetadataFieldDefinitions
                .filter { $0.valueType != .text }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .prefix(16)
        )
    }

    /// Returns true if the custom field column should be shown by default (user toggled it on via Settings).
    func isCustomFieldDefaultVisible(_ id: UUID) -> Bool {
        listColumnPreferences.visibleCustomFieldIDs.contains(id)
    }

    /// Custom columns shown in list view (alphabetical; at most 16 — SwiftUI `Table` column builder limit).
    var visibleCustomFieldsForList: [CustomMetadataFieldDefinition] {
        let visible = listColumnPreferences.visibleCustomFieldIDs
        return Array(
            customMetadataFieldDefinitions
                .filter { visible.contains($0.id) && $0.valueType != .text }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .prefix(16)
        )
    }

    func listCustomFieldDisplay(for video: Video, field: CustomMetadataFieldDefinition) -> String {
        guard let vid = video.databaseId,
              let raw = listCustomMetadataByVideoId[vid]?[field.id]
        else {
            return "—"
        }
        return ListCustomMetadataCellFormatter.display(raw: raw, valueType: field.valueType)
    }

    /// Bumps `Table` identity when the column set or default-visibility state changes.
    var listColumnConfigurationSignature: String {
        let s = listColumnPreferences.visibleStandardColumnIDs.sorted().joined(separator: ",")
        // Track which non-text fields exist AND which are default-visible, so toggling from Settings
        // triggers a table rebuild that re-applies defaultVisibility.
        let c = allCustomFieldsForList
            .map { "\($0.id.uuidString):\(listColumnPreferences.visibleCustomFieldIDs.contains($0.id) ? "1" : "0")" }
            .joined(separator: ",")
        return "\(s)|\(c)"
    }

    private func saveListColumnPreferences() {
        guard let data = try? JSONEncoder().encode(listColumnPreferences) else { return }
        UserDefaults.standard.set(data, forKey: Self.listColumnPreferencesKey)
    }

    private func scheduleListCustomMetadataRefresh() {
        listCustomMetadataRefreshTask?.cancel()
        listCustomMetadataRefreshTask = Task { @MainActor in
            await refreshListCustomMetadataCacheIfNeeded()
        }
    }

    private func refreshListCustomMetadataCacheIfNeeded() async {
        guard !customMetadataFieldDefinitions.isEmpty else {
            listCustomMetadataByVideoId = [:]
            return
        }
        let ids = videos.compactMap(\.databaseId)
        guard !ids.isEmpty else {
            listCustomMetadataByVideoId = [:]
            return
        }
        do {
            let raw = try await videoRepo.fetchCustomMetadata(forVideoIds: ids)
            var result: [Int64: [UUID: String]] = [:]
            for (vid, fields) in raw {
                var m: [UUID: String] = [:]
                for (k, v) in fields {
                    if let u = UUID(uuidString: k) { m[u] = v }
                }
                result[vid] = m
            }
            listCustomMetadataByVideoId = result
        } catch {
            listCustomMetadataByVideoId = [:]
        }
    }

    private func mergeListCustomMetadataCache(videoId: Int64, fieldId: UUID, value: String) {
        guard customMetadataFieldDefinitions.contains(where: { $0.id == fieldId }) else { return }
        var inner = listCustomMetadataByVideoId[videoId] ?? [:]
        inner[fieldId] = value
        listCustomMetadataByVideoId[videoId] = inner
    }

    func addCustomMetadataField() {
        let n = customMetadataFieldDefinitions.count + 1
        addCustomMetadataField(name: "Field \(n)", valueType: .string)
    }

    /// Add a custom metadata field with an explicit name and type (Import Metadata unknown columns).
    /// Skips if a field with the same name already exists (case-insensitive).
    @discardableResult
    func addCustomMetadataField(name: String, valueType: CustomMetadataValueType) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = customMetadataFieldDefinitions.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return existing.id
        }
        let field = CustomMetadataFieldDefinition(name: trimmed, valueType: valueType)
        customMetadataFieldDefinitions.append(field)
        return field.id
    }

    func removeCustomMetadataFields(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        customMetadataFieldDefinitions.removeAll { ids.contains($0.id) }
        var p = listColumnPreferences
        p.visibleCustomFieldIDs.subtract(ids)
        listColumnPreferences = p
        try? videoRepo.deleteCustomMetadata(fieldIds: ids)
        refreshSearchIfActive()
    }

    func updateCustomMetadataFieldName(id: UUID, name: String) {
        guard let i = customMetadataFieldDefinitions.firstIndex(where: { $0.id == id }) else { return }
        customMetadataFieldDefinitions[i].name = name
    }

    func updateCustomMetadataFieldType(id: UUID, valueType: CustomMetadataValueType) {
        guard let i = customMetadataFieldDefinitions.firstIndex(where: { $0.id == id }) else { return }
        customMetadataFieldDefinitions[i].valueType = valueType
    }

    private func saveCustomMetadataFieldDefinitions() {
        try? customMetadataFieldRepo.replaceAll(customMetadataFieldDefinitions)
    }

    /// Loads definitions from the library DB. If the table is empty, seeds once from the legacy
    /// global UserDefaults key (so existing libraries keep field UUIDs / values) without clearing
    /// prefs — each library can seed independently.
    private func loadCustomMetadataFieldDefinitions() {
        _loadingCustomMetadataFieldDefinitions = true
        defer { _loadingCustomMetadataFieldDefinitions = false }

        do {
            var fields = try customMetadataFieldRepo.fetchAll()
            if fields.isEmpty,
               let data = UserDefaults.standard.data(forKey: Self.customMetadataFieldDefinitionsKey),
               let decoded = try? JSONDecoder().decode([CustomMetadataFieldDefinition].self, from: data),
               !decoded.isEmpty
            {
                fields = decoded
                try customMetadataFieldRepo.replaceAll(fields)
            }
            customMetadataFieldDefinitions = fields
        } catch {
            customMetadataFieldDefinitions = []
        }
    }

    // MARK: - Layout (browsing vs playback)

    var browsingLayout: LayoutParams = .browsingDefaults() {
        didSet { saveLayout() }
    }

    private var _applyingLayout = false

    /// The single live layout. Playback no longer reshapes the browser (Wall + Inspector layout), so
    /// browsing and playback share one layout.
    var effectiveLayout: LayoutParams { browsingLayout }

    var effectiveDetailHeight: CGFloat { CGFloat(effectiveLayout.detailVideoHeight) }
    var effectiveDetailWidth: CGFloat { CGFloat(effectiveLayout.detailColumnWidth(for: viewMode)) }
    var effectiveContentWidth: CGFloat { CGFloat(effectiveLayout.contentColumnWidth(for: viewMode)) }
    var effectiveSidebarWidth: CGFloat { CGFloat(effectiveLayout.sidebarWidth) }

    var columnCustomization = TableColumnCustomization<Video>() {
        didSet {
            guard !_applyingLayout else { return }
            updateCurrentLayoutFromLive()
        }
    }

    private var layoutSaveTask: DispatchWorkItem?

    private func saveLayout() {
        layoutSaveTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Self.encodeLayoutToUserDefaults(self.browsingLayout)
        }
        layoutSaveTask = work
        // Next run loop coalesces rapid updates; no delay so quit-after-drag still persists.
        DispatchQueue.main.async(execute: work)
    }

    /// Writes layout JSON immediately (used when split views report sizes; does not rely on `didSet` / debounce).
    private static func encodeLayoutToUserDefaults(_ layout: LayoutParams) {
        let safe = layout.sanitized()
        guard let data = try? JSONEncoder().encode(safe) else { return }
        UserDefaults.standard.set(data, forKey: browsingLayoutKey)
    }

    /// Apply a layout to the live UI properties. Call when switching modes.
    /// When preserveViewModeAndGridSize is true (e.g. switching to playback), keeps current viewMode and gridSize
    /// so the user stays in grid/list as they were, while applying sizes and sidebar from the layout.
    func applyLayout(_ layout: LayoutParams, preserveViewModeAndGridSize: Bool = false) {
        _applyingLayout = true
        defer { _applyingLayout = false }
        if !preserveViewModeAndGridSize {
            if let mode = ViewMode(rawValue: layout.viewMode) { viewMode = mode }
            if let size = GridSize(rawValue: layout.gridSize) { gridSize = size }
            if let data = layout.columnCustomizationData,
               let saved = try? JSONDecoder().decode(TableColumnCustomization<Video>.self, from: data)
            {
                columnCustomization = saved
            }
        }
    }

    /// Persist current live values (view mode, grid size, sidebar, columns) to the active mode's layout.
    func updateCurrentLayoutFromLive() {
        let base = effectiveLayout
        let colData = (try? JSONEncoder().encode(columnCustomization)) ?? base.columnCustomizationData
        let layout = LayoutParams(
            sidebarWidth: base.sidebarWidth,
            contentWidthGrid: base.contentWidthGrid,
            detailWidthGrid: base.detailWidthGrid,
            contentWidthList: base.contentWidthList,
            detailWidthList: base.detailWidthList,
            browserTopPaneHeightGrid: base.browserTopPaneHeightGrid,
            browserTopPaneHeightList: base.browserTopPaneHeightList,
            detailVideoHeight: base.detailVideoHeight,
            columnCustomizationData: colData,
            viewMode: viewMode.rawValue,
            gridSize: gridSize.rawValue
        )
        browsingLayout = layout.sanitized()
    }

    /// Update layout with new size values from resize gestures. Call when user drags a divider.
    func updateCurrentLayoutWithSizes(
        sidebarWidth: CGFloat? = nil,
        contentWidth: CGFloat? = nil,
        detailWidth: CGFloat? = nil,
        browserTopPaneHeight: CGFloat? = nil,
        detailVideoHeight: CGFloat? = nil
    ) {
        let base = effectiveLayout
        var updated = LayoutParams.from(playback: base)
        // Always carry live table column widths; `base` may have stale columnCustomizationData
        // (e.g. browsing snapshot from before playback while list was customized during playback).
        updated.columnCustomizationData = (try? JSONEncoder().encode(columnCustomization)) ?? base.columnCustomizationData
        if let w = sidebarWidth { updated.sidebarWidth = Double(w) }
        if let w = contentWidth {
            switch viewMode {
            case .grid, .storyboard: updated.contentWidthGrid = Double(w)
            case .list: updated.contentWidthList = Double(w)
            }
        }
        if let w = detailWidth, w >= 100 {
            switch viewMode {
            case .grid, .storyboard: updated.detailWidthGrid = Double(w)
            case .list: updated.detailWidthList = Double(w)
            }
        }
        if let h = browserTopPaneHeight {
            switch viewMode {
            case .grid, .storyboard: updated.browserTopPaneHeightGrid = Double(h)
            case .list: updated.browserTopPaneHeightList = Double(h)
            }
        }
        if let h = detailVideoHeight { updated.detailVideoHeight = Double(h) }
        let fixed = updated.sanitized()
        browsingLayout = fixed
        // Always persist split sizes immediately (Observable may coalesce equal structs; didSet save is async).
        Self.encodeLayoutToUserDefaults(fixed)
    }

    func selectBuiltinSort(_ sort: VideoSort, ascending: Bool) {
        // tableSortOrder.didSet clears customSortFieldId and recomputes.
        tableSortOrder = sort.comparators(ascending: ascending)
    }

    /// Restore the album's saved playlist order (and exit Shuffle).
    func selectAlbumOrder() {
        guard isViewingAlbum else { return }
        usesAlbumManualOrder = true
        isRandomOrder = false
        recomputeFilteredVideos()
    }

    func selectCustomSort(fieldId: UUID, ascending: Bool) {
        let slot = allCustomFieldsForList.firstIndex { $0.id == fieldId } ?? 0
        pendingScrollAfterSortId = selectedVideoIds.count == 1 ? selectedVideoIds.first : nil
        if isViewingAlbum {
            usesAlbumManualOrder = false
        }
        // Update tableSortOrder to show the caret on the correct custom column, suppressing didSet side-effects.
        _settingCustomSortOrder = true
        tableSortOrder = [KeyPathComparator(Video.customSortKeyPath(slot: slot), order: ascending ? .forward : .reverse)]
        _settingCustomSortOrder = false
        customSortAscending = ascending
        customSortFieldId = fieldId  // didSet → recomputeFilteredVideos + savePreferences
    }

    func savePreferences() {
        let defaults = UserDefaults.standard
        if let fieldId = customSortFieldId {
            defaults.set("custom:\(fieldId.uuidString)", forKey: Self.sortColumnKey)
            defaults.set(customSortAscending, forKey: Self.sortAscendingKey)
        } else if let first = tableSortOrder.first {
            let sort = VideoSort.from(keyPath: first.keyPath)
            defaults.set(sort.rawValue, forKey: Self.sortColumnKey)
            defaults.set(first.order == .forward, forKey: Self.sortAscendingKey)
        }
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if let sortRaw = defaults.string(forKey: Self.sortColumnKey) {
            // `bool(forKey:)` is false when missing — only trust it if the key was written.
            let ascending: Bool
            if defaults.object(forKey: Self.sortAscendingKey) != nil {
                ascending = defaults.bool(forKey: Self.sortAscendingKey)
            } else {
                ascending = true
            }
            if sortRaw.hasPrefix("custom:"),
               let uuid = UUID(uuidString: String(sortRaw.dropFirst("custom:".count)))
            {
                // Direction first so customSortFieldId.didSet recomputes with the saved order.
                customSortAscending = ascending
                customSortFieldId = uuid
            } else if let sort = VideoSort(rawValue: sortRaw) {
                _loadingSortPreferences = true
                tableSortOrder = sort.comparators(ascending: ascending)
                _loadingSortPreferences = false
            }
        }
        excludeCorrupt = defaults.bool(forKey: Self.excludeCorruptKey)
        confirmDeletions = defaults.object(forKey: Self.confirmDeletionsKey) as? Bool ?? true
        surpriseMeAutoPlays = defaults.object(forKey: Self.surpriseMeAutoPlaysKey) as? Bool ?? true
        playAllLoops = defaults.object(forKey: Self.playAllLoopsKey) as? Bool
            ?? defaults.bool(forKey: "Skagway.albumPlaylistLoops")
        gridHoverPreviewEnabled = defaults.object(forKey: Self.gridHoverPreviewEnabledKey) as? Bool ?? true
        if let raw = defaults.string(forKey: Self.storyboardDensityKey) {
            // Pre-1.3.x stored "comfortable" for the roomier packing — map to Normal.
            if raw == "comfortable" {
                storyboardDensity = .normal
                defaults.set(StoryboardDensity.normal.rawValue, forKey: Self.storyboardDensityKey)
            } else if let density = StoryboardDensity(rawValue: raw) {
                storyboardDensity = density
            }
        }
        if let w = defaults.object(forKey: Self.playerFloatingWidthKey) as? Double, w > 0,
           let h = defaults.object(forKey: Self.playerFloatingHeightKey) as? Double, h > 0 {
            playerFloatingSize = CGSize(width: w, height: h)
        }
        if let x = defaults.object(forKey: Self.playerFloatingPositionXKey) as? Double,
           let y = defaults.object(forKey: Self.playerFloatingPositionYKey) as? Double,
           x > 0, y > 0 {
            playerFloatingPosition = CGPoint(x: x, y: y)
        }
        if let raw = defaults.string(forKey: Self.playerStartPreferenceKey),
           let pref = PlayerStartPreference(rawValue: raw) {
            playerStartPreference = pref
        }
        if let raw = defaults.string(forKey: Self.tagBlindDefaultStateKey),
           let state = TagBlindDefaultState(rawValue: raw) {
            tagBlindDefaultState = state
        }
        if defaults.object(forKey: Self.playerSizeIsCompactKey) != nil {
            playerSizeIsCompact = defaults.bool(forKey: Self.playerSizeIsCompactKey)
        }
        if defaults.object(forKey: Self.playerLastWasFullScreenKey) != nil {
            playerLastWasFullScreen = defaults.bool(forKey: Self.playerLastWasFullScreenKey)
        }
        if defaults.object(forKey: Self.fadeResumeBannerAutomaticallyKey) != nil {
            fadeResumeBannerAutomatically = defaults.bool(forKey: Self.fadeResumeBannerAutomaticallyKey)
        }
        if let sec = defaults.object(forKey: Self.resumeBannerFadeDelaySecondsKey) as? Int, sec >= 1 {
            resumeBannerFadeDelaySeconds = min(sec, 120)
        }
        if let rows = defaults.object(forKey: Self.filmstripRowsKey) as? Int, rows > 0 {
            defaultFilmstripRows = rows
        }
        if let cols = defaults.object(forKey: Self.filmstripColumnsKey) as? Int, cols > 0 {
            defaultFilmstripColumns = cols
        }
        if let rows = defaults.object(forKey: Self.lastAppliedFilmstripRowsKey) as? Int, rows > 0 {
            lastAppliedFilmstripRows = rows
        } else {
            lastAppliedFilmstripRows = defaultFilmstripRows
        }
        if let cols = defaults.object(forKey: Self.lastAppliedFilmstripColumnsKey) as? Int, cols > 0 {
            lastAppliedFilmstripColumns = cols
        } else {
            lastAppliedFilmstripColumns = defaultFilmstripColumns
        }
        if let days = defaults.object(forKey: Self.recentlyAddedDaysKey) as? Int, days > 0 {
            recentlyAddedDays = days
        }
        if let days = defaults.object(forKey: Self.recentlyPlayedDaysKey) as? Int, days > 0 {
            recentlyPlayedDays = days
        }
        if let rating = defaults.object(forKey: Self.topRatedMinRatingKey) as? Int, rating >= 1 {
            topRatedMinRating = rating
        }
        if let v = defaults.object(forKey: Self.showRecentlyAddedKey) as? Bool { showRecentlyAdded = v }
        if let v = defaults.object(forKey: Self.showRecentlyPlayedKey) as? Bool { showRecentlyPlayed = v }
        if let v = defaults.object(forKey: Self.showTopRatedKey) as? Bool { showTopRated = v }
        if let v = defaults.object(forKey: Self.showDuplicatesKey) as? Bool { showDuplicates = v }
        if let v = defaults.object(forKey: Self.showCorruptKey) as? Bool { showCorrupt = v }
        if let v = defaults.string(forKey: Self.ffmpegPathKey) { ffmpegUserPath = v }
        if let v = defaults.object(forKey: Self.showMissingKey) as? Bool { showMissing = v }
        if let v = defaults.object(forKey: Self.showRecentlyConvertedKey) as? Bool { showRecentlyConverted = v }
        if let paths = defaults.stringArray(forKey: Self.recentlyAppliedPathsKey) {
            recentlyAppliedPaths = Set(paths)
        }
        if let paths = defaults.stringArray(forKey: Self.lastAddedPathsKey) {
            lastAddedPaths = Set(paths)
        }
        if let data = defaults.data(forKey: Self.conversionJobsKey),
           let decoded = try? JSONDecoder().decode([ConversionJob].self, from: data)
        {
            conversionJobs = decoded
        } else if let data = defaults.data(forKey: Self.recentlyConvertedEntriesKey),
                  let legacy = try? JSONDecoder().decode([ConvertedEntry].self, from: data)
        {
            // One-time migration from the old "recently converted" list into completed jobs.
            conversionJobs = legacy.map { ConversionJob(migratedConvertedPath: $0.path, date: $0.date) }
        }
        conversionJobs.removeAll { $0.isExpired() }
        if let data = defaults.data(forKey: Self.moveJobsKey),
           let decoded = try? JSONDecoder().decode([MoveJob].self, from: data)
        {
            moveJobs = decoded
        }
        if let v = defaults.object(forKey: Self.missingCountScannedKey) as? Bool { missingCountScanned = v }
        if let v = defaults.object(forKey: Self.filtersDrawerHeightKey) as? Double {
            filtersDrawerHeight = max(CGFloat(v), Self.filtersDrawerMinHeight)
        }
        if let v = defaults.string(forKey: Self.filterDrawerHeightModeKey),
           let mode = FilterDrawerHeightMode(rawValue: v) {
            filterDrawerHeightMode = mode
        }
        if let v = defaults.string(forKey: Self.filtersDrawerModeKey),
           let mode = FiltersDrawerMode(rawValue: v) {
            filtersDrawerMode = mode
        }
        if let v = defaults.object(forKey: Self.inspectorHeroHeightKey) as? Double {
            inspectorHeroHeight = max(CGFloat(v), Self.inspectorHeroMinHeight)
        }
        if defaults.object(forKey: Self.inspectorVisibleKey) != nil {
            isInspectorVisible = defaults.bool(forKey: Self.inspectorVisibleKey)
        }
        if let ids = defaults.stringArray(forKey: Self.missingVideoIdsKey) { missingVideoIds = Set(ids) }
        if defaults.object(forKey: Self.showThumbnailInDetailKey) != nil {
            showThumbnailInDetail = defaults.bool(forKey: Self.showThumbnailInDetailKey)
        }
        loadCustomMetadataFieldDefinitions()

        _loadingListColumnPreferences = true
        if let data = defaults.data(forKey: Self.listColumnPreferencesKey),
           let decoded = try? JSONDecoder().decode(ListColumnPreferences.self, from: data)
        {
            listColumnPreferences = decoded.sanitized(
                knownCustomFieldIds: Set(customMetadataFieldDefinitions.map(\.id))
            )
        } else {
            listColumnPreferences = .default
        }
        _loadingListColumnPreferences = false

        // Load layouts (with migration from legacy keys)
        if let data = defaults.data(forKey: Self.browsingLayoutKey),
           let layout = try? JSONDecoder().decode(LayoutParams.self, from: data)
        {
            browsingLayout = layout.sanitized()
        } else {
            // Migrate from legacy keys
            var migrated = LayoutParams.browsingDefaults()
            if let h = defaults.object(forKey: "Skagway.detailHeight") as? Double, h > 0 {
                migrated.detailVideoHeight = h
            }
            if let w = defaults.object(forKey: "Skagway.detailWidth") as? Double, w > 0 {
                migrated.detailWidthGrid = w
                migrated.detailWidthList = w
            }
            if let data = defaults.data(forKey: "Skagway.columnCustomization"),
               let _ = try? JSONDecoder().decode(TableColumnCustomization<Video>.self, from: data)
            {
                migrated.columnCustomizationData = data
            }
            if let modeRaw = defaults.string(forKey: Self.viewModeKey),
               let _ = ViewMode(rawValue: modeRaw) { migrated.viewMode = modeRaw }
            if let sizeRaw = defaults.string(forKey: Self.gridSizeKey),
               let _ = GridSize(rawValue: sizeRaw) { migrated.gridSize = sizeRaw }
            browsingLayout = migrated.sanitized()
        }
        applyLayout(browsingLayout)
        // One-shot migrate: nested Wall Storyboard toggle → first-class ViewMode.storyboard
        // (must run after applyLayout so layout's viewMode does not overwrite it).
        if defaults.string(forKey: Self.gridDisplayModeKey) == "storyboard" {
            viewMode = .storyboard
            updateCurrentLayoutFromLive()
        }
        defaults.removeObject(forKey: Self.gridDisplayModeKey)
    }

    func startObserving() {
        observationTask?.cancel()

        observationTask = Task { [dbPool] in
            let observation = ValueObservation.tracking { db in
                try Video.order(Column("dateAdded").desc).fetchAll(db)
            }
            do {
                for try await videos in observation.values(in: dbPool) {
                    await MainActor.run {
                        if self.discardObservationDeliveries > 0 {
                            self.discardObservationDeliveries -= 1
                            return
                        }
                        self.videos = videos
                        self.hasCompletedInitialVideoLoad = true
                        // Kick off the fingerprint backfill from *here* — the first delivery is when
                        // `videos` is actually populated. Calling it from `startObserving` ran it
                        // against an empty array (observation is async), so it silently no-op'd and
                        // existing videos never got fingerprinted → Duplicates couldn't match them.
                        self.kickOffFingerprintBackfillIfNeeded()
                    }
                }
            } catch {
                if !Task.isCancelled {
                    print("Video observation error: \(error)")
                    await MainActor.run {
                        self.hasCompletedInitialVideoLoad = true
                        self.reportTransientError("Library updates paused: \(error.localizedDescription)")
                    }
                }
            }
        }

        Task {
            await loadTags()
            await loadCollections()
            await loadNotDuplicatePairs()
        }

        resumePendingConversions()
        resumePendingMoves()
        Task { await sweepInterruptedBulkRenameTemps() }
    }

    /// Once per app session (after videos first load), start the fingerprint backfill. The
    /// once-per-session flag prevents an unreachable-file loop: files whose fingerprint can't be
    /// computed stay nil, and re-running on every observation delivery would keep retrying them.
    private func kickOffFingerprintBackfillIfNeeded() {
        guard !didKickOffFingerprintBackfill, !videos.isEmpty else { return }
        didKickOffFingerprintBackfill = true
        backfillContentFingerprintsIfNeeded()
    }

    private func loadNotDuplicatePairs() async {
        let pairs = (try? await videoRepo.fetchNotDuplicatePairs()) ?? []
        notDuplicatePairs = Set(pairs.map { NotDuplicateKey($0.videoIdA, $0.videoIdB) })
        updateLibraryCounts()
        recomputeFilteredVideos()
    }

    /// One-time (per launch, until every reachable file has one) computation of content
    /// fingerprints for videos that lack one. Runs off-main and writes in chunks so progress
    /// persists (survives a quit mid-pass) and Duplicates fills in progressively instead of only
    /// after the whole library has been read.
    private func backfillContentFingerprintsIfNeeded() {
        guard !isBackfillingFingerprints else { return }
        struct Row: Sendable { let dbId: Int64; let filePath: String }
        let pending: [Row] = videos.compactMap { v in
            guard v.contentFingerprint == nil, let id = v.databaseId else { return nil }
            return Row(dbId: id, filePath: v.filePath)
        }
        guard !pending.isEmpty else { return }
        isBackfillingFingerprints = true

        Task { [videoRepo] in
            // Let launch settle (initial thumbnail/preview work) before doing a bunch of file
            // reads, so the backfill doesn't compete with getting the UI on screen.
            try? await Task.sleep(for: .seconds(3))
            fingerprintBackfillTotal = pending.count
            fingerprintBackfillDone = 0
            defer { fingerprintBackfillTotal = 0; fingerprintBackfillDone = 0 }
            let chunkSize = 300
            var index = 0
            while index < pending.count {
                let end = min(index + chunkSize, pending.count)
                let chunk = Array(pending[index..<end])
                // Compute this chunk's fingerprints off-main, in parallel (bounded), so the pass
                // isn't gated on one file at a time.
                let updates: [(videoId: Int64, fingerprint: String)] = await Task.detached(priority: .utility) {
                    await withTaskGroup(of: (Int64, String)?.self) { group in
                        let maxConcurrent = 6
                        var iterator = chunk.makeIterator()
                        var inFlight = 0
                        func addNext() {
                            guard let row = iterator.next() else { return }
                            inFlight += 1
                            group.addTask {
                                ContentFingerprint.compute(url: URL(fileURLWithPath: row.filePath)).map { (row.dbId, $0) }
                            }
                        }
                        for _ in 0..<maxConcurrent { addNext() }
                        var out: [(Int64, String)] = []
                        while inFlight > 0 {
                            let result = await group.next()
                            inFlight -= 1
                            if let pair = result ?? nil { out.append(pair) }
                            addNext()
                        }
                        return out.map { (videoId: $0.0, fingerprint: $0.1) }
                    }
                }.value
                if !updates.isEmpty {
                    // Each chunk write triggers one observation delivery → one recompute, so
                    // Duplicates updates as the pass proceeds and the work is saved incrementally.
                    try? await videoRepo.updateContentFingerprint(updates: updates)
                }
                index = end
                fingerprintBackfillDone = end   // processed so far (drives the header status)
            }
            isBackfillingFingerprints = false
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - FTS5 Search

    /// Refreshes ftsMatchIds when videos change (e.g. after rename) so search results stay correct.
    private func refreshSearchIfActive() {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task {
            do {
                let results = try await videoRepo.search(trimmed)
                guard !Task.isCancelled else { return }
                ftsMatchIds = Set(results.map(\.id))
            } catch {
                guard !Task.isCancelled else { return }
                ftsMatchIds = nil
            }
            recomputeFilteredVideos()
        }
    }

    private func debouncedSearch() {
        searchTask?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            ftsMatchIds = nil
            recomputeFilteredVideos()
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let results = try await videoRepo.search(trimmed)
                guard !Task.isCancelled else { return }
                ftsMatchIds = Set(results.map(\.id))
            } catch {
                guard !Task.isCancelled else { return }
                ftsMatchIds = nil
            }
            recomputeFilteredVideos()
        }
    }

    // MARK: - Cached Filter/Sort

    private static func isCorrupt(_ video: Video, thumbnailsSettled: Bool) -> Bool {
        VideoIntegrity.isCorrupt(video, thumbnailsSettled: thumbnailsSettled)
    }

    private func recomputeFilteredVideos() {
        filterGeneration += 1
        let gen = filterGeneration
        let resolvedCustomSortField = customSortFieldId.flatMap { id in
            customMetadataFieldDefinitions.first { $0.id == id }
        }
        let customFieldDefinitionsById = Dictionary(
            uniqueKeysWithValues: customMetadataFieldDefinitions.map { ($0.id, $0) }
        )
        let snapshot = FilterSnapshot(
            videos: videos,
            tagsByVideoId: tagsByVideoId,
            collections: collections,
            cachedCollectionRules: cachedCollectionRules,
            cachedCollectionRuleGroups: cachedCollectionRuleGroups,
            cachedAlbumVideoIds: cachedAlbumVideoIds,
            sidebarFilter: sidebarFilter,
            selectedTagIds: selectedTagIds,
            tagFilterMode: tagFilterMode,
            selectedRatingStars: selectedRatingStars,
            ratingFilterOrHigher: ratingFilterOrHigher,
            tableSortOrder: tableSortOrder,
            excludeCorrupt: excludeCorrupt,
            thumbnailsSettled: thumbnailsSettled,
            searchText: searchText,
            ftsMatchIds: ftsMatchIds,
            duplicateVideoIds: duplicateVideoIds,
            missingVideoIds: missingVideoIds,
            recentlyAddedDays: recentlyAddedDays,
            recentlyPlayedDays: recentlyPlayedDays,
            topRatedMinRating: topRatedMinRating,
            recentlyConvertedDates: recentlyConvertedDates,
            recentlyAppliedPaths: recentlyAppliedPaths,
            lastAddedPaths: lastAddedPaths,
            minDurationSeconds: minDurationSeconds,
            maxDurationSeconds: maxDurationSeconds,
            selectedQualityBuckets: selectedQualityBuckets,
            customFieldDefinitionsById: customFieldDefinitionsById,
            advancedFilterGroup: advancedFilterGroup,
            filtersDrawerMode: filtersDrawerMode,
            customSortField: resolvedCustomSortField,
            customSortAscending: customSortAscending,
            listCustomMetadataByVideoId: listCustomMetadataByVideoId,
            isRandomOrder: isRandomOrder,
            randomOrderRanks: randomOrderRanks,
            usesAlbumManualOrder: usesAlbumManualOrder && isViewingAlbum
        )
        let repo = collectionRepo

        Task.detached(priority: .userInitiated) {
            let result = Self.computeFilteredResult(snapshot: snapshot, collectionRepo: repo)
            await MainActor.run {
                guard gen == self.filterGeneration else { return }
                self.applyFilteredVideos(result.videos)
                self.tagCounts = result.tagCounts
            }
        }
    }

    private struct FilterSnapshot {
        let videos: [Video]
        let tagsByVideoId: [Int64: [Tag]]
        let collections: [VideoCollection]
        let cachedCollectionRules: [Int64: [CollectionRule]]
        let cachedCollectionRuleGroups: [Int64: [CollectionRuleGroup]]
        let cachedAlbumVideoIds: [Int64: [Int64]]
        let sidebarFilter: SidebarFilter?
        let selectedTagIds: Set<Int64>
        let tagFilterMode: MatchMode
        let selectedRatingStars: Set<Int>
        let ratingFilterOrHigher: Bool
        let tableSortOrder: [KeyPathComparator<Video>]
        let excludeCorrupt: Bool
        let thumbnailsSettled: Bool
        let searchText: String
        let ftsMatchIds: Set<String>?
        let duplicateVideoIds: Set<String>
        let missingVideoIds: Set<String>
        let recentlyAddedDays: Int
        let recentlyPlayedDays: Int
        let topRatedMinRating: Int
        let recentlyConvertedDates: [String: Date]
        let recentlyAppliedPaths: Set<String>
        let lastAddedPaths: Set<String>
        let minDurationSeconds: Double?
        let maxDurationSeconds: Double?
        let selectedQualityBuckets: Set<String>
        let customFieldDefinitionsById: [UUID: CustomMetadataFieldDefinition]
        let advancedFilterGroup: FilterGroup?
        let filtersDrawerMode: FiltersDrawerMode
        let customSortField: CustomMetadataFieldDefinition?
        let customSortAscending: Bool
        let listCustomMetadataByVideoId: [Int64: [UUID: String]]
        let isRandomOrder: Bool
        let randomOrderRanks: [String: Double]
        let usesAlbumManualOrder: Bool
    }

    private nonisolated static func applyRatingFilter(
        selectedStars: Set<Int>,
        orHigher: Bool,
        base: [Video]
    ) -> [Video] {
        RatingQuickFilter.apply(selectedStars: selectedStars, orHigher: orHigher, base: base)
    }

    /// Quality buckets are OR’d: video matches if its `resolutionLabel` is in the selected set.
    /// Videos with unknown resolution fail the filter (same convention as Advanced Quality).
    private nonisolated static func applyQualityFilter(buckets: Set<String>, base: [Video]) -> [Video] {
        guard !buckets.isEmpty else { return base }
        return base.filter { v in
            guard let label = v.resolutionLabel else { return false }
            return buckets.contains(label)
        }
    }

    /// Sorts by the per-video ranks generated in `shuffleOrder()`. A video with no assigned rank
    /// (e.g. imported after the last shuffle) sorts to the end rather than getting a fresh random
    /// value here — that value would be regenerated on every recompute, making just the new videos
    /// jitter around on every unrelated re-render instead of holding still until the next shuffle.
    private nonisolated static func sortByRandomOrder(_ videos: [Video], ranks: [String: Double]) -> [Video] {
        videos.sorted { (ranks[$0.filePath] ?? 2) < (ranks[$1.filePath] ?? 2) }
    }

    private nonisolated static func sortByAlbumOrder(_ videos: [Video], order: [Int64]) -> [Video] {
        var indexById: [Int64: Int] = [:]
        indexById.reserveCapacity(order.count)
        for (idx, id) in order.enumerated() {
            indexById[id] = idx
        }
        return videos.sorted { a, b in
            let ia = a.databaseId.flatMap { indexById[$0] } ?? Int.max
            let ib = b.databaseId.flatMap { indexById[$0] } ?? Int.max
            if ia != ib { return ia < ib }
            return a.filePath < b.filePath
        }
    }

    /// Concrete, fast replacement for `result.sort(using: [KeyPathComparator])`. The KeyPathComparator path
    /// boxes values and dynamically resolves the key path on every comparison — ~200ms for 12k items even on
    /// a trivial Date sort. Comparing concrete fields directly is ~10–20× faster. Mirrors
    /// `VideoSort.comparators(ascending:)`; `.name` uses `localizedStandardCompare` to match the natural/
    /// localized ordering of the Table column's String comparator.
    private nonisolated static func sortByTableOrder(_ videos: [Video], comparators: [KeyPathComparator<Video>]) -> [Video] {
        let first = comparators.first
        let sort = VideoSort.from(keyPath: first?.keyPath ?? \Video.dateAdded)
        let descending = (first?.order ?? .reverse) == .reverse
        var result = videos
        switch sort {
        case .name:
            result.sort { a, b in
                let r = a.displayTitle.localizedStandardCompare(b.displayTitle)
                return descending ? r == .orderedDescending : r == .orderedAscending
            }
        case .dateAdded:
            result.sort { descending ? $0.dateAdded > $1.dateAdded : $0.dateAdded < $1.dateAdded }
        case .duration:
            result.sort { descending ? $0.sortableDuration > $1.sortableDuration : $0.sortableDuration < $1.sortableDuration }
        case .fileSize:
            result.sort { descending ? $0.fileSize > $1.fileSize : $0.fileSize < $1.fileSize }
        case .rating:
            result.sort { descending ? $0.rating > $1.rating : $0.rating < $1.rating }
        case .playCount:
            result.sort { descending ? $0.playCount > $1.playCount : $0.playCount < $1.playCount }
        case .resolution:
            result.sort { a, b in
                if a.sortableResolutionHeight != b.sortableResolutionHeight {
                    return descending
                        ? a.sortableResolutionHeight > b.sortableResolutionHeight
                        : a.sortableResolutionHeight < b.sortableResolutionHeight
                }
                return descending
                    ? a.sortablePixelCount > b.sortablePixelCount
                    : a.sortablePixelCount < b.sortablePixelCount
            }
        }
        return result
    }

    /// Shared raw-string → typed-value parsing for a custom metadata field, used by both
    /// custom-field sort (`sortByCustomField`) and the advanced/Collections `FilterMatcher`,
    /// so there is exactly one implementation of "how do I read a `.number`/`.date`/`.dateTime`/
    /// `.string` raw value." Builds the map once per field (O(videos)), not once per comparison.
    private enum CustomFieldValueParser {
        static func numberValues(_ videos: [Video], fieldId: UUID, metadata: [Int64: [UUID: String]]) -> [Int64: Double] {
            var values: [Int64: Double] = [:]
            for video in videos {
                guard let vid = video.databaseId, let raw = metadata[vid]?[fieldId] else { continue }
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = Double(t) { values[vid] = d }
            }
            return values
        }

        static func dateValues(_ videos: [Video], fieldId: UUID, metadata: [Int64: [UUID: String]]) -> [Int64: Date] {
            var values: [Int64: Date] = [:]
            for video in videos {
                guard let vid = video.databaseId, let raw = metadata[vid]?[fieldId] else { continue }
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = isoDate.date(from: t) { values[vid] = d }
            }
            return values
        }

        static func dateTimeValues(_ videos: [Video], fieldId: UUID, metadata: [Int64: [UUID: String]]) -> [Int64: Date] {
            var values: [Int64: Date] = [:]
            for video in videos {
                guard let vid = video.databaseId, let raw = metadata[vid]?[fieldId] else { continue }
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = isoFrac.date(from: t) ?? isoPlain.date(from: t) { values[vid] = d }
            }
            return values
        }

        static func stringValues(_ videos: [Video], fieldId: UUID, metadata: [Int64: [UUID: String]]) -> [Int64: String] {
            var values: [Int64: String] = [:]
            for video in videos {
                guard let vid = video.databaseId, let raw = metadata[vid]?[fieldId] else { continue }
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { values[vid] = t }
            }
            return values
        }

        static func booleanValues(_ videos: [Video], fieldId: UUID, metadata: [Int64: [UUID: String]]) -> [Int64: Bool] {
            var values: [Int64: Bool] = [:]
            for video in videos {
                guard let vid = video.databaseId, let raw = metadata[vid]?[fieldId] else { continue }
                if let canon = CustomMetadataValueType.normalizeBooleanStorage(raw) {
                    values[vid] = canon == "true"
                }
            }
            return values
        }

        private static let isoDate: DateFormatter = {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()
        private static let isoFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private static let isoPlain: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()
    }

    /// Applies all active custom-metadata-field filters (AND across fields). For each active
    /// field, builds its typed value map once (via `CustomFieldValueParser`) and filters in a
    /// single pass. Iterates the progressively-narrowed `base` for each successive field, so later
    /// fields build smaller maps once earlier fields have already narrowed the set. A video with no
    /// stored value for an actively-filtered field is excluded (parallels "missing sorts last" in
    /// `sortByCustomField`: here, "missing" fails the filter rather than being ambiguously included).
    private nonisolated static func sortByCustomField(
        _ videos: [Video],
        field: CustomMetadataFieldDefinition,
        ascending: Bool,
        metadata: [Int64: [UUID: String]]
    ) -> [Video] {
        switch field.valueType {
        case .number:
            let values = CustomFieldValueParser.numberValues(videos, fieldId: field.id, metadata: metadata)
            return videos.sorted { a, b in
                let va = a.databaseId.flatMap { values[$0] }
                let vb = b.databaseId.flatMap { values[$0] }
                switch (va, vb) {
                case (nil, nil): return false
                case (nil, _):   return !ascending
                case (_, nil):   return ascending
                case let (l?, r?): return ascending ? l < r : l > r
                }
            }

        case .date:
            let values = CustomFieldValueParser.dateValues(videos, fieldId: field.id, metadata: metadata)
            return videos.sorted { a, b in
                let va = a.databaseId.flatMap { values[$0] }
                let vb = b.databaseId.flatMap { values[$0] }
                switch (va, vb) {
                case (nil, nil): return false
                case (nil, _):   return !ascending
                case (_, nil):   return ascending
                case let (l?, r?): return ascending ? l < r : l > r
                }
            }

        case .dateTime:
            let values = CustomFieldValueParser.dateTimeValues(videos, fieldId: field.id, metadata: metadata)
            return videos.sorted { a, b in
                let va = a.databaseId.flatMap { values[$0] }
                let vb = b.databaseId.flatMap { values[$0] }
                switch (va, vb) {
                case (nil, nil): return false
                case (nil, _):   return !ascending
                case (_, nil):   return ascending
                case let (l?, r?): return ascending ? l < r : l > r
                }
            }

        case .boolean:
            let values = CustomFieldValueParser.booleanValues(videos, fieldId: field.id, metadata: metadata)
            return videos.sorted { a, b in
                let va = a.databaseId.flatMap { values[$0] }
                let vb = b.databaseId.flatMap { values[$0] }
                switch (va, vb) {
                case (nil, nil): return false
                case (nil, _):   return !ascending
                case (_, nil):   return ascending
                case let (l?, r?): return ascending ? (!l && r) : (l && !r)
                }
            }

        case .string, .text:
            let values = CustomFieldValueParser.stringValues(videos, fieldId: field.id, metadata: metadata)
            return videos.sorted { a, b in
                let va = a.databaseId.flatMap { values[$0] }
                let vb = b.databaseId.flatMap { values[$0] }
                switch (va, vb) {
                case (nil, nil): return false
                case (nil, _):   return !ascending
                case (_, nil):   return ascending
                case let (l?, r?):
                    let cmp = l.localizedStandardCompare(r)
                    return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
                }
            }
        }
    }

    private nonisolated static func libraryFilterContext(from snapshot: FilterSnapshot) -> LibraryFilterContext {
        LibraryFilterContext.from(
            duplicateVideoIds: snapshot.duplicateVideoIds,
            missingVideoIds: snapshot.missingVideoIds,
            recentlyAddedDays: snapshot.recentlyAddedDays,
            recentlyPlayedDays: snapshot.recentlyPlayedDays,
            topRatedMinRating: snapshot.topRatedMinRating,
            recentlyConvertedDates: snapshot.recentlyConvertedDates,
            recentlyAppliedPaths: snapshot.recentlyAppliedPaths,
            lastAddedPaths: snapshot.lastAddedPaths,
            thumbnailsSettled: snapshot.thumbnailsSettled,
            cachedAlbumVideoIds: snapshot.cachedAlbumVideoIds
        )
    }

    private func currentLibraryFilterContext() -> LibraryFilterContext {
        LibraryFilterContext.from(
            duplicateVideoIds: duplicateVideoIds,
            missingVideoIds: missingVideoIds,
            recentlyAddedDays: recentlyAddedDays,
            recentlyPlayedDays: recentlyPlayedDays,
            topRatedMinRating: topRatedMinRating,
            recentlyConvertedDates: recentlyConvertedDates,
            recentlyAppliedPaths: recentlyAppliedPaths,
            lastAddedPaths: lastAddedPaths,
            thumbnailsSettled: thumbnailsSettled,
            cachedAlbumVideoIds: cachedAlbumVideoIds
        )
    }

    private nonisolated static func computeFilteredResult(snapshot: FilterSnapshot, collectionRepo: CollectionRepository) -> (videos: [Video], tagCounts: [Int64: Int]) {
        func isCorrupt(_ video: Video) -> Bool {
            video.duration == nil && video.width == nil && video.height == nil
                || (snapshot.thumbnailsSettled && video.thumbnailPath == nil)
        }
        let libraryContext = libraryFilterContext(from: snapshot)
        var baseResult = snapshot.videos
        let isSearching = !snapshot.searchText.isEmpty
        let isCorruptFilter = snapshot.sidebarFilter == .corrupt
        let isMissingFilter = snapshot.sidebarFilter == .missing

        // Don't hide "corrupt-looking" rows inside Missing — absent files often have no
        // thumbnail / probe data, which would otherwise make Exclude Corrupt empty the view
        // while the Missing badge still counts them.
        if snapshot.excludeCorrupt && !isCorruptFilter && !isMissingFilter && !isSearching {
            baseResult = baseResult.filter { !isCorrupt($0) }
        }

        if isSearching, let matchIds = snapshot.ftsMatchIds {
            baseResult = baseResult.filter { matchIds.contains($0.id) }
        }

        switch snapshot.filtersDrawerMode {
        case .quick:
            switch snapshot.sidebarFilter {
            case .recentlyAdded:
                let cutoff = Calendar.current.date(byAdding: .day, value: -snapshot.recentlyAddedDays, to: Date()) ?? Date()
                baseResult = baseResult.filter { $0.dateAdded >= cutoff }
            case .recentlyPlayed:
                let cutoff = Calendar.current.date(byAdding: .day, value: -snapshot.recentlyPlayedDays, to: Date()) ?? Date()
                baseResult = baseResult.filter { ($0.lastPlayed ?? .distantPast) >= cutoff }
            case .topRated:
                baseResult = baseResult.filter { $0.rating >= snapshot.topRatedMinRating }
            case .duplicates:
                baseResult = baseResult.filter { snapshot.duplicateVideoIds.contains($0.id) }
            case .corrupt:
                baseResult = baseResult.filter { isCorrupt($0) }
            case .missing:
                baseResult = baseResult.filter { snapshot.missingVideoIds.contains($0.id) }
            case .recentlyConverted:
                baseResult = baseResult.filter { snapshot.recentlyConvertedDates[$0.filePath] != nil }
            case .recentlyApplied:
                baseResult = baseResult.filter { snapshot.recentlyAppliedPaths.contains($0.filePath) }
            case .lastAdded:
                baseResult = baseResult.filter { snapshot.lastAddedPaths.contains($0.filePath) }
            case .collection(let collection):
                guard let collectionId = collection.id else {
                    return ([], [:])
                }
                if collection.kind == .album {
                    let members = Set(snapshot.cachedAlbumVideoIds[collectionId] ?? [])
                    baseResult = baseResult.filter { video in
                        guard let dbId = video.databaseId else { return false }
                        return members.contains(dbId)
                    }
                } else {
                    let groups = snapshot.cachedCollectionRuleGroups[collectionId] ?? []
                    if groups.isEmpty {
                        return ([], [:])
                    }
                    let rules = snapshot.cachedCollectionRules[collectionId] ?? []
                    let rulesByGroup = Dictionary(grouping: rules, by: \.groupId)
                    let matcher = collectionRepo.compileMatcher(
                        for: collection, groups: groups, rulesByGroup: rulesByGroup,
                        customFields: snapshot.customFieldDefinitionsById,
                        libraryContext: libraryContext,
                        collectionRepo: collectionRepo
                    )
                    baseResult = baseResult.filter { video in
                        let dbId = video.databaseId
                        return matcher.matches(
                            video,
                            tags: snapshot.tagsByVideoId[dbId ?? -1] ?? [],
                            customValues: dbId.flatMap { snapshot.listCustomMetadataByVideoId[$0] } ?? [:]
                        )
                    }
                }
            default:
                break
            }

            baseResult = Self.applyRatingFilter(
                selectedStars: snapshot.selectedRatingStars,
                orHigher: snapshot.ratingFilterOrHigher,
                base: baseResult
            )

            if let minD = snapshot.minDurationSeconds {
                baseResult = baseResult.filter { ($0.duration ?? 0) >= minD }
            }
            if let maxD = snapshot.maxDurationSeconds {
                baseResult = baseResult.filter { ($0.duration ?? 0) <= maxD }
            }

            baseResult = Self.applyQualityFilter(buckets: snapshot.selectedQualityBuckets, base: baseResult)

        case .advanced:
            if let group = snapshot.advancedFilterGroup, !group.isEmpty {
                let matcher = FilterMatcher(
                    group: group,
                    customFields: snapshot.customFieldDefinitionsById,
                    libraryContext: libraryContext,
                    collectionRepo: collectionRepo
                )
                baseResult = baseResult.filter { video in
                    let dbId = video.databaseId
                    return matcher.matches(
                        video,
                        tags: snapshot.tagsByVideoId[dbId ?? -1] ?? [],
                        customValues: dbId.flatMap { snapshot.listCustomMetadataByVideoId[$0] } ?? [:]
                    )
                }
            }
        }

        let tagCounts = computeTagCounts(snapshot: snapshot, baseVideos: baseResult)

        var result = baseResult
        if snapshot.filtersDrawerMode == .quick, !snapshot.selectedTagIds.isEmpty {
            result = result.filter { video in
                let videoTagIds = Set((snapshot.tagsByVideoId[video.databaseId ?? -1] ?? []).compactMap(\.id))
                switch snapshot.tagFilterMode {
                case .all: return snapshot.selectedTagIds.isSubset(of: videoTagIds)
                case .any: return !snapshot.selectedTagIds.isDisjoint(with: videoTagIds)
                }
            }
        }

        if snapshot.isRandomOrder {
            result = Self.sortByRandomOrder(result, ranks: snapshot.randomOrderRanks)
        } else if snapshot.usesAlbumManualOrder,
                  case .collection(let collection) = snapshot.sidebarFilter,
                  collection.isAlbum,
                  let collectionId = collection.id
        {
            result = Self.sortByAlbumOrder(result, order: snapshot.cachedAlbumVideoIds[collectionId] ?? [])
        } else if snapshot.sidebarFilter == .recentlyPlayed {
            result = result.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        } else if snapshot.sidebarFilter == .recentlyConverted {
            result = result.sorted {
                (snapshot.recentlyConvertedDates[$0.filePath] ?? .distantPast) >
                (snapshot.recentlyConvertedDates[$1.filePath] ?? .distantPast)
            }
        } else if let field = snapshot.customSortField {
            result = Self.sortByCustomField(
                result, field: field, ascending: snapshot.customSortAscending,
                metadata: snapshot.listCustomMetadataByVideoId)
        } else {
            result = Self.sortByTableOrder(result, comparators: snapshot.tableSortOrder)
        }
        return (result, tagCounts)
    }

    private nonisolated static func computeTagCounts(snapshot: FilterSnapshot, baseVideos: [Video]) -> [Int64: Int] {
        let baseIds = Set(baseVideos.compactMap(\.databaseId))
        var counts: [Int64: Int] = [:]
        for (videoId, tags) in snapshot.tagsByVideoId {
            guard baseIds.contains(videoId) else { continue }
            for tag in tags {
                guard let tagId = tag.id else { continue }
                counts[tagId, default: 0] += 1
            }
        }
        return counts
    }

    private func applyFilteredVideos(_ newValue: [Video]) {
        // Bump `.id(filteredVideosVersion)` / `contentID` only when the **set** of rows changes — not on pure
        // **reorder** (e.g. column sort). Reorder used to compare full `databaseId` arrays → always "changed" →
        // full grid teardown + every `.task` thumbnail re-fired → multi‑second stalls on large libraries.
        let oldSet = Set(filteredVideos.map(\.id))
        let newSet = Set(newValue.map(\.id))
        let structureChanged = oldSet != newSet
        filteredVideos = newValue
        rebuildFilteredPathIndex()
        if structureChanged {
            filteredVideosVersion &+= 1
            if let id = pendingScrollToAfterRename, newValue.contains(where: { $0.id == id }) {
                pendingScrollToAfterRename = nil
                scrollToVideoId = id
                selectedVideoIds = [id]
                lastSelectedVideoId = id
                focusedVideoId = id
            }
            let validIds = Set(newValue.map(\.id))
            let pruned = selectedVideoIds.intersection(validIds)
            if pruned != selectedVideoIds {
                selectedVideoIds = pruned
            }
            if let id = focusedVideoId, !validIds.contains(id) {
                focusedVideoId = pruned.first
                if lastSelectedVideoId == id {
                    lastSelectedVideoId = focusedVideoId
                }
            }
        } else if pendingScrollToAfterRename != nil {
            pendingScrollToAfterRename = nil
        }

        if let sortScrollId = pendingScrollAfterSortId {
            pendingScrollAfterSortId = nil
            if newValue.contains(where: { $0.id == sortScrollId }) {
                scrollToVideoId = sortScrollId
            }
        }

        // When the visible row *set* changes (e.g. clearing search restores the full library) selection
        // can stay valid while the grid/list viewport is unrelated — scroll the primary selection into view.
        // Skipped when rename/sort handling above already queued a scroll (`scrollToVideoId` non-nil).
        if structureChanged, scrollToVideoId == nil,
           let id = lastSelectedVideoId ?? selectedVideoIds.first,
           !selectedVideoIds.isEmpty,
           selectedVideoIds.contains(id),
           newValue.contains(where: { $0.id == id })
        {
            scrollToVideoId = id
        }
    }

    // MARK: - Library Counts

    private func updateLibraryCounts() {
        var allCount = 0
        var recentlyAdded = 0
        var recentlyPlayed = 0
        var topRated = 0
        var corrupt = 0
        var byRating: [Int: Int] = [:]
        let addedCutoff = Calendar.current.date(byAdding: .day, value: -recentlyAddedDays, to: Date()) ?? Date()
        let playedCutoff = Calendar.current.date(byAdding: .day, value: -recentlyPlayedDays, to: Date()) ?? Date()
        let convertedPaths = Set(recentlyConvertedDates.keys)

        // Bucket by content fingerprint (byte-identical videos land together). Members carry their
        // stable databaseId so the pairwise "not a duplicate" decisions can be applied below.
        typealias DupKey = String
        struct DupMember { let id: String; let dbId: Int64? }
        var buckets: [DupKey: [DupMember]] = [:]
        for video in videos {
            let isCorrupt = Self.isCorrupt(video, thumbnailsSettled: thumbnailsSettled)
            if isCorrupt { corrupt += 1 }
            let skip = excludeCorrupt && isCorrupt
            if !skip {
                allCount += 1
                if video.dateAdded >= addedCutoff { recentlyAdded += 1 }
                if (video.lastPlayed ?? .distantPast) >= playedCutoff { recentlyPlayed += 1 }
                if video.rating >= topRatedMinRating { topRated += 1 }
                if video.rating > 0 {
                    byRating[video.rating, default: 0] += 1
                }
                if let key = Self.duplicateSignature(video) {
                    buckets[key, default: []].append(DupMember(id: video.id, dbId: video.databaseId))
                }
            }
        }

        // A member is a duplicate iff it shares a fingerprint with at least one other member it has
        // NOT been confirmed-distinct from. A newly-imported match has no confirmation yet, so it
        // re-flags itself and its mates automatically (the "re-open on a truly new duplicate" rule).
        var dupIds = Set<String>()
        for members in buckets.values where members.count > 1 {
            for v in members {
                let hasUnconfirmedMate = members.contains { w in
                    w.id != v.id && !isConfirmedDistinct(v.dbId, w.dbId)
                }
                if hasUnconfirmedMate { dupIds.insert(v.id) }
            }
        }
        duplicateVideoIds = dupIds

        let recentlyConverted = videos.filter { convertedPaths.contains($0.filePath) }.count
        let recentlyApplied = videos.filter { recentlyAppliedPaths.contains($0.filePath) }.count
        let lastAdded = videos.filter { lastAddedPaths.contains($0.filePath) }.count

        libraryCounts = LibraryCounts(
            all: allCount,
            recentlyAdded: recentlyAdded,
            recentlyPlayed: recentlyPlayed,
            topRated: topRated,
            duplicates: dupIds.count,
            corrupt: corrupt,
            missing: missingCountScanned ? missingVideoIds.count : 0,
            recentlyConverted: recentlyConverted,
            recentlyApplied: recentlyApplied,
            lastAdded: lastAdded,
            byRating: byRating
        )
    }

    // MARK: - Duplicates

    /// Whether a video is currently in the Duplicates smart library (drives the context-menu item).
    func isDuplicate(_ videoId: String) -> Bool {
        duplicateVideoIds.contains(videoId)
    }

    /// The grouping key for duplicate detection: the content fingerprint (byte-identical files
    /// share it). `nil` when not yet computed (unreachable / not backfilled) — such videos aren't
    /// grouped, so they never appear in Duplicates until a fingerprint is available. Single source
    /// of truth, used by both the recompute above and `markNotDuplicate`.
    static func duplicateSignature(_ video: Video) -> String? {
        video.contentFingerprint
    }

    /// True when the user has confirmed these two videos are not duplicates of each other. Unknown
    /// ids (nil databaseId) can't be confirmed, so they stay treated as potential duplicates.
    private func isConfirmedDistinct(_ a: Int64?, _ b: Int64?) -> Bool {
        guard let a, let b else { return false }
        return notDuplicatePairs.contains(NotDuplicateKey(a, b))
    }

    /// "Not a Duplicate" action: mark each target video as confirmed-distinct from every other
    /// video that currently shares its fingerprint. Clears the target(s) from Duplicates while
    /// leaving genuine duplicates among the *remaining* members flagged. Persisted so it survives
    /// recomputes and relaunches; a later genuinely-new match re-opens review automatically.
    func markNotDuplicate(_ targets: [Video]) async {
        // Group all videos by fingerprint once so each target's current mates are cheap to find.
        var bySignature: [String: [Video]] = [:]
        for v in videos {
            guard let sig = Self.duplicateSignature(v) else { continue }
            bySignature[sig, default: []].append(v)
        }

        var newPairs: [VideoNotDuplicatePair] = []
        var newKeys: [NotDuplicateKey] = []
        for target in targets {
            guard let tId = target.databaseId, let sig = Self.duplicateSignature(target) else { continue }
            for mate in bySignature[sig] ?? [] {
                guard let mId = mate.databaseId, mId != tId else { continue }
                let key = NotDuplicateKey(tId, mId)
                if !notDuplicatePairs.contains(key) {
                    newKeys.append(key)
                    newPairs.append(VideoNotDuplicatePair(tId, mId))
                }
            }
        }
        guard !newPairs.isEmpty else { return }

        try? await videoRepo.insertNotDuplicatePairs(newPairs)
        notDuplicatePairs.formUnion(newKeys)
        updateLibraryCounts()
        recomputeFilteredVideos()
    }

    /// Escape hatch (Settings): forget every "not a duplicate" decision so all fingerprint groups
    /// are re-flagged for review.
    func resetNotDuplicateDecisions() async {
        try? await videoRepo.deleteAllNotDuplicatePairs()
        notDuplicatePairs.removeAll()
        updateLibraryCounts()
        recomputeFilteredVideos()
    }

    private func updateTagCounts() {
        let baseVideos = baseVideosForPrimaryFilter()
        var counts: [Int64: Int] = [:]
        let baseIds = Set(baseVideos.compactMap(\.databaseId))
        for (videoId, tags) in tagsByVideoId {
            guard baseIds.contains(videoId) else { continue }
            for tag in tags {
                guard let tagId = tag.id else { continue }
                counts[tagId, default: 0] += 1
            }
        }
        tagCounts = counts
    }

    /// Videos after applying library/collection sidebar filter and per-star rating filter, before tag filter.
    private func baseVideosForPrimaryFilter() -> [Video] {
        var result = videos
        let isCorruptFilter = sidebarFilter == .corrupt
        let isMissingFilter = sidebarFilter == .missing
        if excludeCorrupt && !isCorruptFilter && !isMissingFilter && searchText.isEmpty {
            result = result.filter { !Self.isCorrupt($0, thumbnailsSettled: thumbnailsSettled) }
        }
        if !searchText.isEmpty, let matchIds = ftsMatchIds {
            result = result.filter { matchIds.contains($0.id) }
        }
        switch sidebarFilter {
        case .recentlyAdded:
            let cutoff = Calendar.current.date(byAdding: .day, value: -recentlyAddedDays, to: Date()) ?? Date()
            result = result.filter { $0.dateAdded >= cutoff }
        case .recentlyPlayed:
            let cutoff = Calendar.current.date(byAdding: .day, value: -recentlyPlayedDays, to: Date()) ?? Date()
            result = result.filter { ($0.lastPlayed ?? .distantPast) >= cutoff }
        case .topRated:
            result = result.filter { $0.rating >= topRatedMinRating }
        case .duplicates:
            result = result.filter { duplicateVideoIds.contains($0.id) }
        case .corrupt:
            result = result.filter { Self.isCorrupt($0, thumbnailsSettled: thumbnailsSettled) }
        case .missing:
            result = result.filter { missingVideoIds.contains($0.id) }
        case .recentlyConverted:
            result = result.filter { recentlyConvertedDates[$0.filePath] != nil }
        case .recentlyApplied:
            result = result.filter { recentlyAppliedPaths.contains($0.filePath) }
        case .lastAdded:
            result = result.filter { lastAddedPaths.contains($0.filePath) }
        case .collection(let collection):
            guard let collectionId = collection.id else { return [] }
            if collection.kind == .album {
                let members = Set(cachedAlbumVideoIds[collectionId] ?? [])
                result = result.filter { video in
                    guard let dbId = video.databaseId else { return false }
                    return members.contains(dbId)
                }
            } else {
                let groups = cachedCollectionRuleGroups[collectionId] ?? []
                if groups.isEmpty { return [] }
                let rules = cachedCollectionRules[collectionId] ?? []
                let rulesByGroup = Dictionary(grouping: rules, by: \.groupId)
                let customFields = Dictionary(uniqueKeysWithValues: customMetadataFieldDefinitions.map { ($0.id, $0) })
                let libraryContext = currentLibraryFilterContext()
                let matcher = collectionRepo.compileMatcher(
                    for: collection,
                    groups: groups,
                    rulesByGroup: rulesByGroup,
                    customFields: customFields,
                    libraryContext: libraryContext,
                    collectionRepo: collectionRepo
                )
                result = result.filter { video in
                    let dbId = video.databaseId
                    return matcher.matches(
                        video,
                        tags: tagsByVideoId[dbId ?? -1] ?? [],
                        customValues: dbId.flatMap { listCustomMetadataByVideoId[$0] } ?? [:]
                    )
                }
            }
        default:
            break
        }
        result = Self.applyRatingFilter(
            selectedStars: selectedRatingStars,
            orHigher: ratingFilterOrHigher,
            base: result
        )

        if let minD = minDurationSeconds {
            result = result.filter { ($0.duration ?? 0) >= minD }
        }
        if let maxD = maxDurationSeconds {
            result = result.filter { ($0.duration ?? 0) <= maxD }
        }

        result = Self.applyQualityFilter(buckets: selectedQualityBuckets, base: result)

        return result
    }

    // MARK: - Actions

    /// Snapshot library paths before a media-add scan so newly inserted rows can feed Last Added.
    private func snapshotLibraryPaths() async -> Set<String> {
        (try? await videoRepo.fetchAllFilePaths()) ?? Set(videos.map(\.filePath))
    }

    /// If `before` → current differs, replace Last Added and select that smart library.
    /// Empty scans leave the previous Last Added set unchanged.
    private func commitLastAdded(before: Set<String>) async {
        let after = await snapshotLibraryPaths()
        let added = after.subtracting(before)
        guard !added.isEmpty else { return }
        lastAddedPaths = added
        sidebarFilter = .lastAdded
        updateLibraryCounts()
        recomputeFilteredVideos()
    }

    func importNew() async {
        let dataSources = (try? await dataSourceRepo.fetchAll()) ?? []
        guard !dataSources.isEmpty else {
            scanProgress = "No data sources — add a folder first"
            Task {
                try? await Task.sleep(for: .seconds(3))
                if scanProgress.starts(with: "No data sources") { scanProgress = "" }
            }
            return
        }

        isScanning = true
        scanProgress = "Checking for new files..."
        stopObserving()

        let knownPaths = (try? await videoRepo.fetchAllFilePaths()) ?? []
        let beforePaths = knownPaths
        let folders = dataSources.map(\.url)
        var failureCount = 0

        for await update in await scanner.scanForNewFiles(folders: folders, knownPaths: knownPaths) {
            switch update {
            case .started(let total):
                scanTotal = total
                scanCurrent = 0
                if total == 0 {
                    scanProgress = "No new files found"
                } else {
                    scanProgress = "Found \(total) new video files"
                }
            case .progress(let current, let total, _):
                scanCurrent = current
                scanTotal = total
            case .partialFailure(let count):
                failureCount = count
            case .completed:
                if scanTotal == 0 {
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        if scanProgress == "No new files found" { scanProgress = "" }
                    }
                } else if failureCount > 0 {
                    let message = "Added \(scanTotal - failureCount)/\(scanTotal) — \(failureCount) failed (see console)"
                    scanProgress = message
                    Task { [message] in
                        try? await Task.sleep(for: .seconds(4))
                        if scanProgress == message { scanProgress = "" }
                    }
                } else {
                    scanProgress = ""
                }
                isScanning = false
                await refreshAfterScan()
                await commitLastAdded(before: beforePaths)
            case .error(let message):
                scanProgress = "Error: \(message)"
                isScanning = false
                startObserving()
            }
        }
    }

    func importDroppedFiles(_ urls: [URL], recordAsLastAdded: Bool = true) async {
        guard !urls.isEmpty else { return }

        let folders = urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let videoUrls = urls.filter { $0.isVideoFile }
        guard !folders.isEmpty || !videoUrls.isEmpty else { return }

        let beforePaths = recordAsLastAdded ? await snapshotLibraryPaths() : []

        for folder in folders {
            await scanFolder(folder, recordAsLastAdded: false)
        }
        guard !videoUrls.isEmpty else {
            if recordAsLastAdded {
                await commitLastAdded(before: beforePaths)
            }
            return
        }

        let parentFolders = Set(videoUrls.map { $0.deletingLastPathComponent() })
        for folder in parentFolders {
            let path = folder.path
            let alreadySaved = (try? await dataSourceRepo.exists(folderPath: path)) ?? false
            if !alreadySaved {
                let source = DataSource(
                    folderPath: path,
                    name: folder.lastPathComponent,
                    dateAdded: Date()
                )
                try? await dataSourceRepo.insert(source)
            }
        }

        isScanning = true
        scanProgress = "Scanning dropped files…"
        stopObserving()
        var failureCount = 0

        for await update in await scanner.scanFiles(videoUrls) {
            switch update {
            case .started(let total):
                scanTotal = total
                scanCurrent = 0
            case .progress(let current, let total, _):
                scanCurrent = current
                scanTotal = total
            case .partialFailure(let count):
                failureCount = count
            case .completed:
                if failureCount > 0 {
                    let message = "Added \(scanTotal - failureCount)/\(scanTotal) — \(failureCount) failed (see console)"
                    scanProgress = message
                    Task { [message] in
                        try? await Task.sleep(for: .seconds(4))
                        if scanProgress == message { scanProgress = "" }
                    }
                } else {
                    scanProgress = ""
                }
                isScanning = false
                await refreshAfterScan()
                if recordAsLastAdded {
                    await commitLastAdded(before: beforePaths)
                }
            case .error(let message):
                scanProgress = "Error: \(message)"
                isScanning = false
                startObserving()
            }
        }
    }

    /// Picks a random video from the current filtered list, selects it, and scrolls it into view.
    /// Both List and the Wall grid already scroll-into-view whenever `scrollToVideoId` changes
    /// (List via its `Table`'s native selection scroll, Wall grid via its own `scrollToVideoId`
    /// handler), so this is the same mechanism Home/End and rename-completion use.
    func surpriseMePickRandom() {
        guard let random = filteredVideos.randomElement() else { return }
        selectOnly(random.id, scroll: true)
        pendingAutoPlay = surpriseMeAutoPlays
    }

    /// Play the current filtered view from the first playable video, ignoring resume.
    func playAllFromStart() {
        guard let first = firstPlayableFilteredVideo() else { return }
        isPlayAllSession = true
        setReviewFocus(first.id, retargetIfPlaying: false, scroll: true)
        pendingFilmstripSeekSeconds = nil
        pendingIgnoreResumeOnNextStart = true
        if isPlayingInline {
            playQueueSuccessor(first)
        } else {
            pendingAutoPlay = true
        }
    }

    private func firstPlayableFilteredVideo() -> Video? {
        filteredVideos.first { FileManager.default.fileExists(atPath: $0.filePath) }
    }

    /// Grid / List “Scroll to Selection” (⌘J): focus, last focus, or any collected clip.
    var hasScrollToSelectionTarget: Bool {
        focusedVideoId != nil || lastSelectedVideoId != nil || !selectedVideoIds.isEmpty
    }

    /// Scroll the browser so the reviewed / focused clip (or a collected stand-in) is visible.
    func scrollToSelected() {
        guard let id = focusedVideoId ?? lastSelectedVideoId ?? selectedVideoIds.first,
              filteredVideos.contains(where: { $0.id == id }) else { return }
        scrollToVideoId = id
    }

    /// Plain click in the browser — collected clips toggle batch inspect vs focus on repeat clicks.
    func applyPlainReviewClick(on id: String, lastClickedId: inout String?) {
        requestDefocusTextInputs()
        var session = ReviewSession(focusedId: focusedVideoId, selectedIds: selectedVideoIds)
        lastClickedId = session.applyPlainClick(on: id, lastClickedId: lastClickedId)
        let previous = focusedVideoId
        focusedVideoId = session.focusedId
        if let focusedVideoId {
            lastSelectedVideoId = focusedVideoId
            if isPlayingInline, previous != focusedVideoId,
               let video = filteredVideo(forPath: focusedVideoId) {
                retargetPlayback(to: video)
            }
        } else if selectedVideoIds.contains(id) {
            lastSelectedVideoId = id
        }
    }

    /// Move review focus without replacing the collected set. Retargets the player when already playing.
    func setReviewFocus(_ id: String, retargetIfPlaying: Bool = true, scroll: Bool = false) {
        requestDefocusTextInputs()
        let previous = focusedVideoId
        focusedVideoId = id // didSet → noteMissingClipFocusIfNeeded
        lastSelectedVideoId = id
        if scroll { scrollToVideoId = id }
        if retargetIfPlaying, isPlayingInline, previous != id,
           let video = filteredVideo(forPath: id) {
            retargetPlayback(to: video)
        }
    }

    /// Public entry for playback / other paths that discover a missing file without changing focus.
    func noteLibraryFileMissing(path: String) {
        noteMissingClipFocusIfNeeded(path: path)
    }

    /// Show the Missing / Reconnect banner when a clip’s file is gone.
    /// Does not auto-open Reconnect (offline ≠ force repair). Idempotent (no flicker).
    /// Triggers the same full-library missing scan as the Missing smart library so banner
    /// count and Reconnect scope cover every missing clip, not only the focused orphan.
    private func noteMissingClipFocusIfNeeded(path: String) {
        let knownMissing = missingVideoIds.contains(path)
        let missingOnDisk = !FileManager.default.fileExists(atPath: path)
        guard knownMissing || missingOnDisk else {
            // Present file — clear click-triggered banner; Missing-filter case still uses its own rule.
            if showRepairLinksBannerFromMissingClick {
                showRepairLinksBannerFromMissingClick = false
            }
            return
        }

        if missingOnDisk, !missingVideoIds.contains(path) {
            missingVideoIds.insert(path)
            missingCountScanned = true
            UserDefaults.standard.set(true, forKey: Self.missingCountScannedKey)
            UserDefaults.standard.set(Array(missingVideoIds), forKey: Self.missingVideoIdsKey)
            libraryCounts = LibraryCounts(
                all: libraryCounts.all,
                recentlyAdded: libraryCounts.recentlyAdded,
                recentlyPlayed: libraryCounts.recentlyPlayed,
                topRated: libraryCounts.topRated,
                duplicates: libraryCounts.duplicates,
                corrupt: libraryCounts.corrupt,
                missing: missingVideoIds.count,
                recentlyConverted: libraryCounts.recentlyConverted,
                recentlyApplied: libraryCounts.recentlyApplied,
                lastAdded: libraryCounts.lastAdded,
                byRating: libraryCounts.byRating
            )
        }

        showRepairLinksBannerFromMissingClick = true
        updateRepairLinksBannerPreferredRoot(forMissingPath: path)

        // Full scan (cheap) — banner + Reconnect then reflect the complete missing set.
        let anchorPath = path
        isMissingBannerScanPending = true
        Task { @MainActor in
            defer { self.isMissingBannerScanPending = false }
            await self.refreshMissingCount()
            guard self.missingVideoIds.contains(anchorPath) || !self.missingVideoIds.isEmpty else {
                self.showRepairLinksBannerFromMissingClick = false
                return
            }
            self.showRepairLinksBannerFromMissingClick = true
            self.updateRepairLinksBannerPreferredRoot(forMissingPath: anchorPath)
        }
    }

    private func updateRepairLinksBannerPreferredRoot(forMissingPath path: String) {
        var paths = Array(missingVideoIds)
        if !paths.contains(path) { paths.append(path) }
        if let inferred = LocationRelink.inferSharedMissingRoot(missingPaths: paths, dataSourceRoots: []) {
            repairLinksBannerPreferredRoot = inferred
            return
        }
        let parent = LocationRelink.normalizeRoot(
            URL(fileURLWithPath: path).deletingLastPathComponent().path
        )
        repairLinksBannerPreferredRoot = LocationRelink.isSelectableOldRoot(parent) ? parent : nil
    }

    func toggleInCollectedSet(_ id: String) {
        var ids = selectedVideoIds
        let adding = !ids.contains(id)
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        selectedVideoIds = ids
        if adding {
            activateBatchInspectIfMultiCollected(lastTouchedId: id)
        }
    }

    /// ⌘/⇧/A collection edits with 2+ clips — batch inspect (clears review focus).
    func activateBatchInspectIfMultiCollected(lastTouchedId: String? = nil) {
        guard selectedVideoIds.count > 1 else { return }
        focusedVideoId = nil
        if let lastTouchedId {
            lastSelectedVideoId = lastTouchedId
        }
    }

    func unionIntoCollectedSet(_ ids: Set<String>, lastTouchedId: String? = nil) {
        guard !ids.isEmpty else { return }
        selectedVideoIds.formUnion(ids)
        activateBatchInspectIfMultiCollected(lastTouchedId: lastTouchedId)
    }

    func toggleFocusedInCollectedSet() {
        guard let id = focusedVideoId ?? lastSelectedVideoId ?? selectedVideoIds.first else { return }
        toggleInCollectedSet(id)
    }

    func selectOnly(_ id: String, scroll: Bool = false) {
        selectedVideoIds = [id]
        setReviewFocus(id, retargetIfPlaying: isPlayingInline, scroll: scroll)
    }

    /// Keep the collected set, review focus, and last-selected id coherent when a file path changes.
    private func remapVideoPathInSelection(from old: String, to new: String) {
        if selectedVideoIds.contains(old) {
            selectedVideoIds.remove(old)
            selectedVideoIds.insert(new)
        }
        if lastSelectedVideoId == old {
            lastSelectedVideoId = new
        }
        if focusedVideoId == old {
            focusedVideoId = new
        }
    }

    func navigateFilteredVideoStep(_ step: Int) {
        guard step != 0 else { return }
        let videos = filteredVideos
        guard !videos.isEmpty else { return }
        var session = ReviewSession(
            focusedId: focusedVideoId ?? lastSelectedVideoId ?? selectedVideoIds.first,
            selectedIds: selectedVideoIds
        )
        session.moveFocus(step: step, orderedIds: videos.map(\.id))
        guard let newId = session.focusedId, newId != focusedVideoId else { return }
        setReviewFocus(newId, scroll: true)
    }

    /// Home / End key equivalents: select the first / last video in the current filtered order and
    /// scroll it into view. Uses `.top`/`.bottom` (not `scrollToVideoId`'s `.toRow`, which minimally
    /// reveals off-screen rows without re-centering rows already in view, and has no special handling
    /// for List's column header) so List's
    /// first row lands fully clear of the header instead of partially hidden under it.
    /// Select All (⌘A) for the Wall grid — List's `Table` handles ⌘A natively.
    func selectAllVideos() {
        guard !filteredVideos.isEmpty else { return }
        selectedVideoIds = Set(filteredVideos.map(\.id))
    }

    /// Deselect All (⌘⇧A) — works in both List and Wall grid, since unlike ⌘A, `Table` has no
    /// native "deselect all" gesture to defer to.
    func deselectAllVideos() {
        guard !selectedVideoIds.isEmpty else { return }
        selectedVideoIds = []
    }

    func goToFirstVideo() {
        guard let first = filteredVideos.first else { return }
        setReviewFocus(first.id)
        issueScrollCommand(.top)
    }

    func goToLastVideo() {
        guard let last = filteredVideos.last else { return }
        setReviewFocus(last.id)
        issueScrollCommand(.bottom)
    }

    func showFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select folders containing video files"
        panel.prompt = "Scan"

        if panel.runModal() == .OK {
            for url in panel.urls {
                Task { await scanFolder(url) }
            }
        }
    }

    /// Empty-library “Add Files…” — pick video files and/or folders.
    func showAddMediaPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg]
        panel.message = "Select video files or folders to add to your library"
        panel.prompt = "Add"

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let folders = urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let files = urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }
        Task {
            let beforePaths = await snapshotLibraryPaths()
            for folder in folders {
                await scanFolder(folder, recordAsLastAdded: false)
            }
            if !files.isEmpty {
                await importDroppedFiles(files, recordAsLastAdded: false)
            }
            await commitLastAdded(before: beforePaths)
        }
    }

    func scanFolder(_ url: URL, recordAsLastAdded: Bool = true) async {
        isScanning = true
        scanProgress = "Scanning..."
        stopObserving()

        let beforePaths = recordAsLastAdded ? await snapshotLibraryPaths() : []

        let path = url.path
        let alreadySaved = (try? await dataSourceRepo.exists(folderPath: path)) ?? false
        if !alreadySaved {
            let source = DataSource(
                folderPath: path,
                name: url.lastPathComponent,
                dateAdded: Date()
            )
            try? await dataSourceRepo.insert(source)
        }

        var failureCount = 0
        for await update in await scanner.scan(folder: url) {
            switch update {
            case .started(let total):
                scanTotal = total
                scanCurrent = 0
            case .progress(let current, let total, _):
                scanCurrent = current
                scanTotal = total
            case .partialFailure(let count):
                failureCount = count
            case .completed:
                if failureCount > 0 {
                    let message = "Added \(scanTotal - failureCount)/\(scanTotal) — \(failureCount) failed (see console)"
                    scanProgress = message
                    Task { [message] in
                        try? await Task.sleep(for: .seconds(4))
                        if scanProgress == message { scanProgress = "" }
                    }
                } else {
                    scanProgress = ""
                }
                isScanning = false
                await refreshAfterScan()
                if recordAsLastAdded {
                    await commitLastAdded(before: beforePaths)
                }
            case .error(let message):
                scanProgress = "Error: \(message)"
                isScanning = false
                startObserving()
            }
        }
    }

    func applyRating(to videoIds: Set<String>, rating: Int) {
        var updated = videos
        for idx in updated.indices where videoIds.contains(updated[idx].filePath) {
            updated[idx].rating = rating
        }
        videos = updated
    }

    /// Rescans videos in the **current filtered list** for a sidecar `.srt` and updates
    /// `subtitlePresence` via `applying(sidecarPresent:)` (preserves burned-in marks).
    /// Disk I/O is chunked and dispatched off the main actor so the UI remains responsive; progress is
    /// reported via `scanCurrent` / `scanTotal` / `scanProgress`.
    func scanForSubtitles() async {
        guard !isScanning else { return }
        guard !filteredVideos.isEmpty else {
            let message = videos.isEmpty ? "No videos to scan" : "No videos match the current filter"
            scanProgress = message
            Task { [message] in
                try? await Task.sleep(for: .seconds(2))
                if scanProgress == message { scanProgress = "" }
            }
            return
        }

        // Snapshot inputs once — only videos with a DB id can be updated.
        struct Row: Sendable {
            let dbId: Int64
            let filePath: String
            let current: SubtitlePresence
        }
        let snapshot: [Row] = filteredVideos.compactMap { v in
            guard let id = v.databaseId else { return nil }
            return Row(dbId: id, filePath: v.filePath, current: v.subtitlePresence)
        }
        let total = snapshot.count

        isScanning = true
        stopObserving()
        scanTotal = total
        scanCurrent = 0
        scanProgress = "Scanning \(total) video\(total == 1 ? "" : "s") for subtitles…"

        // Process in chunks on a background task so the UI can keep drawing progress.
        let chunkSize = 200
        var updates: [(videoId: Int64, presence: SubtitlePresence)] = []
        var index = 0
        while index < snapshot.count {
            let end = min(index + chunkSize, snapshot.count)
            let chunk = Array(snapshot[index..<end])
            let chunkUpdates: [(Int64, SubtitlePresence)] = await Task.detached(priority: .userInitiated) {
                var out: [(Int64, SubtitlePresence)] = []
                out.reserveCapacity(chunk.count)
                for row in chunk {
                    let url = URL(fileURLWithPath: row.filePath)
                    let hasNow = SubtitleTrack.findSidecarSRT(for: url) != nil
                    let next = row.current.applying(sidecarPresent: hasNow)
                    if next != row.current {
                        out.append((row.dbId, next))
                    }
                }
                return out
            }.value
            updates.append(contentsOf: chunkUpdates.map { ($0.0, $0.1) })
            index = end
            scanCurrent = index
        }

        let gainedSidecar = updates.filter {
            $0.presence == .sidecar || $0.presence == .burnedInAndSidecar
        }.count
        let lostSidecar = updates.count - gainedSidecar

        if !updates.isEmpty {
            try? await videoRepo.updateSubtitlePresence(updates: updates)
            videos = (try? await videoRepo.fetchAll()) ?? videos
            // `applyFilteredVideos` only bumps `filteredVideosVersion` when the **set** of rows
            // changes — so a subtitle-only edit leaves the list/grid `.id(...)` unchanged and
            // SwiftUI reuses stale `Video` values. Force a version bump so both views remount
            // with the refreshed presence.
            filteredVideosVersion &+= 1
        }
        startObserving()
        isScanning = false

        let summary: String
        switch (gainedSidecar, lostSidecar) {
        case (0, 0):
            summary = "No subtitle changes found"
        case (let a, 0):
            summary = "Found sidecar subtitles for \(a) video\(a == 1 ? "" : "s")"
        case (0, let r):
            summary = "Removed sidecar flag on \(r) video\(r == 1 ? "" : "s")"
        case (let a, let r):
            summary = "Sidecar found on \(a), removed on \(r)"
        }
        scanProgress = summary
        Task { [summary] in
            try? await Task.sleep(for: .seconds(4))
            if scanProgress == summary { scanProgress = "" }
        }
    }

    /// Re-extracts metadata for a video that appears corrupt. Called when the user views a
    /// corrupt video in the detail pane — covers files repaired externally (e.g. via ffmpeg)
    /// that now have valid metadata but whose DB record still shows nil fields.
    func refreshMetadataIfCorrupt(for video: Video) async {
        guard isCorrupt(video) else { return }
        let metadata = await MetadataExtractor().extract(from: video.url)
        guard metadata.duration != nil || metadata.width != nil else { return }
        guard let idx = videoIndexByPath[video.filePath] else { return }
        var updated = videos
        updated[idx].duration = metadata.duration
        updated[idx].width = metadata.width
        updated[idx].height = metadata.height
        if let codec = metadata.codec { updated[idx].codec = codec }
        if let frameRate = metadata.frameRate { updated[idx].frameRate = frameRate }
        let updatedVideo = updated[idx]
        videos = updated
        try? await videoRepo.update(updatedVideo)

        if updatedVideo.thumbnailPath == nil,
           let thumbURL = try? await thumbnailService.generateThumbnail(for: updatedVideo) {
            await setThumbnailPath(videoPath: updatedVideo.filePath, url: thumbURL)
        }
    }

    private func isCorrupt(_ video: Video) -> Bool {
        Self.isCorrupt(video, thumbnailsSettled: thumbnailsSettled)
    }

    func setThumbnailPath(videoPath: String, url: URL) async {
        guard let idx = videoIndexByPath[videoPath] else { return }
        var updated = videos
        updated[idx].thumbnailPath = url.path
        let dbId = updated[idx].databaseId
        videos = updated
        if let dbId {
            try? await videoRepo.updateThumbnailPath(videoId: dbId, path: url.path)
        }
    }

    /// Persists a *regenerated* thumbnail and bumps a cache-busting suffix onto `thumbnailPath`, so
    /// already-rendered Wall cards / list rows (keyed on `thumbnailPath` as their reload trigger)
    /// actually pick up the new image. Plain `setThumbnailPath` writes the bare disk path, which is a
    /// deterministic hash of the file path and doesn't change between regenerations — so a bare write
    /// wouldn't produce a new value for anything keyed on it to react to.
    func setRegeneratedThumbnailPath(videoPath: String, url: URL) async {
        guard let idx = videoIndexByPath[videoPath] else { return }
        var updated = videos
        let versioned = "\(url.path)#\(Date().timeIntervalSince1970)"
        updated[idx].thumbnailPath = versioned
        let dbId = updated[idx].databaseId
        videos = updated
        if let dbId {
            try? await videoRepo.updateThumbnailPath(videoId: dbId, path: versioned)
        }
    }

    /// Open an image picker and apply the chosen file as the poster for every video in `videos`
    /// (same image for all). No-op if the user cancels.
    func chooseAndApplyPosterImage(to videos: [Video], thumbnailService: ThumbnailService) async {
        guard !videos.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Set Poster"
        panel.message = videos.count == 1
            ? "Choose an image to use as this video’s poster thumbnail"
            : "Choose an image to use as the poster thumbnail for \(videos.count) selected videos"
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let imageURL = panel.url else { return }
        await applyPosterImage(from: imageURL, to: videos, thumbnailService: thumbnailService)
    }

    /// Write `imageURL` into each video’s library poster cache (thumb + detail still) and bump
    /// `thumbnailPath` so grid/list refresh. Filmstrips are left alone.
    func applyPosterImage(
        from imageURL: URL,
        to videos: [Video],
        thumbnailService: ThumbnailService
    ) async {
        guard !videos.isEmpty else { return }
        var applied = 0
        for video in videos {
            do {
                let url = try await thumbnailService.setPoster(fromImageURL: imageURL, for: video)
                await setRegeneratedThumbnailPath(videoPath: video.filePath, url: url)
                applied += 1
            } catch {
                reportTransientError("Couldn't set poster for \"\(video.displayTitle)\": \(error.localizedDescription)")
            }
        }
        if applied > 0 {
            let text = applied == 1 ? "Poster updated" : "Poster updated on \(applied) videos"
            scanProgress = text
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                if self?.scanProgress == text { self?.scanProgress = "" }
            }
        }
    }

    /// Sets subtitle presence in-memory and persists. No-op when unchanged.
    /// Surgical: updates one row without the O(n) didSet cascade and discards the GRDB observation
    /// echo so edits don't reload the full library.
    /// - Parameter syncFiltered: When true (Inspector), also patch `filteredVideos` and bump version
    ///   so badges remount. Play-time discovery leaves filtered rows alone to avoid grid thrash.
    func setSubtitlePresence(
        videoPath: String,
        presence: SubtitlePresence,
        syncFiltered: Bool = true
    ) async {
        guard let idx = videoIndexByPath[videoPath] else { return }
        guard videos[idx].subtitlePresence != presence else { return }

        suppressVideosDidSet = true
        var updated = videos
        updated[idx].subtitlePresence = presence
        let dbId = updated[idx].databaseId
        videos = updated
        videosByPath[videoPath] = updated[idx]
        if syncFiltered, let fIdx = filteredIndexByPath[videoPath], fIdx < filteredVideos.count {
            var filtered = filteredVideos
            filtered[fIdx].subtitlePresence = presence
            filteredVideos = filtered
            filteredVideosVersion &+= 1
        }
        suppressVideosDidSet = false

        if let dbId {
            discardObservationDeliveries += 1
            try? await videoRepo.updateSubtitlePresence(videoId: dbId, presence: presence)
        }
    }

    /// Apply a chosen presence to every selected path (Inspector multi-edit).
    func setSubtitlePresence(videoPaths: Set<String>, presence: SubtitlePresence) async {
        let paths = videoPaths.filter { videoIndexByPath[$0] != nil }
        guard !paths.isEmpty else { return }

        var bulk: [(videoId: Int64, presence: SubtitlePresence)] = []
        suppressVideosDidSet = true
        var updated = videos
        var filtered = filteredVideos
        var anyChange = false
        for path in paths {
            guard let idx = videoIndexByPath[path] else { continue }
            guard updated[idx].subtitlePresence != presence else { continue }
            anyChange = true
            updated[idx].subtitlePresence = presence
            videosByPath[path] = updated[idx]
            if let fIdx = filteredIndexByPath[path], fIdx < filtered.count {
                filtered[fIdx].subtitlePresence = presence
            }
            if let dbId = updated[idx].databaseId {
                bulk.append((dbId, presence))
            }
        }
        videos = updated
        filteredVideos = filtered
        if anyChange { filteredVideosVersion &+= 1 }
        suppressVideosDidSet = false

        if !bulk.isEmpty {
            discardObservationDeliveries += 1
            try? await videoRepo.updateSubtitlePresence(updates: bulk)
        }
    }

    /// Play-time helper: merge sidecar detection into the current presence without wiping burned-in.
    func applySidecarSubtitlePresence(videoPath: String, sidecarPresent: Bool) async {
        guard let idx = videoIndexByPath[videoPath] else { return }
        let next = videos[idx].subtitlePresence.applying(sidecarPresent: sidecarPresent)
        await setSubtitlePresence(videoPath: videoPath, presence: next, syncFiltered: false)
    }

    func persistRating(for videoIds: Set<String>, rating: Int) async {
        let dbIds = videos.filter { videoIds.contains($0.filePath) }.compactMap(\.databaseId)
        guard !dbIds.isEmpty else { return }

        if dbIds.count == 1 {
            try? await videoRepo.updateRating(videoId: dbIds[0], rating: rating)
        } else {
            stopObserving()
            try? await videoRepo.updateRating(videoIds: dbIds, rating: rating)
            videos = (try? await videoRepo.fetchAll()) ?? []
            startObserving()
        }
    }

    /// Per-field merged string; `nil` means selected videos disagree (show “Various”).
    func mergedCustomMetadata(forVideoPaths paths: [String]) async -> [UUID: String?] {
        let defs = customMetadataFieldDefinitions
        guard !defs.isEmpty else { return [:] }
        let dbIds = paths.compactMap { path in
            videos.first(where: { $0.filePath == path })?.databaseId
        }
        guard !dbIds.isEmpty else {
            return Dictionary(uniqueKeysWithValues: defs.map { ($0.id, nil as String?) })
        }

        var perVideo: [[String: String]] = []
        for dbId in dbIds {
            let row = (try? await videoRepo.fetchCustomMetadata(forVideoId: dbId)) ?? [:]
            perVideo.append(row)
        }

        var out: [UUID: String?] = [:]
        for def in defs {
            let key = def.id.uuidString
            let vals = perVideo.map { $0[key] ?? "" }
            if Set(vals).count == 1 {
                out[def.id] = vals.first
            } else {
                out[def.id] = nil
            }
        }
        return out
    }

    func persistCustomMetadata(fieldId: UUID, value: String, forVideoPaths paths: Set<String>) async {
        let dbIds = videos.filter { paths.contains($0.filePath) }.compactMap(\.databaseId)
        guard !dbIds.isEmpty else { return }
        try? await videoRepo.upsertCustomMetadata(videoIds: dbIds, fieldId: fieldId, value: value)
        for id in dbIds {
            mergeListCustomMetadataCache(videoId: id, fieldId: fieldId, value: value)
        }
        refreshSearchIfActive()
    }

    enum RenameVideoResult: Equatable {
        case success(String)
        case failure(String)
    }

    @discardableResult
    func renameVideo(_ video: Video, to newName: String, reportErrors: Bool = true) async -> RenameVideoResult {
        guard let dbId = video.databaseId else {
            return .failure("Video has no library id")
        }
        guard !activeMoveVideoIds.contains(video.filePath) else {
            let reason = "Can't rename \"\(video.fileName)\" — a move is still in progress"
            if reportErrors { reportTransientError(reason) }
            return .failure(reason)
        }

        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return .failure("New file name is empty")
        }

        let oldURL = video.url
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(trimmed)
        let newFilePath = newURL.path

        // Case-insensitive filesystems (APFS/HFS+): a case-only rename makes fileExists return
        // true and moveItem a no-op because both paths resolve to the same inode. Use a temp name.
        let isCaseOnlyRename = oldURL.path.lowercased() == newURL.path.lowercased()

        if !isCaseOnlyRename {
            guard !FileManager.default.fileExists(atPath: newFilePath) else {
                print("Rename failed: file already exists at \(newFilePath)")
                let reason = "A file named \"\(trimmed)\" already exists here"
                if reportErrors { reportTransientError(reason) }
                return .failure(reason)
            }
        }

        do {
            if isCaseOnlyRename {
                let tempURL = oldURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString)")
                try FileManager.default.moveItem(at: oldURL, to: tempURL)
                try FileManager.default.moveItem(at: tempURL, to: newURL)
            } else {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            }
            try await videoRepo.renameVideo(
                videoId: dbId,
                newFilePath: newFilePath,
                newFileName: trimmed,
                previousFileName: video.fileName
            )
            thumbnailService.migrateCacheKey(from: video.filePath, to: newFilePath)
            if let idx = videos.firstIndex(where: { $0.databaseId == dbId }) {
                var updated = videos
                let previousName = video.fileName
                updated[idx].filePath = newFilePath
                updated[idx].fileName = trimmed
                if updated[idx].title == previousName || updated[idx].title.isEmpty {
                    updated[idx].title = trimmed
                }
                videos = updated
            }
            remapVideoPathInSelection(from: video.filePath, to: newFilePath)
            if isSortedByName {
                pendingScrollToAfterRename = newFilePath
            }
            return .success(newFilePath)
        } catch {
            print("Rename failed: \(error)")
            let reason = "Couldn't rename \"\(video.fileName)\""
            if reportErrors { reportTransientError(reason) }
            return .failure(reason)
        }
    }

    /// Updates the library display title without renaming the file on disk.
    func updateVideoTitle(_ video: Video, to newTitle: String) async {
        guard let dbId = video.databaseId else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? video.fileName : trimmed
        do {
            try await videoRepo.updateTitle(videoId: dbId, title: resolved)
            if let idx = videos.firstIndex(where: { $0.databaseId == dbId }) {
                var updated = videos
                updated[idx].title = resolved
                videos = updated
            }
            if isSortedByName {
                pendingScrollToAfterRename = video.filePath
            }
        } catch {
            reportTransientError("Couldn't update title for \"\(video.displayTitle)\"")
        }
    }

    func beginEditingTitle(for video: Video) {
        renamingVideoId = nil
        renameText = ""
        titleEditText = video.displayTitle
        editingTitleVideoId = video.id
    }

    func beginRenamingFile(for video: Video) {
        editingTitleVideoId = nil
        titleEditText = ""
        renameText = video.fileName
        renamingVideoId = video.id
    }

    func cancelTitleEdit() {
        editingTitleVideoId = nil
        titleEditText = ""
    }

    func cancelFileRename() {
        renamingVideoId = nil
        renameText = ""
    }

    /// Same-volume moves are an atomic rename (instant, no partial-file risk) and run inline.
    /// Cross-volume moves are a real copy + delete and go through the persisted move queue
    /// (`MoveJob`) so progress is visible and conflicting actions on the file can be disabled
    /// until it's safe again — see `MoveFiles_Queue_Plan_2026-07-03.md`.
    func moveVideos(_ videosToMove: [Video], to destinationFolder: URL) async {
        for video in videosToMove {
            let newURL = destinationFolder.appendingPathComponent(video.fileName)
            if newURL.path == video.url.path { continue }
            guard !FileManager.default.fileExists(atPath: newURL.path) else {
                recordFailedMoveJob(video: video, destinationFolder: destinationFolder,
                                     reason: "\(video.fileName) already exists at destination")
                continue
            }
            if isSameVolume(video.url, destinationFolder) {
                await performSameVolumeMove(video: video, newURL: newURL)
            } else {
                enqueueMoveJob(video: video, destinationFolder: destinationFolder)
            }
        }
        startDrainingMovesIfNeeded()
    }

    private func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let av = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject,
              let bv = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        else { return false }
        return av.isEqual(bv)
    }

    private func performSameVolumeMove(video: Video, newURL: URL) async {
        let wasSelected = selectedVideoIds.contains(video.filePath)
        let wasLastSelected = lastSelectedVideoId == video.filePath

        let fm = FileManager.default
        do {
            try fm.moveItem(at: video.url, to: newURL)
        } catch {
            recordFailedMoveJob(video: video, destinationFolder: newURL.deletingLastPathComponent(),
                                 reason: "Failed to move: \(error.localizedDescription)")
            return
        }
        guard let dbId = video.databaseId else { return }
        do {
            try await videoRepo.renameVideo(
                videoId: dbId,
                newFilePath: newURL.path,
                newFileName: newURL.lastPathComponent,
                previousFileName: video.fileName
            )
        } catch {
            try? fm.moveItem(at: newURL, to: video.url)
            recordFailedMoveJob(video: video, destinationFolder: newURL.deletingLastPathComponent(),
                                 reason: "Moved, but couldn't update the library — rolled back.")
            return
        }

        // Everything below is synchronous (no further `await`) so none of it can be interleaved
        // by GRDB's independent observation stream — that stream reacts to the DB write above on
        // its own async path and, left alone, can update `videos`/prune `selectedVideoIds` at an
        // arbitrary moment relative to our own selection update, dropping the video's selection
        // depending on exactly how the race lands. Applying the rename to `videos` ourselves
        // first, then updating selection, in one uninterrupted block, means the two can never be
        // inconsistent — GRDB's later redundant delivery of the same data is then a no-op.
        thumbnailService.migrateCacheKey(from: video.filePath, to: newURL.path)
        if let idx = videos.firstIndex(where: { $0.databaseId == dbId }) {
            var updated = videos
            updated[idx].filePath = newURL.path
            updated[idx].fileName = newURL.lastPathComponent
            if updated[idx].title == video.fileName || updated[idx].title.isEmpty {
                updated[idx].title = newURL.lastPathComponent
            }
            videos = updated
        }
        if wasSelected || wasLastSelected || focusedVideoId == video.filePath {
            remapVideoPathInSelection(from: video.filePath, to: newURL.path)
        }
    }

    func videoConvertedToMP4(_ video: Video, newPath: String) async {
        guard let dbId = video.databaseId else { return }
        let newURL = URL(fileURLWithPath: newPath)
        let newFileName = newURL.lastPathComponent

        do {
            try await videoRepo.renameVideo(
                videoId: dbId,
                newFilePath: newPath,
                newFileName: newFileName,
                previousFileName: video.fileName
            )
        } catch {
            print("videoConvertedToMP4 DB update failed: \(error)")
            reportTransientError("Converted \"\(newFileName)\" but couldn't update the library record")
            return
        }

        remapVideoPathInSelection(from: video.filePath, to: newPath)

        // Look up by DB id, not filePath: GRDB's observation may have already updated
        // the in-memory path (e.g. wmv→mp4) before we reach this line.
        guard let idx = videos.firstIndex(where: { $0.databaseId == dbId }) else { return }
        var updated = videos
        updated[idx].filePath = newPath
        updated[idx].fileName = newFileName
        if updated[idx].title == video.fileName || updated[idx].title.isEmpty {
            updated[idx].title = newFileName
        }
        updated[idx].thumbnailPath = nil
        if let size = (try? newURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            updated[idx].fileSize = Int64(size)
        }

        let metadata = await MetadataExtractor().extract(from: newURL)
        if let duration = metadata.duration { updated[idx].duration = duration }
        if let width = metadata.width { updated[idx].width = width }
        if let height = metadata.height { updated[idx].height = height }
        if let codec = metadata.codec { updated[idx].codec = codec }
        if let frameRate = metadata.frameRate { updated[idx].frameRate = frameRate }
        // Re-encoding rewrote the file, so the old fingerprint is stale — recompute from the new
        // content (falls back to nil → backfill picks it up if the file isn't readable right now).
        updated[idx].contentFingerprint = ContentFingerprint.compute(url: newURL)

        let updatedVideo = updated[idx]
        videos = updated
        try? await videoRepo.update(updatedVideo)

        if let thumbURL = try? await thumbnailService.generateThumbnail(for: updatedVideo) {
            await setThumbnailPath(videoPath: newPath, url: thumbURL)
        }

        if selectedVideoIds.contains(newPath) {
            filmstripRefreshId &+= 1
        }
    }

    // MARK: - Re-encode queue

    /// [path: completion date] for completed jobs — feeds the "recently converted" filter/badge.
    private var recentlyConvertedDates: [String: Date] {
        var result: [String: Date] = [:]
        for job in conversionJobs where job.isCompleted {
            if let path = job.convertedPath, let date = job.completedAt { result[path] = date }
        }
        return result
    }

    /// True when there is anything to show in the queue manager (active work or kept history).
    var hasConversionActivity: Bool { !conversionJobs.isEmpty }

    /// Short status for the header pill / status bar.
    var conversionStatusText: String {
        if let running = conversionJobs.first(where: { if case .converting = $0.status { return true }; return false }) {
            let pct: Int = { if case .converting(let p) = running.status { return p }; return 0 }()
            let queued = conversionJobs.filter { $0.status == .queued }.count
            let base = "Re-encoding '\(running.sourceFileName)'… \(pct)%"
            return queued > 0 ? "\(base) (+\(queued) queued)" : base
        }
        let queued = conversionJobs.filter { $0.status == .queued }.count
        if queued > 0 { return queued == 1 ? "1 queued to re-encode" : "\(queued) queued to re-encode" }
        let failed = conversionJobs.filter { if case .failed = $0.status { return true }; return false }.count
        if failed > 0 { return failed == 1 ? "1 re-encode failed" : "\(failed) re-encodes failed" }
        let completed = conversionJobs.filter { $0.isCompleted }.count
        return completed == 1 ? "1 re-encoded" : "\(completed) re-encoded"
    }

    func reencodeVideo(_ video: Video, ffmpegPath: String) {
        // Don't queue a file that already has an active job.
        if conversionJobs.contains(where: { $0.isActive && $0.videoDatabaseId != nil && $0.videoDatabaseId == video.databaseId }) {
            return
        }
        conversionJobs.append(ConversionJob(video: video, ffmpegPath: ffmpegPath))
        persistConversionJobs()
        startDrainingIfNeeded()
    }

    private func persistConversionJobs() {
        if let data = try? JSONEncoder().encode(conversionJobs) {
            UserDefaults.standard.set(data, forKey: Self.conversionJobsKey)
        }
    }

    /// Update a job's status in place. Progress ticks pass `persist: false` to avoid
    /// hammering UserDefaults; state transitions persist.
    private func updateJobStatus(_ id: UUID, _ status: ConversionJob.Status, persist: Bool = true) {
        guard let idx = conversionJobs.firstIndex(where: { $0.id == id }) else { return }
        conversionJobs[idx].status = status
        if persist { persistConversionJobs() }
    }

    private func startDrainingIfNeeded() {
        guard !isDrainingConversions,
              conversionJobs.contains(where: { $0.status == .queued }) else { return }
        isDrainingConversions = true
        Task { await drainConversionQueue() }
    }

    private func drainConversionQueue() async {
        defer { isDrainingConversions = false }
        while let idx = conversionJobs.firstIndex(where: { $0.status == .queued }) {
            let jobId = conversionJobs[idx].id
            updateJobStatus(jobId, .converting(pct: 0))
            await performReencode(jobId: jobId)
        }
    }

    private func performReencode(jobId: UUID) async {
        guard let job = conversionJobs.first(where: { $0.id == jobId }) else { return }

        // Resolve the current on-disk path (a prior conversion/rename may have moved it).
        let liveVideo = job.videoDatabaseId.flatMap { dbId in videos.first { $0.databaseId == dbId } }
        let sourcePath = liveVideo?.filePath ?? job.sourcePath
        let sourceName = liveVideo?.fileName ?? job.sourceFileName
        let duration = liveVideo?.duration ?? job.durationSeconds

        let videoURL = URL(fileURLWithPath: sourcePath)
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let ext = videoURL.pathExtension
        let dir = videoURL.deletingLastPathComponent().path
        func inDir(_ name: String) -> URL { URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name)) }
        let convertURL = inDir("\(stem)_convert.mp4")
        let backupURL = inDir(ext.isEmpty ? "\(stem)_backup" : "\(stem)_backup.\(ext)")
        let finalURL = inDir("\(stem).mp4")
        let fm = FileManager.default

        // Preconditions. The original is never touched until ffmpeg succeeds.
        guard fm.fileExists(atPath: videoURL.path) else {
            updateJobStatus(jobId, .failed(reason: "Source file is missing"))
            return
        }
        guard !fm.fileExists(atPath: backupURL.path) else {
            updateJobStatus(jobId, .failed(reason: "A backup (\(backupURL.lastPathComponent)) already exists"))
            return
        }
        if finalURL.path != videoURL.path, fm.fileExists(atPath: finalURL.path) {
            updateJobStatus(jobId, .failed(reason: "\(finalURL.lastPathComponent) already exists"))
            return
        }
        // Clear any stale temp from a prior interrupted run.
        try? fm.removeItem(at: convertURL)

        let progressPipe = Pipe()
        // Read ffmpeg's -progress stream and push a live percentage into the job (in-memory only).
        let progressTask = Task.detached(priority: .utility) { [weak self] in
            let handle = progressPipe.fileHandleForReading
            var buffer = ""
            while true {
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { break }
                buffer += chunk
                var lines = buffer.components(separatedBy: "\n")
                buffer = lines.removeLast()
                for line in lines {
                    guard line.hasPrefix("out_time_ms="),
                          let us = Double(line.dropFirst("out_time_ms=".count)),
                          let dur = duration, dur > 0
                    else { continue }
                    let pct = min(99, Int(us / (dur * 1_000_000) * 100))
                    await MainActor.run { [weak self] in
                        self?.updateJobStatus(jobId, .converting(pct: pct), persist: false)
                    }
                }
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: job.ffmpegPath)
        proc.arguments = ["-i", videoURL.path, "-c:v", "libx264", "-c:a", "aac",
                          "-movflags", "+faststart", "-y", "-progress", "pipe:1", convertURL.path]
        proc.standardOutput = progressPipe
        proc.standardError = FileHandle.nullDevice
        currentConversionProcess = proc

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            proc.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
            guard (try? proc.run()) != nil else {
                continuation.resume(returning: Int32(-1))
                return
            }
        }
        currentConversionProcess = nil
        // Wait for the progress reader to drain the pipe before continuing.
        await progressTask.value

        // The job may have been aborted (and removed) while ffmpeg ran.
        let stillTracked = conversionJobs.contains { $0.id == jobId }

        guard exitCode == 0 else {
            try? fm.removeItem(at: convertURL) // discard partial; original untouched
            if stillTracked {
                updateJobStatus(jobId, .failed(reason: "Re-encoding failed"))
            }
            return
        }

        // Success: move the original aside, promote the converted file to the final name.
        do {
            try fm.moveItem(at: videoURL, to: backupURL)
        } catch {
            try? fm.removeItem(at: convertURL)
            if stillTracked { updateJobStatus(jobId, .failed(reason: "Couldn't rename original: \(error.localizedDescription)")) }
            return
        }
        do {
            try fm.moveItem(at: convertURL, to: finalURL)
        } catch {
            try? fm.moveItem(at: backupURL, to: videoURL) // roll back
            if stillTracked { updateJobStatus(jobId, .failed(reason: "Couldn't finalize output: \(error.localizedDescription)")) }
            return
        }

        // Point the DB record at the new file (handles path/extension change and metadata refresh).
        if let video = liveVideo {
            await videoConvertedToMP4(video, newPath: finalURL.path)
        }

        // Record completion. If the job was aborted mid-flight the file work is already
        // done, so still trash the just-created backup to leave a clean result.
        if let idx = conversionJobs.firstIndex(where: { $0.id == jobId }) {
            conversionJobs[idx].status = .completed
            conversionJobs[idx].completedAt = Date()
            conversionJobs[idx].convertedPath = finalURL.path
            conversionJobs[idx].backupPath = backupURL.path
            conversionJobs[idx].sourcePath = finalURL.path
            conversionJobs[idx].sourceFileName = finalURL.lastPathComponent
            persistConversionJobs()
        } else {
            try? fm.trashItem(at: backupURL, resultingItemURL: nil)
        }
        _ = sourceName // (retained for potential status messaging)
        updateLibraryCounts()
        recomputeFilteredVideos()
    }

    // MARK: - Queue management actions

    /// Abort a queued job (remove it) or the running one (terminate ffmpeg, discard partial).
    func abortConversion(_ id: UUID) {
        guard let idx = conversionJobs.firstIndex(where: { $0.id == id }) else { return }
        let wasRunning: Bool = { if case .converting = conversionJobs[idx].status { return true }; return false }()
        conversionJobs.remove(at: idx)
        persistConversionJobs()
        if wasRunning {
            currentConversionProcess?.terminate() // performReencode will discard the partial
        }
    }

    /// Move a queued job ahead of the other queued jobs (can't jump the running one).
    func moveConversionToTop(_ id: UUID) {
        guard let from = conversionJobs.firstIndex(where: { $0.id == id }),
              conversionJobs[from].status == .queued else { return }
        let job = conversionJobs.remove(at: from)
        let insertAt = conversionJobs.firstIndex(where: { $0.status == .queued }) ?? conversionJobs.count
        conversionJobs.insert(job, at: insertAt)
        persistConversionJobs()
    }

    /// Remove a finished/failed row (and its partial, if any) from the history.
    func dismissConversion(_ id: UUID) {
        guard let idx = conversionJobs.firstIndex(where: { $0.id == id }),
              !conversionJobs[idx].isActive else { return }
        let wasCompleted = conversionJobs[idx].isCompleted
        conversionJobs.remove(at: idx)
        persistConversionJobs()
        if wasCompleted {
            // Dropped from the "recently converted" smart filter/count.
            updateLibraryCounts()
            recomputeFilteredVideos()
        }
    }

    /// Re-queue a failed job. No-op if ffmpeg can't be resolved.
    func retryConversion(_ id: UUID) {
        guard let idx = conversionJobs.firstIndex(where: { $0.id == id }),
              case .failed = conversionJobs[idx].status,
              let ffmpeg = resolvedFFmpegPath else { return }
        conversionJobs[idx].status = .queued
        conversionJobs[idx].ffmpegPath = ffmpeg
        persistConversionJobs()
        startDrainingIfNeeded()
    }

    /// Trash the kept-aside backup for a completed job; the row stays (video is still converted).
    func deleteConversionBackup(_ id: UUID) {
        guard let idx = conversionJobs.firstIndex(where: { $0.id == id }),
              let backupPath = conversionJobs[idx].backupPath else { return }
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: backupPath), resultingItemURL: nil)
        conversionJobs[idx].backupPath = nil
        persistConversionJobs()
    }

    func deleteAllConversionBackups() {
        let fm = FileManager.default
        for idx in conversionJobs.indices where conversionJobs[idx].backupPath != nil {
            if let path = conversionJobs[idx].backupPath {
                try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
            conversionJobs[idx].backupPath = nil
        }
        persistConversionJobs()
    }

    /// Bulk-removes queue rows for completed jobs whose backup is already gone (deleted
    /// individually or via "Delete All Backups") — nothing left to Restore/Delete Backup for
    /// them, so they're just clutter. Narrower than "remove every completed job": one still
    /// holding its backup stays, since Restore/Delete Backup remain meaningful actions for it.
    func clearConvertedJobsWithDeletedBackup() {
        let hasAny = conversionJobs.contains { $0.isCompleted && $0.backupPath == nil }
        guard hasAny else { return }
        conversionJobs.removeAll { $0.isCompleted && $0.backupPath == nil }
        persistConversionJobs()
        updateLibraryCounts()
        recomputeFilteredVideos()
    }

    /// Undo a conversion: trash the converted `.mp4`, rename the backup back to the original
    /// name, and revert the DB record. Drops the job row on success.
    func restoreConversionBackup(_ id: UUID) async {
        guard let idx = conversionJobs.firstIndex(where: { $0.id == id }),
              conversionJobs[idx].isCompleted,
              let backupPath = conversionJobs[idx].backupPath,
              let convertedPath = conversionJobs[idx].convertedPath else { return }

        let fm = FileManager.default
        let backupURL = URL(fileURLWithPath: backupPath)
        guard fm.fileExists(atPath: backupPath) else {
            conversionJobs[idx].status = .failed(reason: "Backup file is missing")
            conversionJobs[idx].backupPath = nil
            persistConversionJobs()
            return
        }
        // Restored name drops the "_backup" suffix: clip_backup.mov -> clip.mov
        let backupStem = backupURL.deletingPathExtension().lastPathComponent
        let restoredStem = backupStem.hasSuffix("_backup") ? String(backupStem.dropLast("_backup".count)) : backupStem
        let dir = backupURL.deletingLastPathComponent()
        let restoredURL = dir.appendingPathComponent(
            backupURL.pathExtension.isEmpty ? restoredStem : "\(restoredStem).\(backupURL.pathExtension)")

        if restoredURL.path != convertedPath, fm.fileExists(atPath: restoredURL.path) {
            updateJobStatus(id, .failed(reason: "\(restoredURL.lastPathComponent) already exists"))
            return
        }

        // Trash the converted output, then restore the original name.
        try? fm.trashItem(at: URL(fileURLWithPath: convertedPath), resultingItemURL: nil)
        do {
            try fm.moveItem(at: backupURL, to: restoredURL)
        } catch {
            updateJobStatus(id, .failed(reason: "Couldn't restore backup: \(error.localizedDescription)"))
            return
        }

        if let dbId = conversionJobs.first(where: { $0.id == id })?.videoDatabaseId,
           let video = videos.first(where: { $0.databaseId == dbId }) {
            await videoConvertedToMP4(video, newPath: restoredURL.path)
        }

        conversionJobs.removeAll { $0.id == id }
        persistConversionJobs()
        updateLibraryCounts()
        recomputeFilteredVideos()
    }

    /// On launch: re-queue any job interrupted mid-encode, sweep stray `_convert.mp4`
    /// partials, and restart the drain loop. Called after the DB observation starts.
    func resumePendingConversions() {
        let fm = FileManager.default
        var changed = false
        for i in conversionJobs.indices {
            if case .converting = conversionJobs[i].status {
                conversionJobs[i].status = .queued
                changed = true
            }
        }
        // Orphan sweep: remove leftover temp files for any not-yet-completed job.
        for job in conversionJobs where !job.isCompleted {
            let url = URL(fileURLWithPath: job.sourcePath)
            let stem = url.deletingPathExtension().lastPathComponent
            let convertURL = url.deletingLastPathComponent().appendingPathComponent("\(stem)_convert.mp4")
            try? fm.removeItem(at: convertURL)
        }
        if changed { persistConversionJobs() }
        startDrainingIfNeeded()
    }

    // MARK: - Move queue (cross-volume moves only — see `moveVideos`)

    /// Video ids (file paths) with a queued or in-flight move — context menus disable
    /// destructive/file-touching actions for these until the move completes.
    var activeMoveVideoIds: Set<String> {
        Set(moveJobs.filter { $0.isActive }.compactMap { job -> String? in
            if let dbId = job.videoDatabaseId, let v = videos.first(where: { $0.databaseId == dbId }) {
                return v.filePath
            }
            return job.sourcePath
        })
    }

    var hasMoveActivity: Bool { !moveJobs.isEmpty }

    var moveStatusText: String {
        if let running = moveJobs.first(where: { if case .moving = $0.status { return true }; return false }) {
            let pct: Int = { if case .moving(let f) = running.status { return Int(f * 100) }; return 0 }()
            let queued = moveJobs.filter { $0.status == .queued }.count
            let base = "Moving '\(running.sourceFileName)'… \(pct)%"
            return queued > 0 ? "\(base) (+\(queued) queued)" : base
        }
        let queued = moveJobs.filter { $0.status == .queued }.count
        if queued > 0 { return queued == 1 ? "1 queued to move" : "\(queued) queued to move" }
        let failed = moveJobs.filter { if case .failed = $0.status { return true }; return false }.count
        if failed > 0 { return failed == 1 ? "1 move failed" : "\(failed) moves failed" }
        let completed = moveJobs.filter { $0.isCompleted }.count
        return completed == 1 ? "1 moved" : "\(completed) moved"
    }

    /// Top of the list, but below the currently-moving job (if any) — that job stays pinned at
    /// index 0 for the duration of its move (see `drainMoveQueue`).
    private var newestJobInsertionIndex: Int {
        moveJobs.contains(where: { if case .moving = $0.status { return true }; return false }) ? 1 : 0
    }

    private func recordFailedMoveJob(video: Video, destinationFolder: URL, reason: String) {
        var job = MoveJob(video: video, destinationFolder: destinationFolder)
        job.status = .failed(reason: reason)
        moveJobs.insert(job, at: newestJobInsertionIndex)
        persistMoveJobs()
    }

    private func enqueueMoveJob(video: Video, destinationFolder: URL) {
        guard !moveJobs.contains(where: { $0.isActive && $0.videoDatabaseId != nil && $0.videoDatabaseId == video.databaseId }) else { return }
        moveJobs.insert(MoveJob(video: video, destinationFolder: destinationFolder), at: newestJobInsertionIndex)
        persistMoveJobs()
    }

    private func persistMoveJobs() {
        if let data = try? JSONEncoder().encode(moveJobs) {
            UserDefaults.standard.set(data, forKey: Self.moveJobsKey)
        }
    }

    /// Update a job's status in place. Progress ticks pass `persist: false` to avoid
    /// hammering UserDefaults; state transitions persist.
    private func updateMoveJobStatus(_ id: UUID, _ status: MoveJob.Status, persist: Bool = true) {
        guard let idx = moveJobs.firstIndex(where: { $0.id == id }) else { return }
        moveJobs[idx].status = status
        if persist { persistMoveJobs() }
    }

    private func startDrainingMovesIfNeeded() {
        guard !isDrainingMoves, moveJobs.contains(where: { $0.status == .queued }) else { return }
        isDrainingMoves = true
        Task { await drainMoveQueue() }
    }

    private func drainMoveQueue() async {
        defer { isDrainingMoves = false }
        while let idx = moveJobs.firstIndex(where: { $0.status == .queued }) {
            let jobId = moveJobs[idx].id
            // The job that's about to run pops to the very top of the list, ahead of everything
            // else queued after it, so it's always obvious at a glance what's active right now.
            if idx != 0 {
                let job = moveJobs.remove(at: idx)
                moveJobs.insert(job, at: 0)
            }
            updateMoveJobStatus(jobId, .moving(fractionComplete: 0))
            await performMove(jobId: jobId)
        }
        // Successful moves need no post-hoc management (unlike re-encode backups). Drop them
        // so the header pill / menu only remain for failures or leftover active work.
        clearCompletedMoves()
    }

    private func performMove(jobId: UUID) async {
        guard let job = moveJobs.first(where: { $0.id == jobId }) else { return }
        let liveVideo = job.videoDatabaseId.flatMap { dbId in videos.first { $0.databaseId == dbId } }
        let sourcePath = liveVideo?.filePath ?? job.sourcePath
        let sourceName = liveVideo?.fileName ?? job.sourceFileName
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destFolder = URL(fileURLWithPath: job.destinationFolderPath)
        let tempURL = destFolder.appendingPathComponent("\(sourceName).moving")
        let finalURL = destFolder.appendingPathComponent(sourceName)
        let fm = FileManager.default

        let wasSelected = selectedVideoIds.contains(sourcePath)
        let wasLastSelected = lastSelectedVideoId == sourcePath

        // Preconditions. The original is never touched until the copy is verified complete.
        guard fm.fileExists(atPath: sourceURL.path) else {
            updateMoveJobStatus(jobId, .failed(reason: "Source file is missing"))
            return
        }
        guard finalURL.path == sourceURL.path || !fm.fileExists(atPath: finalURL.path) else {
            updateMoveJobStatus(jobId, .failed(reason: "\(finalURL.lastPathComponent) already exists at destination"))
            return
        }
        try? fm.removeItem(at: tempURL) // clear any stale partial from an interrupted prior run

        let abortLatch = MoveAbortLatch()
        currentMoveAbortLatch = abortLatch
        let copyTask = Task.detached(priority: .utility) { [weak self] in
            try ProgressiveFileCopy.copy(
                from: sourceURL,
                to: tempURL,
                isCancelled: { abortLatch.isAborted }
            ) { fraction in
                Task { @MainActor in
                    guard self?.moveJobs.contains(where: { $0.id == jobId }) == true else { return }
                    self?.updateMoveJobStatus(jobId, .moving(fractionComplete: fraction), persist: false)
                }
            }
        }
        currentMoveTask = copyTask
        do {
            try await copyTask.value
        } catch is CancellationError {
            currentMoveTask = nil
            currentMoveAbortLatch = nil
            try? fm.removeItem(at: tempURL)
            return
        } catch {
            currentMoveTask = nil
            currentMoveAbortLatch = nil
            try? fm.removeItem(at: tempURL)
            if moveJobs.contains(where: { $0.id == jobId }) {
                updateMoveJobStatus(jobId, .failed(reason: "Copy failed: \(error.localizedDescription)"))
            }
            return
        }
        currentMoveTask = nil

        guard !abortLatch.isAborted, moveJobs.contains(where: { $0.id == jobId }) else {
            currentMoveAbortLatch = nil
            try? fm.removeItem(at: tempURL)
            return
        }
        currentMoveAbortLatch = nil

        let srcSize = (try? fm.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64) ?? nil
        let tmpSize = (try? fm.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? nil
        guard let srcSize, let tmpSize, srcSize == tmpSize else {
            try? fm.removeItem(at: tempURL)
            updateMoveJobStatus(jobId, .failed(reason: "Copy verification failed (size mismatch)"))
            return
        }

        guard moveJobs.contains(where: { $0.id == jobId }) else {
            try? fm.removeItem(at: tempURL)
            return
        }

        do {
            try fm.moveItem(at: tempURL, to: finalURL) // same-volume rename of the temp — instant
        } catch {
            try? fm.removeItem(at: tempURL)
            updateMoveJobStatus(jobId, .failed(reason: "Couldn't finalize destination file: \(error.localizedDescription)"))
            return
        }

        guard moveJobs.contains(where: { $0.id == jobId }) else {
            try? fm.removeItem(at: finalURL)
            return
        }

        // Only now remove the source — the destination is fully valid at this point.
        do {
            try fm.removeItem(at: sourceURL)
        } catch {
            updateMoveJobStatus(jobId, .failed(reason: "Moved, but couldn't remove the original: \(error.localizedDescription)"))
            return
        }

        guard let dbId = liveVideo?.databaseId else {
            if let idx = moveJobs.firstIndex(where: { $0.id == jobId }) {
                moveJobs[idx].status = .completed
                moveJobs[idx].completedAt = Date()
                moveJobs[idx].newPath = finalURL.path
                persistMoveJobs()
            }
            return
        }
        do {
            try await videoRepo.renameVideo(
                videoId: dbId,
                newFilePath: finalURL.path,
                newFileName: sourceName,
                previousFileName: liveVideo?.fileName ?? job.sourceFileName
            )
        } catch {
            try? fm.moveItem(at: finalURL, to: sourceURL) // roll back so the file isn't silently lost
            updateMoveJobStatus(jobId, .failed(reason: "Moved the file, but couldn't update the library — rolled back."))
            return
        }
        // Synchronous from here (no further `await`) — see the matching comment in
        // `performSameVolumeMove` for why `videos` is updated locally before selection.
        thumbnailService.migrateCacheKey(from: sourcePath, to: finalURL.path)
        if let idx = videos.firstIndex(where: { $0.databaseId == dbId }) {
            var updated = videos
            let previousName = liveVideo?.fileName ?? job.sourceFileName
            updated[idx].filePath = finalURL.path
            updated[idx].fileName = sourceName
            if updated[idx].title == previousName || updated[idx].title.isEmpty {
                updated[idx].title = sourceName
            }
            videos = updated
        }
        if wasSelected || wasLastSelected || focusedVideoId == sourcePath {
            remapVideoPathInSelection(from: sourcePath, to: finalURL.path)
        }
        if let idx = moveJobs.firstIndex(where: { $0.id == jobId }) {
            moveJobs[idx].status = .completed
            moveJobs[idx].completedAt = Date()
            moveJobs[idx].newPath = finalURL.path
            persistMoveJobs()
        }
    }

    /// Abort one queued or in-flight move. Removes it from the queue; in-flight copies stop via
    /// the abort latch and discard the `.moving` partial (source untouched).
    func abortMove(_ id: UUID) {
        guard let idx = moveJobs.firstIndex(where: { $0.id == id }) else { return }
        let wasRunning: Bool = { if case .moving = moveJobs[idx].status { return true }; return false }()
        moveJobs.remove(at: idx)
        persistMoveJobs()
        if wasRunning {
            currentMoveAbortLatch?.abort()
            currentMoveTask?.cancel()
        }
    }

    /// Abort every queued and in-flight move at once. Completed / failed history is left alone.
    func abortAllMoves() {
        let hadRunning = moveJobs.contains { if case .moving = $0.status { return true }; return false }
        let before = moveJobs.count
        moveJobs.removeAll { $0.isActive }
        guard moveJobs.count != before || hadRunning else { return }
        persistMoveJobs()
        if hadRunning {
            currentMoveAbortLatch?.abort()
            currentMoveTask?.cancel()
        }
    }

    func moveJobToTop(_ id: UUID) {
        guard let from = moveJobs.firstIndex(where: { $0.id == id }), moveJobs[from].status == .queued else { return }
        let job = moveJobs.remove(at: from)
        let insertAt = moveJobs.firstIndex(where: { $0.status == .queued }) ?? moveJobs.count
        moveJobs.insert(job, at: insertAt)
        persistMoveJobs()
    }

    /// Remove a finished/failed row from the history.
    func dismissMove(_ id: UUID) {
        guard let idx = moveJobs.firstIndex(where: { $0.id == id }), !moveJobs[idx].isActive else { return }
        moveJobs.remove(at: idx)
        persistMoveJobs()
    }

    /// Remove every completed row at once — the "Clear" action in the queue manager, same as a
    /// browser download manager's "clear completed." Leaves queued/moving/failed rows untouched.
    func clearCompletedMoves() {
        guard moveJobs.contains(where: { $0.isCompleted }) else { return }
        moveJobs.removeAll { $0.isCompleted }
        persistMoveJobs()
    }

    /// Re-queue a failed job.
    func retryMove(_ id: UUID) {
        guard let idx = moveJobs.firstIndex(where: { $0.id == id }), case .failed = moveJobs[idx].status else { return }
        moveJobs[idx].status = .queued
        persistMoveJobs()
        startDrainingMovesIfNeeded()
    }

    /// On launch: re-queue any job interrupted mid-copy, sweep stray `.moving` partials under
    /// every known destination folder, drop successful history, and restart the drain loop.
    func resumePendingMoves() {
        let fm = FileManager.default
        var changed = false
        for i in moveJobs.indices {
            if case .moving = moveJobs[i].status {
                moveJobs[i].status = .queued
                changed = true
            }
        }
        for job in moveJobs where !job.isCompleted {
            let destFolder = URL(fileURLWithPath: job.destinationFolderPath)
            let tempURL = destFolder.appendingPathComponent("\(job.sourceFileName).moving")
            try? fm.removeItem(at: tempURL)
        }
        if changed { persistMoveJobs() }
        // Stale successful rows from prior sessions are history only — drop them.
        clearCompletedMoves()
        startDrainingMovesIfNeeded()
    }

    private var missingRefreshTask: Task<Void, Never>?

    func refreshMissingCount() async {
        if let inflight = missingRefreshTask {
            await inflight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefreshMissingCount()
        }
        missingRefreshTask = task
        await task.value
        if missingRefreshTask == task {
            missingRefreshTask = nil
        }
    }

    private func performRefreshMissingCount() async {
        guard !isRefreshingMissing else { return }
        isRefreshingMissing = true
        defer { isRefreshingMissing = false }
        let snapshot = videos
        let missIds = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            return Set(snapshot.filter { !fm.fileExists(atPath: $0.filePath) }.map(\.id))
        }.value
        missingVideoIds = missIds
        missingCountScanned = true
        UserDefaults.standard.set(true, forKey: Self.missingCountScannedKey)
        UserDefaults.standard.set(Array(missIds), forKey: Self.missingVideoIdsKey)
        libraryCounts = LibraryCounts(
            all: libraryCounts.all,
            recentlyAdded: libraryCounts.recentlyAdded,
            recentlyPlayed: libraryCounts.recentlyPlayed,
            topRated: libraryCounts.topRated,
            duplicates: libraryCounts.duplicates,
            corrupt: libraryCounts.corrupt,
            missing: missIds.count,
            recentlyConverted: libraryCounts.recentlyConverted,
            recentlyApplied: libraryCounts.recentlyApplied,
            lastAdded: libraryCounts.lastAdded,
            byRating: libraryCounts.byRating
        )
        recomputeFilteredVideos()
    }

    func clearFilmstripCacheAndMarkApplied() async {
        let rows = defaultFilmstripRows
        let cols = defaultFilmstripColumns
        // Epoch bump makes every prior on-disk/in-memory filmstrip a miss immediately.
        thumbnailService.invalidateAllFilmstrips()

        if let selectedId = focusedVideoId ?? lastSelectedVideoId ?? selectedVideoIds.first,
           let video = videos.first(where: { $0.filePath == selectedId })
        {
            _ = try? await thumbnailService.regenerateFilmstrip(
                for: video,
                rows: rows,
                columns: cols
            )
        }

        lastAppliedFilmstripRows = rows
        lastAppliedFilmstripColumns = cols
        UserDefaults.standard.set(lastAppliedFilmstripRows, forKey: Self.lastAppliedFilmstripRowsKey)
        UserDefaults.standard.set(lastAppliedFilmstripColumns, forKey: Self.lastAppliedFilmstripColumnsKey)
        filmstripRefreshId &+= 1
    }

    private func updateMissingAfterRemove(_ ids: Set<String>) {
        guard missingCountScanned, !ids.isEmpty else { return }
        missingVideoIds.subtract(ids)
        UserDefaults.standard.set(Array(missingVideoIds), forKey: Self.missingVideoIdsKey)
        libraryCounts = LibraryCounts(
            all: libraryCounts.all,
            recentlyAdded: libraryCounts.recentlyAdded,
            recentlyPlayed: libraryCounts.recentlyPlayed,
            topRated: libraryCounts.topRated,
            duplicates: libraryCounts.duplicates,
            corrupt: libraryCounts.corrupt,
            missing: missingVideoIds.count,
            recentlyConverted: libraryCounts.recentlyConverted,
            recentlyApplied: libraryCounts.recentlyApplied,
            lastAdded: libraryCounts.lastAdded,
            byRating: libraryCounts.byRating
        )
        recomputeFilteredVideos()
    }

    func deleteVideos(_ ids: Set<String>) async {
        let orderedIds = filteredVideos.map(\.id)
        let targets = videos.filter { ids.contains($0.filePath) }
        isDeleting = true
        deleteKindLabel = "Deleting"
        deleteTotal = targets.count
        deleteCurrent = 0
        defer {
            isDeleting = false
            deleteCurrent = 0
            deleteTotal = 0
        }
        for video in targets {
            try? await videoRepo.delete(video)
            var resultingURL: NSURL?
            try? FileManager.default.trashItem(at: video.url, resultingItemURL: &resultingURL)
            deleteCurrent += 1
        }
        selectedVideoIds.subtract(ids)
        applySelectionAfterDeletionIfNeeded(orderedIdsBeforeDeletion: orderedIds, removedIds: ids)
        updateMissingAfterRemove(ids)
    }

    func removeVideosFromLibrary(_ ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        let orderedIds = filteredVideos.map(\.id)
        stopObserving()
        let targets = videos.filter { ids.contains($0.filePath) }
        isDeleting = true
        deleteKindLabel = "Removing"
        deleteTotal = targets.count
        deleteCurrent = 0
        defer {
            isDeleting = false
            deleteCurrent = 0
            deleteTotal = 0
        }
        for video in targets {
            try? await videoRepo.delete(video)
            deleteCurrent += 1
        }
        selectedVideoIds.subtract(ids)
        applySelectionAfterDeletionIfNeeded(orderedIdsBeforeDeletion: orderedIds, removedIds: ids)
        updateMissingAfterRemove(ids)
        await refreshAfterScan()
    }

    /// When deletion clears the selection, select the next row in the pre-deletion list order (or the previous if the last row was removed). List and grid both use `filteredVideos` order.
    private func applySelectionAfterDeletionIfNeeded(orderedIdsBeforeDeletion ordered: [String], removedIds: Set<String>) {
        guard selectedVideoIds.isEmpty, !removedIds.isEmpty else { return }
        guard let next = Self.successorIdAfterRemoving(fromOrderedIds: ordered, removedIds: removedIds) else { return }
        selectedVideoIds = [next]
        lastSelectedVideoId = next
        focusedVideoId = next
        scrollToVideoId = next
    }

    private static func successorIdAfterRemoving(fromOrderedIds ordered: [String], removedIds: Set<String>) -> String? {
        guard !ordered.isEmpty, !removedIds.isEmpty else { return nil }
        guard let firstRemovedIdx = ordered.firstIndex(where: { removedIds.contains($0) }) else { return nil }
        if let after = ordered[(firstRemovedIdx + 1)...].first(where: { !removedIds.contains($0) }) {
            return after
        }
        if let before = ordered[..<firstRemovedIdx].last(where: { !removedIds.contains($0) }) {
            return before
        }
        return nil
    }

    // MARK: - Video bookmarks

    /// Reload bookmarks for the single selected video (clears list when multi/none/no DB id).
    func reloadBookmarksForSelection() async {
        let ids = inspectorActionIds
        guard ids.count == 1,
              let path = ids.first,
              let video = video(forPath: path),
              let videoId = video.databaseId else {
            bookmarksForSelection = []
            notifyBookmarksChanged()
            return
        }
        bookmarksForSelection = (try? await bookmarkRepo.fetch(forVideoId: videoId)) ?? []
        notifyBookmarksChanged()
    }

    /// Timeline ticks follow the playing video, not merely the Inspector selection.
    func reloadBookmarksForPlayback(video: Video?) async {
        guard let video, let videoId = video.databaseId else {
            bookmarksForPlayback = []
            notifyBookmarksChanged()
            return
        }
        bookmarksForPlayback = (try? await bookmarkRepo.fetch(forVideoId: videoId)) ?? []
        notifyBookmarksChanged()
    }

    /// Insert a bookmark at `seconds`, capture a still, refresh the Inspector list when relevant.
    /// Default title is the timecode; rename inline in the Inspector.
    @discardableResult
    func addBookmark(for video: Video, atSeconds seconds: Double, title: String? = nil) async -> VideoBookmark? {
        guard let videoId = video.databaseId else { return nil }
        let clamped = max(0, seconds)
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmed.isEmpty ? clamped.formattedDuration : trimmed
        var bookmark = VideoBookmark(
            id: nil,
            videoId: videoId,
            seconds: clamped,
            title: resolvedTitle,
            thumbnailPath: nil,
            dateCreated: Date()
        )
        do {
            bookmark = try await bookmarkRepo.insert(bookmark)
            guard let bookmarkId = bookmark.id else { return bookmark }
            if let stillURL = try? await thumbnailService.captureBookmarkStill(
                for: video, atSeconds: clamped, videoId: videoId, bookmarkId: bookmarkId
            ) {
                try? await bookmarkRepo.updateThumbnailPath(id: bookmarkId, path: stillURL.path)
                bookmark.thumbnailPath = stillURL.path
            }
            pendingBookmarkTitleFocusId = bookmarkId
            if inspectorActionIds == [video.filePath] {
                await reloadBookmarksForSelection()
            }
            if playback.currentVideo?.filePath == video.filePath {
                await reloadBookmarksForPlayback(video: video)
            } else if inspectorActionIds != [video.filePath] {
                notifyBookmarksChanged()
            }
            return bookmark
        } catch {
            return nil
        }
    }

    func renameBookmark(_ bookmark: VideoBookmark, title: String) async {
        guard let id = bookmark.id else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmed.isEmpty ? bookmark.seconds.formattedDuration : trimmed
        try? await bookmarkRepo.updateTitle(id: id, title: newTitle)
        await reloadBookmarksForSelection()
        if playback.currentVideo?.databaseId == bookmark.videoId {
            await reloadBookmarksForPlayback(video: playback.currentVideo)
        }
    }

    func deleteBookmark(_ bookmark: VideoBookmark) async {
        if let id = bookmark.id {
            thumbnailService.deleteBookmarkStill(videoId: bookmark.videoId, bookmarkId: id)
        }
        thumbnailService.deleteBookmarkStill(at: bookmark.thumbnailPath)
        try? await bookmarkRepo.delete(bookmark)
        await reloadBookmarksForSelection()
        if playback.currentVideo?.databaseId == bookmark.videoId {
            await reloadBookmarksForPlayback(video: playback.currentVideo)
        }
    }

    /// Jump to a bookmark: seek live player if already playing this video, otherwise start at that time.
    func jumpToBookmark(_ bookmark: VideoBookmark) {
        guard let video = videos.first(where: { $0.databaseId == bookmark.videoId })
                ?? bookmarksSelectionVideoMatching(bookmark) else { return }

        if isPlayingInline, playback.currentVideo?.filePath == video.filePath {
            playback.rememberReturnPointBeforeJump(to: bookmark.seconds)
            playback.seek(toSeconds: bookmark.seconds)
            return
        }

        if selectedVideoIds != [video.filePath] {
            selectedVideoIds = [video.filePath]
        }
        pendingFilmstripSeekSeconds = bookmark.seconds
        pendingIgnoreResumeOnNextStart = true
        if isPlayingInline {
            // Restart at the bookmark time (stop persists resume; then start with seek).
            isPlayingInline = false
            DispatchQueue.main.async { [weak self] in
                self?.pendingFilmstripSeekSeconds = bookmark.seconds
                self?.pendingIgnoreResumeOnNextStart = true
                self?.isPlayingInline = true
            }
        } else {
            isPlayingInline = true
        }
    }

    private func bookmarksSelectionVideoMatching(_ bookmark: VideoBookmark) -> Video? {
        guard selectedVideoIds.count == 1,
              let path = selectedVideoIds.first,
              let video = video(forPath: path),
              video.databaseId == bookmark.videoId else { return nil }
        return video
    }

    /// Bumps play count / last-played without reloading the library. A naive DB write would fire
    /// `ValueObservation` → `videos = fetchAll` → O(n) filter/counts cascade and freeze playback
    /// for several seconds on large libraries (first frame stuck while the main actor is busy).
    func recordPlay(for video: Video) async {
        guard let id = video.databaseId else { return }
        guard let idx = videoIndexByPath[video.filePath] else {
            try? await videoRepo.recordPlay(videoId: id)
            return
        }

        let now = Date()
        suppressVideosDidSet = true
        var updated = videos
        updated[idx].playCount += 1
        updated[idx].lastPlayed = now
        videos = updated
        videosByPath[video.filePath] = updated[idx]
        // Keep the filtered row in sync when present (no membership change → no version bump).
        if let fIdx = filteredIndexByPath[video.filePath], fIdx < filteredVideos.count {
            var filtered = filteredVideos
            filtered[fIdx].playCount = updated[idx].playCount
            filtered[fIdx].lastPlayed = now
            filteredVideos = filtered
        }
        suppressVideosDidSet = false

        discardObservationDeliveries += 1
        try? await videoRepo.recordPlay(videoId: id)
    }

    func createTag(_ name: String) async {
        do {
            _ = try await tagRepo.findOrCreate(name: name)
            await reloadTagState()
        } catch {
            print("Failed to create tag: \(error)")
            reportTransientError("Couldn't create tag \"\(name)\"")
        }
    }

    func addTag(_ name: String, to video: Video) async {
        guard let videoId = video.databaseId else { return }
        do {
            let tag = try await tagRepo.findOrCreate(name: name)
            if let tagId = tag.id {
                try await tagRepo.addTag(tagId, to: videoId)
                await reloadTagState()
            }
        } catch {
            print("Failed to add tag: \(error)")
            reportTransientError("Couldn't add tag \"\(name)\"")
        }
    }

    func addTag(_ name: String, toVideos videoIds: Set<String>) async {
        do {
            let tag = try await tagRepo.findOrCreate(name: name)
            guard let tagId = tag.id else { return }
            let dbIds = videos.filter { videoIds.contains($0.filePath) }.compactMap(\.databaseId)
            for dbId in dbIds {
                try? await tagRepo.addTag(tagId, to: dbId)
            }
            await reloadTagState()
        } catch {
            print("Failed to add tag: \(error)")
            reportTransientError("Couldn't add tag \"\(name)\"")
        }
    }

    func removeTag(_ tag: Tag, from video: Video) async {
        guard let videoId = video.databaseId, let tagId = tag.id else { return }
        do {
            try await tagRepo.removeTag(tagId, from: videoId)
            await reloadTagState()
        } catch {
            print("Failed to remove tag: \(error)")
            reportTransientError("Couldn't remove tag \"\(tag.name)\"")
        }
    }

    func removeTag(_ tag: Tag, fromVideos videoIds: Set<String>) async {
        guard let tagId = tag.id else { return }
        let dbIds = videos.filter { videoIds.contains($0.filePath) }.compactMap(\.databaseId)
        for dbId in dbIds {
            try? await tagRepo.removeTag(tagId, from: dbId)
        }
        await reloadTagState()
    }

    func renameTag(_ tag: Tag, to newName: String) async {
        guard let tagId = tag.id, !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await tagRepo.rename(tagId, to: newName)
            await loadTags()
            await refreshTagsByVideoId()
            refreshSearchIfActive()
        } catch {
            print("Failed to rename tag: \(error)")
            reportTransientError("Couldn't rename tag \"\(tag.name)\"")
        }
    }

    func clearTagFilters() {
        selectedTagIds = []
    }

    /// True when the filter strip’s per-star rating filter is active.
    var isRatingFilterActive: Bool {
        !selectedRatingStars.isEmpty
    }

    /// True if the active filter stack (Quick or Advanced tab) has a non-default filter applied.
    /// Used for the header Filter icon and the closed-drawer pills row.
    var hasActiveFilters: Bool {
        switch filtersDrawerMode {
        case .quick:
            if case .collection = sidebarFilter { return true }
            if sidebarFilter != nil && sidebarFilter != .all { return true }
            if !selectedTagIds.isEmpty { return true }
            if !selectedRatingStars.isEmpty { return true }
            if minDurationSeconds != nil || maxDurationSeconds != nil { return true }
            if !selectedQualityBuckets.isEmpty { return true }
            return false
        case .advanced:
            return hasActiveAdvancedFilter
        }
    }

    /// Clears the per-star rating filter (filter strip → Rating).
    func clearRatingFilter() {
        ratingFilterOrHigher = false
        selectedRatingStars = []
    }

    func clearDurationFilter() {
        minDurationSeconds = nil
        maxDurationSeconds = nil
    }

    func clearQualityFilter() {
        selectedQualityBuckets = []
    }

    /// Clears Quick Filter stack without resetting sidebar / smart-library selection.
    func clearFilters() {
        clearTagFilters()
        clearRatingFilter()
        clearDurationFilter()
        clearQualityFilter()
        resetAdvancedFilterEditorSession()
        // Note: we intentionally do not reset sidebarFilter here; caller can do if desired.
    }

    /// Resets all filters (sidebar to All, tags, rating, duration, quality, Advanced). Useful for "Clear all" in drawer.
    func resetAllFilters() {
        sidebarFilter = .all
        selectedTagIds = []
        clearRatingFilter()
        minDurationSeconds = nil
        maxDurationSeconds = nil
        selectedQualityBuckets = []
        collectionFilterPreview = nil
        resetAdvancedFilterEditorSession()
    }

    func deleteTag(_ tag: Tag) async {
        guard let tagId = tag.id else { return }
        selectedTagIds.remove(tagId)
        do {
            try await tagRepo.delete(tagId)
            await reloadTagState()
        } catch {
            print("Failed to delete tag: \(error)")
            reportTransientError("Couldn't delete tag \"\(tag.name)\"")
        }
    }

    private func reloadTagState() async {
        await loadTags()
        await refreshTagsByVideoId()
        refreshSearchIfActive()
    }

    /// Tags common to every video in the selection. Iterates the selection only (O(selection)),
    /// resolving each path via `videosByPath` and intersecting `tagsByVideoId`. The old full-library
    /// scan was O(library) on every Inspector render — multi-second stalls at ~12k videos.
    func tagsForVideos(_ videoIds: Set<String>) -> [Tag] {
        guard !videoIds.isEmpty else { return [] }
        var commonTagIds: Set<Int64>?
        for path in videoIds {
            guard let video = videosByPath[path], let dbId = video.databaseId else { continue }
            let videoTagIds = Set((tagsByVideoId[dbId] ?? []).compactMap(\.id))
            if commonTagIds == nil {
                commonTagIds = videoTagIds
            } else {
                commonTagIds!.formIntersection(videoTagIds)
            }
            if commonTagIds!.isEmpty { break }
        }
        guard let common = commonTagIds, !common.isEmpty else { return [] }
        return tags.filter { common.contains($0.id ?? -1) }
    }

    func tagsForVideo(_ video: Video) async -> [Tag] {
        guard let videoId = video.databaseId else { return [] }
        return (try? await tagRepo.fetchTags(for: videoId)) ?? []
    }

    private func loadTags() async {
        tags = (try? await tagRepo.fetchAll()) ?? []
    }

    // MARK: - Collections

    /// Albums only (manual membership), sorted with the full collections list.
    var albums: [VideoCollection] {
        collections.filter(\.isAlbum)
    }

    func loadCollections() async {
        collections = (try? await collectionRepo.fetchAll()) ?? []
        cachedCollectionRules = (try? await collectionRepo.fetchAllRulesGrouped()) ?? [:]
        cachedCollectionRuleGroups = (try? await collectionRepo.fetchAllRuleGroupsGrouped()) ?? [:]
        cachedAlbumVideoIds = (try? await collectionRepo.fetchAllAlbumMemberships()) ?? [:]
        await refreshTagsByVideoId()
        await refreshCollectionCounts()
        recomputeFilteredVideos()
    }

    private func scheduleCollectionCountRefresh() {
        collectionCountTask?.cancel()
        collectionCountTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await refreshCollectionCounts()
        }
    }

    func refreshCollectionCounts() async {
        // Snapshot main-actor state, then compute the O(videos × collections × rules) loop off the main
        // actor — it was a ~180ms main-thread stall at 12k. Result is assigned back on the main actor.
        let baseVideos = excludeCorrupt ? videos.filter { !Self.isCorrupt($0, thumbnailsSettled: thumbnailsSettled) } : videos
        let currentTags = tagsByVideoId
        let allRules = cachedCollectionRules
        let allGroups = cachedCollectionRuleGroups
        let albumMembers = cachedAlbumVideoIds
        let cols = collections
        let repo = collectionRepo
        let customValuesById = listCustomMetadataByVideoId
        let customFields = Dictionary(uniqueKeysWithValues: customMetadataFieldDefinitions.map { ($0.id, $0) })
        let libraryContext = currentLibraryFilterContext()

        let counts = await Task.detached(priority: .utility) {
            var counts: [Int64: Int] = [:]
            for collection in cols {
                guard let id = collection.id else { continue }
                if collection.kind == .album {
                    let members = Set(albumMembers[id] ?? [])
                    counts[id] = baseVideos.filter { video in
                        guard let dbId = video.databaseId else { return false }
                        return members.contains(dbId)
                    }.count
                    continue
                }
                let groups = allGroups[id] ?? []
                if groups.isEmpty {
                    counts[id] = 0
                    continue
                }
                let rulesByGroup = Dictionary(grouping: allRules[id] ?? [], by: \.groupId)
                let matcher = repo.compileMatcher(
                    for: collection,
                    groups: groups,
                    rulesByGroup: rulesByGroup,
                    customFields: customFields,
                    libraryContext: libraryContext,
                    collectionRepo: repo
                )
                counts[id] = baseVideos.filter { video in
                    let dbId = video.databaseId
                    return matcher.matches(
                        video,
                        tags: currentTags[dbId ?? -1] ?? [],
                        customValues: dbId.flatMap { customValuesById[$0] } ?? [:]
                    )
                }.count
            }
            return counts
        }.value

        collectionCounts = counts
    }

    func deleteCollection(_ collection: VideoCollection) async {
        try? await collectionRepo.delete(collection)
        if case .collection(let selected) = sidebarFilter, selected == collection {
            sidebarFilter = .all
        }
        await loadCollections()
    }

    /// Creates an Album from the given video paths (selection), selects it in the sidebar.
    @discardableResult
    func createAlbum(name: String, fromVideoPaths paths: Set<String>) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Preserve the current view order so "New Album from Selection" becomes a playlist.
        var dbIds = filteredVideos.filter { paths.contains($0.id) }.compactMap(\.databaseId)
        if dbIds.isEmpty {
            dbIds = paths.compactMap { videosByPath[$0]?.databaseId }
        }
        guard !dbIds.isEmpty else { return false }

        let album = VideoCollection(name: trimmed, dateCreated: Date(), matchMode: .all, kind: .album)
        guard let saved = try? await collectionRepo.insert(album), let id = saved.id else { return false }
        try? await collectionRepo.replaceAlbumMembership(for: id, videoIds: dbIds)
        await loadCollections()
        if let refreshed = collections.first(where: { $0.id == id }) {
            sidebarFilter = .collection(refreshed)
        }
        return true
    }

    /// Creates an empty Album (drawer affordance).
    @discardableResult
    func createEmptyAlbum(name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let album = VideoCollection(name: trimmed, dateCreated: Date(), matchMode: .all, kind: .album)
        guard let saved = try? await collectionRepo.insert(album), let id = saved.id else { return false }
        await loadCollections()
        if let refreshed = collections.first(where: { $0.id == id }) {
            sidebarFilter = .collection(refreshed)
        }
        return true
    }

    func addVideos(paths: Set<String>, toAlbum album: VideoCollection) async {
        guard album.isAlbum, let albumId = album.id else { return }
        var dbIds = filteredVideos.filter { paths.contains($0.id) }.compactMap(\.databaseId)
        if dbIds.count != paths.count {
            let seen = Set(dbIds)
            for path in paths {
                if let dbId = videosByPath[path]?.databaseId, !seen.contains(dbId) {
                    dbIds.append(dbId)
                }
            }
        }
        guard !dbIds.isEmpty else { return }
        try? await collectionRepo.addVideos(dbIds, toAlbum: albumId)
        await loadCollections()
    }

    func removeVideos(paths: Set<String>, fromAlbum album: VideoCollection) async {
        guard album.isAlbum, let albumId = album.id else { return }
        let dbIds = paths.compactMap { videosByPath[$0]?.databaseId }
        guard !dbIds.isEmpty else { return }
        try? await collectionRepo.removeVideos(dbIds, fromAlbum: albumId)
        await loadCollections()
    }

    /// Drag-and-drop playlist reorder: move the dragged video (or the whole selection if it includes
    /// the dragged video) so they sit immediately before `ontoPathId` in the album.
    func reorderAlbumDrop(draggingPathId: String, ontoPathId: String) async {
        guard let album = activeAlbum, let albumId = album.id else { return }
        let movingPaths: [String]
        if selectedVideoIds.contains(draggingPathId) {
            movingPaths = filteredVideos.filter { selectedVideoIds.contains($0.id) }.map(\.id)
        } else {
            movingPaths = [draggingPathId]
        }
        let movingDb = movingPaths.compactMap { videosByPath[$0]?.databaseId }
        guard let targetDb = videosByPath[ontoPathId]?.databaseId else { return }
        let current = cachedAlbumVideoIds[albumId] ?? []
        guard let newOrder = AlbumPlaylistOrder.moving(movingDb, onto: targetDb, in: current) else { return }
        try? await collectionRepo.replaceAlbumOrder(for: albumId, videoIds: newOrder)
        cachedAlbumVideoIds[albumId] = newOrder
        usesAlbumManualOrder = true
        isRandomOrder = false
        recomputeFilteredVideos()
    }

    /// Called when the current item finishes. Auto-advance and loop only run during a Play All session.
    func advancePlayAllIfNeeded() {
        guard isPlayAllSession else { return }
        let currentPath = playback.currentVideo?.filePath
            ?? focusedVideoId
            ?? lastSelectedVideoId
            ?? selectedVideoIds.first
        guard let currentPath else { return }
        let idx = filteredIndexByPath[currentPath]
            ?? filteredVideos.firstIndex(where: { $0.id == currentPath })
        guard let idx else { return }

        let paths = filteredVideos.map(\.filePath)
        guard let nextIdx = PlayAllAdvance.nextIndex(
            after: idx,
            paths: paths,
            loop: playAllLoops,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        ) else {
            isPlayAllSession = false
            return
        }
        playQueueSuccessor(filteredVideos[nextIdx])
    }

    private func retargetPlayback(to video: Video) {
        isAdvancingPlayAllQueue = true
        pendingFilmstripSeekSeconds = nil
        pendingIgnoreResumeOnNextStart = true
        focusedVideoId = video.id
        lastSelectedVideoId = video.id
        playback.start(video: video, at: 0, ignoreResume: true)
        DispatchQueue.main.async { [weak self] in
            self?.isAdvancingPlayAllQueue = false
        }
    }

    private func playQueueSuccessor(_ video: Video) {
        retargetPlayback(to: video)
    }

    func renameCollection(_ collection: VideoCollection, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = collection
        updated.name = trimmed
        try? await collectionRepo.update(updated)
        if case .collection(let selected) = sidebarFilter, selected.id == collection.id {
            sidebarFilter = .collection(updated)
        }
        await loadCollections()
    }

    /// Phase 4 bridge: persist the live advanced `FilterGroup` as a named Collection.
    /// Returns `false` if there is nothing to save or the name is blank.
    @discardableResult
    func saveAdvancedFilterAsCollection(name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let group = advancedFilterGroup, !group.isEmpty else { return false }
        let inputs = Self.ruleGroupInputs(from: group)
        guard !inputs.isEmpty else { return false }

        let collection = VideoCollection(name: trimmed, dateCreated: Date(), matchMode: group.mode, kind: .smart)
        do {
            _ = try await collectionRepo.saveSmartCollection(collection, groups: inputs)
            await loadCollections()
            return true
        } catch {
            return false
        }
    }

    /// Opens a smart collection's rules in the Advanced Filter drawer from the closed-drawer pill.
    /// Quick filter state (including the selected collection) is preserved so tab toggles stay in sync.
    /// Closing without edits restores the collection Quick Filter pill; edits keep Advanced Filter active.
    func previewCollectionInAdvancedFilter(_ collection: VideoCollection) {
        guard ensureAdvancedFilterCompiledFromQuick(fallbackCollection: collection) else { return }

        filtersDrawerMode = .advanced
        if case .collection = sidebarFilter,
           let group = advancedFilterGroup, !group.isEmpty {
            collectionFilterPreview = (collection, group)
        }
        isCuratedWallFiltersDrawerOpen = true
    }

    /// Phase 4 bridge: load a Collection's rule tree into the live Advanced Filter and open the
    /// drawer (exclusive mode — clears Quick Filter). Albums have no rules — no-op.
    func editCollectionAsAdvancedFilter(_ collection: VideoCollection) {
        guard let group = filterGroup(for: collection), !group.isEmpty else { return }

        collectionFilterPreview = nil
        clearQuickFilters()
        // Don't leave the sidebar stuck on this collection — Advanced Filter now owns matching.
        if case .collection(let selected) = sidebarFilter, selected.id == collection.id {
            sidebarFilter = .all
        }
        filtersDrawerMode = .advanced
        loadAdvancedFilterEditorSession(group)
        isCuratedWallFiltersDrawerOpen = true
    }

    @discardableResult
    private func compileQuickFiltersIntoAdvanced() -> Bool {
        let input = QuickFilterCompiler.Input(
            sidebarFilter: sidebarFilter,
            collectionGroup: quickFilterCollectionGroup(),
            tags: tags,
            selectedTagIds: selectedTagIds,
            tagFilterMode: tagFilterMode,
            selectedRatingStars: selectedRatingStars,
            ratingFilterOrHigher: ratingFilterOrHigher,
            minDurationSeconds: minDurationSeconds,
            maxDurationSeconds: maxDurationSeconds,
            selectedQualityBuckets: selectedQualityBuckets,
            topRatedMinRating: topRatedMinRating
        )
        guard let group = QuickFilterCompiler.compile(input), !group.isEmpty else { return false }
        loadAdvancedFilterEditorSession(group)
        return true
    }

    @discardableResult
    private func ensureAdvancedFilterCompiledFromQuick(fallbackCollection: VideoCollection? = nil) -> Bool {
        if compileQuickFiltersIntoAdvanced() { return true }
        if let collection = fallbackCollection,
           let group = filterGroup(for: collection), !group.isEmpty {
            loadAdvancedFilterEditorSession(group)
            return true
        }
        if let group = advancedFilterGroup, !group.isEmpty { return true }
        return false
    }

    private func quickFilterCollectionGroup() -> FilterGroup? {
        guard case .collection(let collection) = sidebarFilter, collection.isSmart else { return nil }
        return filterGroup(for: collection)
    }

    private func restoreCollectionFilterPreviewIfUnchanged() {
        guard let preview = collectionFilterPreview else { return }
        collectionFilterPreview = nil

        guard advancedFilterGroup == preview.snapshot else { return }

        filtersDrawerMode = .quick
        sidebarFilter = .collection(resolvedCollection(for: preview.collection))
        resetAdvancedFilterEditorSession()
    }

    private func beginAdvancedFilterEditorSession() {
        advancedFilterEditorSessionID = UUID()
    }

    private func loadAdvancedFilterEditorSession(_ group: FilterGroup) {
        beginAdvancedFilterEditorSession()
        advancedFilterGroup = group
    }

    private func resetAdvancedFilterEditorSession() {
        beginAdvancedFilterEditorSession()
        advancedFilterGroup = nil
    }

    private func resolvedCollection(for collection: VideoCollection) -> VideoCollection {
        guard let id = collection.id,
              let refreshed = collections.first(where: { $0.id == id }) else {
            return collection
        }
        return refreshed
    }

    /// Maps a working `FilterGroup` onto the two-level shape `replaceRuleGroups` expects.
    /// Top-level conditions (no nesting) are wrapped in a single ALL group.
    private static func ruleGroupInputs(
        from group: FilterGroup
    ) -> [(mode: MatchMode, rules: [CollectionRule])] {
        var inputs: [(mode: MatchMode, rules: [CollectionRule])] = []
        var looseConditions: [CollectionRule] = []

        for node in group.nodes {
            switch node {
            case .group(let inner):
                let rules: [CollectionRule] = inner.nodes.compactMap { child in
                    guard case .condition(let c) = child else { return nil }
                    return CollectionRule(
                        collectionId: 0,
                        groupId: 0,
                        attribute: c.field,
                        comparison: c.comparison,
                        value: c.value,
                        value2: c.value2
                    )
                }
                if !rules.isEmpty {
                    inputs.append((mode: inner.mode, rules: rules))
                }
            case .condition(let c):
                looseConditions.append(CollectionRule(
                    collectionId: 0,
                    groupId: 0,
                    attribute: c.field,
                    comparison: c.comparison,
                    value: c.value,
                    value2: c.value2
                ))
            }
        }

        if !looseConditions.isEmpty {
            inputs.insert((mode: .all, rules: looseConditions), at: 0)
        }
        return inputs
    }

    private func refreshTagsByVideoId() async {
        tagsByVideoId = (try? await tagRepo.fetchAllVideoTags()) ?? [:]
    }

    private func startThumbnailSettlingTask() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.thumbnailService.hasPendingThumbnails {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !self.thumbnailsSettled else { return }
            self.thumbnailsSettled = true
            self.recomputeFilteredVideos()
            self.updateLibraryCounts()
        }
    }

    private func refreshAfterScan() async {
        videos = (try? await videoRepo.fetchAll()) ?? []
        await loadTags()
        await refreshTagsByVideoId()
        await refreshCollectionCounts()
        startObserving()
    }
}

/// Thread-safe counter for Relink thumb-migration progress (updated off the main actor).
private final class RelinkThumbProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func set(_ newValue: Int) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
