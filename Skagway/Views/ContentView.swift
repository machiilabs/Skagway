import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if !DatabaseExportImport.hasCompletedLibraryHomeSetup {
            LibraryHomeSetupView()
                .frame(minWidth: 900, minHeight: 600)
                .appDesignSystem()
        } else if !appState.hasLibrary {
            LandingView()
                .frame(minWidth: 900, minHeight: 600)
                .appDesignSystem()
        } else if let vm = appState.libraryViewModel {
            LibraryContentView(vm: vm, thumbService: appState.thumbnailService)
                .appDesignSystem()   // Injects Skagway design tokens + theme
        }
    }
}

private struct LibraryContentView: View {
    /// Required so `browsingLayout` changes invalidate `NSViewRepresentable` and apply saved split positions.
    @Bindable var vm: LibraryViewModel
    let thumbService: ThumbnailService
    /// Persists across content host rootView replacements (playback/browsing switch, layout changes).
    @State private var listScrollPositionRow: Int?
    /// Must remove when the view goes away; repeated `onAppear` without removal stacks monitors and breaks handling.
    @State private var keyDownMonitor: Any?
    @State private var fullScreenController: FullscreenInlinePlayerWindowController?
    @State private var showConversionQueue = false
    @State private var showMoveQueue = false
    /// Highlights the empty-library drop zone while a drag is over the browser split.
    @State private var isBrowserDropTargeted = false
    @FocusState private var isSearchFocused: Bool

    /// Local presentation flag for the filters drawer (discrete).
    @State private var isFiltersDrawerOpen = false

    /// Interpolated 0...1 value that drives smooth height/offset animations for the drawer well.
    /// Using a CGFloat animated via withAnimation gives the view modifiers interpolated values
    /// each frame, so the drawer grows its height gradually instead of appearing full-size instantly,
    /// and the grid/list below is pushed at a matching rate.
    @State private var drawerReveal: CGFloat = 0
    /// Captured once at the start of a drawer-resize drag so `DragGesture`'s cumulative
    /// `translation` can be applied against a stable baseline instead of the live (already
    /// mutating) height.
    @State private var filtersDrawerDragStartHeight: CGFloat?
    /// Live height while actively dragging the resize handle. Kept local (not written to
    /// `vm.filtersDrawerHeight`) until the drag ends — writing the `@Observable`/persisted
    /// property on every drag delta caused a visible flicker (UserDefaults I/O plus broader
    /// view invalidation on every pixel of movement). `vm.filtersDrawerHeight` is only updated
    /// once, in `onEnded`.
    @State private var filtersDrawerLiveHeight: CGFloat?
    /// The drawer's natural content height (header + cards), reported by `CuratedWallFiltersDrawer`.
    /// Caps how tall the drawer can be dragged — growing past its content would just add a dead
    /// scroll region. `nil` until first measured.
    @State private var filtersDrawerContentHeight: CGFloat?

    /// Inspector target: focused clip while reviewing, collected set once you finish.
    private var selectedVideo: Video? {
        guard let id = vm.reviewVideoId else { return nil }
        return vm.filteredVideo(forPath: id)
    }

    /// Player always follows review focus, even when Inspector is in set mode.
    private var focusedVideo: Video? {
        guard let id = vm.focusedVideoId ?? vm.lastSelectedVideoId ?? vm.selectedVideoIds.first else { return nil }
        return vm.filteredVideo(forPath: id)
    }

    private var navigationTitle: String {
        let name = DatabaseExportImport.activeLibraryDisplayName
        // Default library basename is Skagway (file Skagway.machii).
        if name.isEmpty || name == "Skagway" { return "Skagway" }
        return "Skagway — \(name)"
    }

    private var detailID: String {
        vm.reviewVideoId ?? ""
    }


    /// Column targets for the split view always follow browsing layout so toggling playback
    /// does not change effective widths (avoids a layout pulse / grid jump before freeze).
    private var browsingSplitContentWidth: CGFloat {
        CGFloat(vm.browsingLayout.contentColumnWidth(for: vm.viewMode))
    }
    private var browsingSplitDetailWidth: CGFloat {
        CGFloat(vm.browsingLayout.detailColumnWidth(for: vm.viewMode))
    }
    private var browsingSplitTopPaneHeight: CGFloat {
        CGFloat(vm.browsingLayout.browserTopPaneHeight(for: vm.viewMode))
    }

    /// Duration for the Curated Wall top filters drawer slide animation (open and close).
    /// A deliberate, visible slide — was previously too fast at 0.22s.
    private static let drawerAnimationDuration: Double = 0.38

    /// Reusable styled search field (cinematic blue focus ring, clear affordance).
    /// Used both in the regular nav bar and inline in the Curated Wall thin header.
    private var searchField: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.appTextTertiary)
                .font(.callout)
            TextField("Search videos", text: $vm.searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(Color.appTextPrimary)
                .tint(Color.appAccent)
                .focused($isSearchFocused)
                .help("Search videos (⌘F)")
            if !vm.searchText.isEmpty {
                Button {
                    vm.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.appTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, 4)
        .background(Color.appSurface.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .stroke(isSearchFocused ? Color.appAccent.opacity(0.55) : Color.appAccent.opacity(0.18), lineWidth: isSearchFocused ? 1.5 : 1)
        )
        .frame(minWidth: 160, idealWidth: 220)
    }

    /// Idle header count (busy progress lives in the bottom activity strip).
    private var headerStatusText: String {
        "\(vm.filteredVideos.count) videos"
    }

    private var isConversionActive: Bool {
        vm.conversionJobs.contains { $0.isActive }
    }

    private var hasConversionFailure: Bool {
        !isConversionActive && vm.conversionJobs.contains { if case .failed = $0.status { return true }; return false }
    }

    /// Busy conversion work is shown in the activity strip; header keeps icon-only access to
    /// history (including completed jobs with kept backups) when the strip is not already showing re-encode.
    private var showsHeaderConversionIconOnly: Bool {
        vm.hasConversionActivity
            && vm.activityStripState.primary?.kind != .reencoding
            && !vm.activityStripState.secondaries.contains(where: { $0.kind == .reencoding })
    }

    private var conversionPill: some View {
        Button {
            showConversionQueue = true
        } label: {
            Image(systemName: hasConversionFailure ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hasConversionFailure ? .white : Color.appTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(
                        hasConversionFailure ? Color.red.opacity(0.75) : Color.appAccent.opacity(0.08)
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
        .help("Re-encode queue — click to manage")
    }

    private var isMoveActive: Bool {
        vm.moveJobs.contains { $0.isActive }
    }

    private var hasMoveFailure: Bool {
        !isMoveActive && vm.moveJobs.contains { if case .failed = $0.status { return true }; return false }
    }

    private var showsHeaderMoveIconOnly: Bool {
        vm.hasMoveActivity
            && vm.activityStripState.primary?.kind != .moving
            && !vm.activityStripState.secondaries.contains(where: { $0.kind == .moving })
    }

    /// Icon-only access to move history when the strip owns the busy text.
    private var movePill: some View {
        Button {
            showMoveQueue = true
        } label: {
            Image(systemName: hasMoveFailure ? "exclamationmark.triangle.fill" : "folder")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hasMoveFailure ? .white : Color.appTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(
                        hasMoveFailure ? Color.red.opacity(0.75) : Color.appAccent.opacity(0.08)
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
        .help("Move queue — click to manage")
    }

    private var sortCluster: some View {
        let isCustomSort = vm.customSortFieldId != nil
        let currentBuiltinSort = VideoSort.from(keyPath: vm.tableSortOrder.first?.keyPath ?? \Video.dateAdded)
        let currentCustomField = vm.customMetadataFieldDefinitions.first { $0.id == vm.customSortFieldId }
        let isAscending = isCustomSort ? vm.customSortAscending : (vm.tableSortOrder.first?.order == .forward)
        // While shuffled, none of the built-in/custom sorts are actually "active" — show Random
        // in the label and skip the checkmarks below rather than pointing at stale prior state.
        let sortLabel: String = {
            if vm.isRandomOrder { return "Random" }
            if vm.isShowingAlbumOrder { return "Album Order" }
            return currentCustomField?.name ?? currentBuiltinSort.displayName
        }()
        let sortableCustomFields = vm.customMetadataFieldDefinitions
            .filter { $0.valueType != .text }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return HStack(spacing: 4) {
            Menu {
                if vm.isViewingAlbum {
                    Button {
                        vm.selectAlbumOrder()
                    } label: {
                        if vm.isShowingAlbumOrder {
                            Label("Album Order", systemImage: "checkmark")
                        } else {
                            Text("Album Order")
                        }
                    }
                    Divider()
                }
                ForEach(VideoSort.allCases) { sort in
                    Button {
                        vm.selectBuiltinSort(sort, ascending: isAscending)
                    } label: {
                        if !isCustomSort && !vm.isRandomOrder && !vm.isShowingAlbumOrder && sort == currentBuiltinSort {
                            Label(sort.displayName, systemImage: "checkmark")
                        } else {
                            Text(sort.displayName)
                        }
                    }
                }
                if !sortableCustomFields.isEmpty {
                    Divider()
                    ForEach(sortableCustomFields) { field in
                        Button {
                            vm.selectCustomSort(fieldId: field.id, ascending: isAscending)
                        } label: {
                            if !vm.isRandomOrder && !vm.isShowingAlbumOrder && vm.customSortFieldId == field.id {
                                Label(field.name, systemImage: "checkmark")
                            } else {
                                Text(field.name)
                            }
                        }
                    }
                }
            } label: {
                Text("Sort: \(sortLabel)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appTextSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            // Ascending/descending has no meaning for a shuffled order or album playlist order.
            if !vm.isRandomOrder && !vm.isShowingAlbumOrder {
                Button {
                    if isCustomSort, let fieldId = vm.customSortFieldId {
                        vm.selectCustomSort(fieldId: fieldId, ascending: !isAscending)
                    } else {
                        vm.tableSortOrder = currentBuiltinSort.comparators(ascending: !isAscending)
                        vm.savePreferences()
                    }
                } label: {
                    Image(systemName: isAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.appTextSecondary)
                }
                .buttonStyle(.plain)
                .help(isAscending ? "Ascending — click for descending" : "Descending — click for ascending")
            }
        }
    }

    private var curatedHeaderBar: some View {
        HStack(spacing: 8) {
            // Library actions (left cluster).
            Button {
                Task { await vm.importNew() }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appTextSecondary)
            .disabled(vm.isScanning)
            .help("Scan for New Videos — scan your folders for newly added video files")

            Button {
                vm.surpriseMePickRandom()
            } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appTextSecondary)
            .disabled(vm.filteredVideos.isEmpty)
            .help("Surprise Me — pick a random video, auto-plays if enabled in Settings (⌘⇧S)")
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button {
                vm.shuffleOrder()
            } label: {
                Image(systemName: "shuffle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(vm.isRandomOrder ? Color.appAccent : Color.appTextSecondary)
            .disabled(vm.filteredVideos.isEmpty)
            .help(vm.isRandomOrder
                  ? "Shuffled — click to reshuffle (⌘⇧R)"
                  : "Shuffle — show the library in random order (⌘⇧R)")
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button {
                vm.playAllFromStart()
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(vm.isPlayAllSession ? Color.appAccent : Color.appTextSecondary)
            .disabled(vm.filteredVideos.isEmpty)
            .help(vm.isPlayAllSession
                  ? "Play All — playing this view in order (⌘⇧P restarts from the first video)"
                  : "Play All — play this view from the first video (⌘⇧P)")
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button {
                vm.playAllLoops.toggle()
            } label: {
                Image(systemName: "repeat")
            }
            .buttonStyle(.plain)
            .foregroundStyle(vm.playAllLoops ? Color.appAccent : Color.appTextSecondary)
            .help(vm.playAllLoops
                  ? "Loop Play All — on; after the last video, start again from the first"
                  : "Loop Play All — off; Play All stops after the last video")

            Divider().frame(height: 16)

            AppSegmentedControl(
                selection: Binding(
                    get: { vm.viewMode },
                    set: { newValue in
                        vm.scrollToSelectedOnViewSwitch = true
                        vm.viewMode = newValue
                        vm.savePreferences()
                    }
                ),
                items: [ViewMode.grid, .list],
                tooltip: { mode in
                    switch mode {
                    case .grid: "Grid view (⌘1)"
                    case .list: "List view (⌘2)"
                    }
                }
            ) { mode in
                switch mode {
                case .list: Label("List", systemImage: "list.bullet")
                case .grid: Label("Grid", systemImage: "square.grid.2x2")
                }
            }
            .controlSize(.small)

            sortCluster

            Divider().frame(height: 16)

            // Search is placed inline here (after the mode picker, before right-aligned actions)
            // to match the Curated Wall wireframe mockup.
            searchField

            Spacer()

            // Video count — busy progress / errors live in the bottom activity strip.
            Text(headerStatusText)
                .font(.system(size: 10))
                .foregroundStyle(Color.appTextTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.trailing, 4)

            // Icon-only queue access when the strip is not already showing that job.
            if showsHeaderConversionIconOnly { conversionPill }
            if showsHeaderMoveIconOnly { movePill }

            // Unified filter drawer (⌘⇧F) — Quick and Advanced are tabs inside.
            Button {
                vm.toggleFiltersDrawer()
            } label: {
                if vm.isCuratedWallFiltersDrawerOpen {
                    Image(systemName: "xmark.circle")
                } else {
                    Image(systemName: "slider.horizontal.3")
                        .symbolVariant(vm.hasActiveFilters ? .fill : .none)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                vm.isCuratedWallFiltersDrawerOpen
                    ? Color.appTextSecondary
                    : (vm.hasActiveFilters ? Color.appAccent : Color.appTextSecondary)
            )
            .help(vm.isCuratedWallFiltersDrawerOpen ? "Close Filter (⌘⇧F)" : "Filter (⌘⇧F)")
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Color.appSurface.opacity(0.35))
    }

    /// The full browsing surface for the Curated Wall: header bar + optional top drawer + optional active pills + grid/list.
    /// Replaces the previous vertical split + bottom filter strip for this variant.
    private var wallBrowserPane: some View {
        VStack(spacing: 0) {
            curatedHeaderBar

            // GeometryReader reports whatever's left after the header above — the space the
            // drawer, its resize handle, the pills, and the grid/list all have to share.
            GeometryReader { geo in
                wallDrawerAndContent(
                    availableWidth: geo.size.width,
                    availableHeight: geo.size.height
                )
            }
        }
        // Animate the pane layout (grid/list position) in response to the reveal factor.
        // This makes the wall content rise/fall smoothly as the well above it changes height.
        .animation(.easeInOut(duration: Self.drawerAnimationDuration), value: drawerReveal)
    }

    /// Clamps a requested drawer height. Ceiling is the smaller of: what fits in the window (so the
    /// resize handle stays on screen) and the drawer's own natural content height (so it can't be
    /// dragged taller than its content — past that would just be a dead scroll region). Floor is
    /// `filtersDrawerMinHeight`, which always wins if content/window are somehow shorter.
    private func clampedFiltersDrawerHeight(_ requested: CGFloat, availableHeight: CGFloat) -> CGFloat {
        var ceiling = availableHeight - Self.filtersDrawerHandleHeight
        if let contentH = filtersDrawerContentHeight {
            ceiling = min(ceiling, contentH)
        }
        ceiling = max(ceiling, LibraryViewModel.filtersDrawerMinHeight)
        return min(max(requested, LibraryViewModel.filtersDrawerMinHeight), ceiling)
    }

    private static let filtersDrawerHandleHeight: CGFloat = 12

    @ViewBuilder
    private func wallDrawerAndContent(availableWidth: CGFloat, availableHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Drawer well — the expanding slot directly under the thin header.
            // Goal: a clean, "wow" slide where the filter panel drops down from under the header
            // while smoothly pushing the grid/list below. No full pane flash, no "appears then pushes".
            //
            // How:
            // - The drawer is *always* laid out at its full height (stable layout, no mid-animation reflow of its sections/grids).
            // - We slide it into view with a changing offset: starts fully above the well, moves downward as the well opens.
            // - The well's own height grows from 0→fullH; because it's in the VStack, this reserves space and pushes the wall content down in lockstep.
            // - `.clipped()` hides the portion that is still "above" the visible well rect.
            // - Everything is driven from the single interpolated `drawerReveal` (0...1) so the visual slide and the layout push are perfectly synchronized.
            let reveal = drawerReveal
            // Fit-to-content: always request the natural content height (the clamp caps it to the
            // window). Last-used: request the live drag value, else the persisted height.
            let requestedH: CGFloat = vm.filterDrawerHeightMode == .fitToContent
                ? (filtersDrawerContentHeight ?? LibraryViewModel.filtersDrawerDefaultHeight)
                : (filtersDrawerLiveHeight ?? vm.filtersDrawerHeight)
            let fullH = clampedFiltersDrawerHeight(requestedH, availableHeight: availableHeight)
            let shownH = fullH * reveal

            ZStack(alignment: .top) {
                CuratedWallFiltersDrawer(viewModel: vm, onNaturalHeightChanged: { h in
                    // Round to avoid sub-point jitter re-triggering the clamp.
                    let rounded = h.rounded(.up)
                    if filtersDrawerContentHeight != rounded { filtersDrawerContentHeight = rounded }
                })
                    .frame(height: fullH, alignment: .top)   // full layout (no squish/reflow)
                    .offset(y: shownH - fullH)               // -fullH (above, hidden) → 0 (fully visible in well)
                    .opacity(reveal)
            }
            .frame(height: shownH, alignment: .top)
            .clipped()
            .zIndex(1)   // ensure the sliding drawer draws above the grid/list during the push (prevents any "behind" flash)
            .animation(.easeInOut(duration: Self.drawerAnimationDuration), value: reveal)

            // Resize handle — only in "Last used" mode (Fit to content sizes itself, so there's
            // nothing to drag), and only once the drawer has finished opening (dragging mid-slide
            // isn't a sensible interaction). Adjusts and persists `filtersDrawerHeight`.
            if reveal > 0.99 && vm.filterDrawerHeightMode == .lastUsed {
                filtersDrawerResizeHandle(availableHeight: availableHeight)
                    .transition(.opacity)
            }

            // Filter pills when the drawer is fully closed; collection pill stays visible while collecting.
            if vm.selectedVideoIds.count > 1 || (reveal < 0.001 && vm.hasActiveFilters) {
                ActiveFilterPills(viewModel: vm, showFilterPills: reveal < 0.001)
                    .transition(.opacity)
            }

            if vm.sidebarFilter == .missing, vm.libraryCounts.missing > 0 {
                missingLibraryRepairCue
            }

            if vm.videos.isEmpty && !vm.hasCompletedInitialVideoLoad {
                // Stay blank until the first video observation arrives — otherwise a populated
                // library briefly flashes the empty-library invite while `videos` is still [].
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.videos.isEmpty {
                EmptyLibraryBrowserPlaceholder(
                    isDropTargeted: isBrowserDropTargeted,
                    onAddFiles: { vm.showAddMediaPicker() }
                )
            } else if vm.viewMode == .grid {
                CuratedWallGrid(
                    viewModel: vm,
                    thumbnailService: thumbService,
                    containerWidth: availableWidth
                )
            } else {
                LibraryListView(
                    viewModel: vm,
                    thumbnailService: thumbService,
                    scrollPositionRow: $listScrollPositionRow
                )
            }
        }
    }

    private func filtersDrawerResizeHandle(availableHeight: CGFloat) -> some View {
        Capsule()
            .fill(Color.appTextSecondary.opacity(0.55))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity, minHeight: Self.filtersDrawerHandleHeight)
            // Matches the Inspector hero handle's backdrop exactly (same dark navy) — without an
            // explicit background here, this row shows the plain wall/window background instead,
            // a visibly lighter charcoal that breaks the otherwise-consistent dark surroundings.
            .background(CuratedWallInspector.inspectorBackground)
            .contentShape(Rectangle())
            .gesture(
                // Global coordinate space avoids a feedback loop: the handle is laid out below the
                // drawer it resizes, so it moves as the drawer grows/shrinks. In the default *local*
                // space the moving frame makes `translation` drift even without mouse movement →
                // oscillating flicker. Global space measures against the fixed window frame instead.
                // Round to whole points to avoid sub-pixel layout thrash (same as the player handle).
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = filtersDrawerDragStartHeight
                            ?? clampedFiltersDrawerHeight(vm.filtersDrawerHeight, availableHeight: availableHeight)
                        filtersDrawerDragStartHeight = start
                        filtersDrawerLiveHeight = clampedFiltersDrawerHeight(
                            (start + value.translation.height).rounded(),
                            availableHeight: availableHeight
                        )
                    }
                    .onEnded { _ in
                        if let live = filtersDrawerLiveHeight {
                            vm.filtersDrawerHeight = live
                        }
                        filtersDrawerDragStartHeight = nil
                        filtersDrawerLiveHeight = nil
                    }
            )
            .help("Drag to resize the filters drawer")
    }

    /// Quiet repair cue when browsing Missing — never auto-forces Repair Links (offline ≠ broken).
    private var missingLibraryRepairCue: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(Color.appTextSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Library folder missing")
                    .font(.subheadline.weight(.medium))
                Text("If you moved an entire folder tree, repair the links once — ghost clips stay visible until then.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
            Spacer(minLength: 8)
            Button("Repair Links…") {
                vm.beginLocationRelink(preferredOldRoot: vm.inferredMissingLibraryRoot)
            }
            .disabled(vm.isApplyingLocationRelink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.appTextSecondary.opacity(0.08))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Curated Wall layout (bold dedicated implementation)
            // Left: elegant gallery "Wall"  |  Right: focused Inspector
            // Matches the refined mockups as closely as we can get.
            ResizableBrowserDetailSplitView(
                layoutModeKey: vm.viewMode.rawValue,
                contentWidth: browsingSplitContentWidth,
                detailWidth: browsingSplitDetailWidth,
                contentID: "curatedWall",
                detailID: detailID,
                // Playback no longer reshapes the browser, so the wall never needs freezing during play.
                freezeContent: false,
                onSizesChanged: { browserW, detailW in
                    vm.updateCurrentLayoutWithSizes(sidebarWidth: nil, contentWidth: browserW, detailWidth: detailW)
                },
                content: {
                    // Curated Wall uses a top-descending live filters drawer instead of a persistent bottom strip.
                    // Drawer always starts closed; toggle via button or ⌘⇧F. Changes are live.
                    wallBrowserPane
                },
                detail: {
                    CuratedWallInspector(video: selectedVideo, viewModel: vm, thumbnailService: thumbService)
                }
            )
            .onDrop(of: [.fileURL], isTargeted: $isBrowserDropTargeted) { providers in
                guard !providers.isEmpty else { return true }
                let group = DispatchGroup()
                var urls: [URL] = []
                let lock = NSLock()
                for provider in providers {
                    group.enter()
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        defer { group.leave() }
                        if let data = data,
                           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           let url = URL(string: path)
                        {
                            lock.lock()
                            urls.append(url)
                            lock.unlock()
                        }
                    }
                }
                group.notify(queue: .main) {
                    Task { await vm.importDroppedFiles(urls) }
                }
                return true
            }
            .overlay {
                // The single resizable player: one surface anchored top-right, shown whenever
                // playback is active. Hidden while in true full-screen (the borderless window hosts
                // the same player instead). Floats above the wall/inspector (no freeze/resize).
                if vm.isPlayingInline, !vm.isPlayerFullScreen, let video = focusedVideo {
                    GeometryReader { geo in
                        FloatingPlayerPanel(video: video, viewModel: vm, available: geo.size)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            // Drive the shared player lifecycle from state, not from any view's appear/disappear, so
            // the panel can hide for full-screen without tearing down the player.
            .onChange(of: vm.isPlayingInline) { _, isOn in
                if isOn {
                    guard let v = focusedVideo ?? selectedVideo else { vm.isPlayingInline = false; return }
                    // Search (and other text fields) often still hold focus after a click/double-click
                    // to play. Escape then only resigns the field; a second Escape is needed to stop
                    // playback. Clear focus as playback starts so the next Escape stops the player.
                    resignTextInputFocusForPlayback()
                    let seek = vm.pendingFilmstripSeekSeconds ?? 0
                    vm.pendingFilmstripSeekSeconds = nil
                    let ignoreResume = vm.pendingIgnoreResumeOnNextStart
                    vm.pendingIgnoreResumeOnNextStart = false
                    vm.playback.start(video: v, at: seek, ignoreResume: ignoreResume)
                    // Apply the starting-size preference. `.lastSize` keeps whatever the player was
                    // last left at (including sticky compact mode); `.compact` re-enables compact.
                    switch vm.playerStartPreference {
                    case .fullScreen: vm.isPlayerFullScreen = true
                    case .compact: vm.playerSizeIsCompact = true
                    case .lastSize: if vm.playerLastWasFullScreen { vm.isPlayerFullScreen = true }
                    }
                } else {
                    vm.isPlayerFullScreen = false
                    vm.playback.stop()
                }
            }
            // Surprise Me auto-play: `surpriseMePickRandom()` selects a random video and (if enabled)
            // raises this flag *in the same batch* as the selection change. The selection change also
            // fires the inspector's "video changed → stop playback" handler, so we defer starting to
            // the next runloop — otherwise that stop would immediately cancel the just-started play.
            .onChange(of: vm.pendingAutoPlay) { _, shouldPlay in
                guard shouldPlay else { return }
                vm.pendingAutoPlay = false
                DispatchQueue.main.async {
                    vm.pendingFilmstripSeekSeconds = nil
                    vm.isPlayingInline = true
                }
            }
            .onChange(of: vm.playbackItemEpoch) { _, _ in
                guard vm.isPlayerFullScreen, let player = vm.playback.player else { return }
                let title = vm.playback.currentVideo?.displayTitle ?? selectedVideo?.displayTitle ?? ""
                fullScreenController?.updatePlayback(player: player, title: title)
            }
            // Enter/leave true full-screen by moving the *same* player into a borderless window.
            .onChange(of: vm.isPlayerFullScreen) { _, isFS in
                if isFS {
                    guard fullScreenController == nil else { return }
                    Task { @MainActor in
                        // The controller creates its AVPlayer asynchronously in `start()`, so on the
                        // "open at full screen" path the player isn't ready yet — wait briefly for it
                        // (the manual full-screen button already has a player, so this returns at once).
                        var player = vm.playback.player
                        var waited = 0
                        while player == nil, waited < 3000, vm.isPlayerFullScreen {
                            try? await Task.sleep(for: .milliseconds(40))
                            waited += 40
                            player = vm.playback.player
                        }
                        guard vm.isPlayerFullScreen, fullScreenController == nil, let player else {
                            if player == nil { vm.isPlayerFullScreen = false }
                            return
                        }
                        let controller = FullscreenInlinePlayerWindowController()
                        fullScreenController = controller
                        controller.present(
                            player: player,
                            title: selectedVideo?.displayTitle ?? "",
                            startWindowInFullscreen: true,
                            subtitleTrack: vm.playback.subtitleTrack,
                            viewModel: vm,
                            onStopPlayback: {
                                vm.isPlayingInline = false
                            },
                            onEnded: {
                                vm.isPlayerFullScreen = false
                            }
                        )
                    }
                } else {
                    fullScreenController?.closeWindow()
                    fullScreenController = nil
                    // The borderless full-screen window occluded the grid; nudge it to repaint any
                    // cells the occlusion left blank once it's revealed again.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        vm.issueScrollCommand(.retile)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                vm.playback.persistPosition()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            ActivityStripView(state: vm.activityStripState) { action in
                switch action {
                case .openConversionQueue:
                    showConversionQueue = true
                case .openMoveQueue:
                    showMoveQueue = true
                }
            }
            .animation(.easeInOut(duration: 0.2), value: vm.activityStripState.isVisible)
            .onReceive(NotificationCenter.default.publisher(for: .openConversionQueue)) { _ in
                showConversionQueue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openMoveQueue)) { _ in
                showMoveQueue = true
            }
        }
        .task {
            vm.startObserving()
            // Curated Wall: always start with the top filters drawer closed (per spec).
            // Drawer state is intentionally not persisted. Set both directly (no animation on init).
            vm.isCuratedWallFiltersDrawerOpen = false
            isFiltersDrawerOpen = false
            drawerReveal = 0
            // On launch the window makes the search field the first responder, so Space would type
            // into it instead of starting playback. Clear that unintended focus once the window has
            // settled, so Space starts playback until the user deliberately clicks the search field.
            try? await Task.sleep(for: .milliseconds(120))
            if let window = NSApp.keyWindow, window.firstResponder is NSText {
                window.makeFirstResponder(nil)
            }
        }
        .sheet(isPresented: $showConversionQueue) {
            ConversionQueueView(vm: vm)
        }
        .sheet(isPresented: $showMoveQueue) {
            MoveQueueView(vm: vm)
        }
        .sheet(item: $vm.metadataExportPresentation) { presentation in
            ExportMetadataSheet(
                viewModel: vm,
                scope: presentation.scope,
                videoCount: presentation.videoCount
            )
        }
        .sheet(item: $vm.bulkRenamePresentation) { presentation in
            BulkRenameSheet(
                viewModel: vm,
                scope: presentation.scope,
                videoCount: presentation.videoCount
            )
        }
        .sheet(item: $vm.locationRelinkPresentation) { presentation in
            LocationRelinkSheet(viewModel: vm, presentation: presentation)
        }
        .sheet(item: $vm.metadataApplyUnknownColumnsPrompt) { prompt in
            ApplyMetadataUnknownColumnsSheet(viewModel: vm, prompt: prompt)
        }
        .sheet(item: $vm.metadataApplySummary) { summary in
            ApplyMetadataSummarySheet(viewModel: vm, summary: summary)
        }
        .alert(
            vm.albumNamePrompt?.title ?? "Album",
            isPresented: Binding(
                get: { vm.albumNamePrompt != nil },
                set: { if !$0 { vm.albumNamePrompt = nil; vm.albumNameDraft = "" } }
            )
        ) {
            TextField("Album name", text: $vm.albumNameDraft)
            Button("Cancel", role: .cancel) {
                vm.albumNamePrompt = nil
                vm.albumNameDraft = ""
            }
            Button("Save") { vm.confirmAlbumNamePrompt() }
                .disabled(vm.albumNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(vm.albumNamePrompt?.message ?? "")
        }
        .onChange(of: vm.focusSearchFieldToken) { _, _ in
            isSearchFocused = true
        }
        .onChange(of: isSearchFocused) { _, focused in
            vm.isLibrarySearchFocused = focused
        }
        .onChange(of: vm.defocusTextInputsToken) { _, _ in
            resignTextInputFocusForBrowserKeyboard()
        }
        .onChange(of: vm.isCuratedWallFiltersDrawerOpen) { _, newValue in
            // Animate the reveal factor. The well and drawer heights are driven from this CGFloat,
            // so we get smooth per-frame interpolated sizes instead of a full-height pop followed by a push.
            withAnimation(.easeInOut(duration: Self.drawerAnimationDuration)) {
                isFiltersDrawerOpen = newValue
                drawerReveal = newValue ? 1 : 0
            }
        }
        .onAppear {
            guard keyDownMonitor == nil else { return }
            let lvm = vm
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                Self.processLibraryKeyDown(event, lvm: lvm)
            }
        }
        .onDisappear {
            if let m = keyDownMonitor {
                NSEvent.removeMonitor(m)
                keyDownMonitor = nil
            }
        }
    }

    /// Clears search and Inspector text focus so Space, arrows, and Escape reach the browser/player.
    private func resignTextInputFocusForBrowserKeyboard() {
        isSearchFocused = false
        vm.isLibrarySearchFocused = false
        vm.isEditingText = false
        guard let window = NSApp.keyWindow else { return }
        if let first = window.firstResponder,
           first is NSText || first is NSTextView || first is NSTextField
        {
            window.makeFirstResponder(nil)
            Self.refocusBrowserAfterTextDefocus(viewMode: vm.viewMode, window: window)
        }
    }

    private func resignTextInputFocusForPlayback() {
        resignTextInputFocusForBrowserKeyboard()
    }

    /// After the library search field (or another text control) resigns focus, give List's `Table`
    /// first responder again so row highlight and arrow keys behave normally.
    private static func refocusBrowserAfterTextDefocus(
        viewMode: ViewMode,
        window: NSWindow? = NSApp.keyWindow
    ) {
        guard viewMode == .list,
              let window,
              let content = window.contentView,
              let tableView = TableScrollHelper.findTableView(in: content)
        else { return }
        window.makeFirstResponder(tableView)
    }

    private static func arrowNavigationStep(for keyCode: UInt16, viewMode: ViewMode) -> Int? {
        switch keyCode {
        case 123: return -1
        case 124: return 1
        case 126: return viewMode == .grid ? -CuratedWallGrid.columns : -1
        case 125: return viewMode == .grid ? CuratedWallGrid.columns : 1
        default: return nil
        }
    }

    /// Grid navigation is always handled here; List defers to `Table` unless search still owns focus.
    private static func shouldHandleArrowNavigation(_ lvm: LibraryViewModel) -> Bool {
        switch lvm.viewMode {
        case .grid: return true
        case .list: return lvm.isLibrarySearchFocused
        }
    }

    /// Returns `nil` to consume the key event (do not deliver to the app).
    private static func processLibraryKeyDown(_ event: NSEvent, lvm: LibraryViewModel) -> NSEvent? {
            // Enter key (without modifiers) — start inline title edit in list or grid mode.
        // A focused text field (Inspector New Tag, search, notes, filter create-tag, etc.)
        // must keep Return for its own submit — same first-responder carve-out as Space.
        if event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [], !lvm.isEditingText {
            if let first = NSApp.keyWindow?.firstResponder,
               first is NSTextView || first is NSTextField || first is NSText
            {
                return event
            }
            if (lvm.viewMode == .list || lvm.viewMode == .grid),
               let videoId = lvm.focusedVideoId ?? (lvm.selectedVideoIds.count == 1 ? lvm.selectedVideoIds.first : nil),
               !lvm.activeMoveVideoIds.contains(videoId),
               let video = lvm.filteredVideo(forPath: videoId)
            {
                DispatchQueue.main.async {
                    lvm.beginEditingTitle(for: video)
                }
                return nil
            }
            return event
        }
            // Escape key — cancel title edit / file rename, defocus text input, or stop playback (including fullscreen).
        if event.keyCode == 53 {
            if lvm.renamingTagId != nil {
                DispatchQueue.main.async {
                    lvm.renamingTagId = nil
                    lvm.tagRenameText = ""
                    lvm.isEditingText = false
                }
                return nil
            }
            if lvm.editingTitleVideoId != nil {
                DispatchQueue.main.async {
                    lvm.cancelTitleEdit()
                }
                return nil
            }
            if lvm.renamingVideoId != nil {
                DispatchQueue.main.async {
                    lvm.cancelFileRename()
                }
                return nil
            }
            // Defocus any active text input (search field, inspector fields). SwiftUI TextFields
            // handle Escape themselves before this monitor sees it; this catches NSTextView-backed
            // fields (TabbableTextEditor handles its own via doCommandBy, but this is a fallback).
            if let first = NSApp.keyWindow?.firstResponder,
               first is NSText {
                DispatchQueue.main.async {
                    guard let window = NSApp.keyWindow else { return }
                    window.makeFirstResponder(nil)
                    Self.refocusBrowserAfterTextDefocus(viewMode: lvm.viewMode, window: window)
                }
                return nil
            }
            if lvm.isPlayingInline {
                DispatchQueue.main.async {
                    lvm.isPlayingInline = false
                }
                return nil
            }
            return event
        }
        // Space — play/pause (or start playback). ⌥-Space — "Play from Beginning": starts (or, if
        // already playing, restarts) from 0, ignoring any saved resume position. ⌥-Space replaces the
        // old ⌥⌘B "Restart from Beginning" shortcut for the already-playing case.
        if event.keyCode == 49 {
            // A focused text field (e.g. Notes) wins so a space can be typed.
            if let first = NSApp.keyWindow?.firstResponder,
               first is NSTextView || first is NSTextField
            {
                return event
            }
            guard !lvm.isEditingText else { return event }
            let optionHeld = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
            if lvm.isPlayingInline {
                DispatchQueue.main.async {
                    if optionHeld {
                        lvm.playback.restartFromBeginning()
                    } else {
                        lvm.playback.togglePlayPause()
                    }
                }
                return nil
            }
            guard lvm.focusedVideoId != nil || !lvm.selectedVideoIds.isEmpty else { return event }
            DispatchQueue.main.async {
                if optionHeld { lvm.pendingIgnoreResumeOnNextStart = true }
                lvm.isPlayingInline = true
            }
            return nil
        }

        // A — toggle the focused clip in the collected set.
        if event.keyCode == 0,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           !lvm.isEditingText {
            if let first = NSApp.keyWindow?.firstResponder,
               first is NSTextView || first is NSTextField || first is NSText
            {
                return event
            }
            DispatchQueue.main.async { lvm.toggleFocusedInCollectedSet() }
            return nil
        }

        // ⌃⌘F — toggle full-screen inline playback (enter when playing, exit when already fullscreen).
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .command],
           event.keyCode == 3 /* 'f' */ {
            if lvm.isPlayingInline {
                DispatchQueue.main.async { lvm.isPlayerFullScreen.toggle() }
                return nil
            }
            return event
        }

        // ⌘F — focus the search field (matches system-wide Find convention).
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 3 /* 'f' */ {
            DispatchQueue.main.async { lvm.requestFocusSearchField() }
            return nil
        }

        // Real command/option/control/shift only — arrow keys also carry `.function` + `.numericPad`.
        let commandModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

        // ⌘⇧F — toggle Filter drawer (Quick / Advanced tabs inside).
        // Fallback in addition to the .keyboardShortcut on the button.
        if event.modifierFlags.intersection(commandModifiers) == [.command, .shift],
           event.keyCode == 3 /* 'f' */ {
            DispatchQueue.main.async {
                lvm.toggleFiltersDrawer()
            }
            return nil
        }

        // ⌘⌥Q / ⌘⌥A — Quick / Advanced filter tab (opens the drawer if it is closed).
        if !lvm.isEditingText,
           event.modifierFlags.intersection(commandModifiers) == [.command, .option] {
            if event.keyCode == 12 /* 'q' */ {
                DispatchQueue.main.async { lvm.openFiltersDrawer(mode: .quick) }
                return nil
            }
            if event.keyCode == 0 /* 'a' */ {
                DispatchQueue.main.async { lvm.openFiltersDrawer(mode: .advanced) }
                return nil
            }
        }

        // While playing: ←/→ nudge 5s, ⌥←/⌥→ skip 15s. Takes priority over grid navigation.
        if lvm.isPlayingInline,
           [123, 124].contains(event.keyCode),
           !lvm.isEditingText {
            if let first = NSApp.keyWindow?.firstResponder, first is NSTextView || first is NSTextField {
                return event
            }
            let mods = event.modifierFlags.intersection(commandModifiers)
            let isLeft = event.keyCode == 123
            if mods.isEmpty {
                let delta = InlinePlaybackController.nudgeSeconds * (isLeft ? -1 : 1)
                DispatchQueue.main.async { lvm.playback.nudgeBy(delta) }
                return nil
            }
            if mods == .option {
                let delta = InlinePlaybackController.skipSeconds * (isLeft ? -1 : 1)
                DispatchQueue.main.async { lvm.playback.skipBy(delta) }
                return nil
            }
        }

        // Arrow keys — grid navigation (and list when search still owns focus). Handled here (same
        // local monitor as Space/Enter/Escape) because SwiftUI `.onKeyPress` on the grid's
        // `ScrollView` doesn't reliably receive keys inside the NSHostingView+NSSplitView the
        // Curated Wall is hosted in. ←/→ step one video; ↑/↓ step one row in grid, one row in list.
        // keyCodes: 123 ←, 124 →, 125 ↓, 126 ↑.
        // While playing, ←/→ are consumed above for nudge/skip; ↑/↓ still navigate the grid.
        if [123, 124, 125, 126].contains(event.keyCode),
           event.modifierFlags.intersection(commandModifiers).isEmpty,
           shouldHandleArrowNavigation(lvm),
           !lvm.isEditingText {
            let searchFocused = lvm.isLibrarySearchFocused
            // Inspector / notes fields keep caret navigation; library search yields to the result set.
            if !searchFocused,
               let first = NSApp.keyWindow?.firstResponder, first is NSTextView || first is NSTextField {
                return event
            }
            guard let step = arrowNavigationStep(for: event.keyCode, viewMode: lvm.viewMode) else {
                return event
            }
            DispatchQueue.main.async {
                if searchFocused {
                    lvm.requestDefocusSearchField()
                }
                lvm.navigateFilteredVideoStep(step)
            }
            return nil
        }

        // Home / End — "Go to first" / "Go to last": select the first/last video in the current
        // filtered order and scroll it into view. Works in both list and grid (unlike the arrow-key
        // block above, which is grid-only since List's Table already handles its own arrow keys).
        // Handled here rather than a SwiftUI `.keyboardShortcut(.home/.end)` for the same reason as
        // arrow-key navigation: Table's own responder chain can intercept Home/End for plain
        // scrolling before a menu-level shortcut would ever see the event.
        // NB: like arrow keys, Home/End always carry `.function` (+ often `.numericPad`), so a
        // `.deviceIndependentFlagsMask` emptiness check never matches — test only the real modifiers.
        if event.keyCode == 115 || event.keyCode == 119,  // 115 Home, 119 End
           event.modifierFlags.intersection(commandModifiers).isEmpty,
           shouldHandleArrowNavigation(lvm),
           !lvm.isEditingText {
            let searchFocused = lvm.isLibrarySearchFocused
            if !searchFocused,
               let first = NSApp.keyWindow?.firstResponder, first is NSTextView || first is NSTextField {
                return event
            }
            DispatchQueue.main.async {
                if searchFocused { lvm.requestDefocusSearchField() }
                if event.keyCode == 115 { lvm.goToFirstVideo() } else { lvm.goToLastVideo() }
            }
            return nil
        }

        // Page Up / Page Down — scroll the visible browser by ~one viewport (grid and list).
        // Same local-monitor path as Home/End so SwiftUI ScrollView / Table don't swallow the keys
        // before we can drive `ScrollCommandHandler`. Selection is left alone (unlike Home/End).
        // keyCodes: 116 Page Up, 121 Page Down.
        if event.keyCode == 116 || event.keyCode == 121,
           event.modifierFlags.intersection(commandModifiers).isEmpty,
           !lvm.isEditingText {
            if let first = NSApp.keyWindow?.firstResponder, first is NSTextView || first is NSTextField {
                return event
            }
            DispatchQueue.main.async {
                lvm.issueScrollCommand(event.keyCode == 116 ? .pageUp : .pageDown)
            }
            return nil
        }

        // No ⌘A handling here — deliberately. Select All lives in the Edit menu, whose action
        // routes through the responder chain first (a focused text field selects its own text,
        // List's table selects its rows) and falls back to `selectAllVideos()` only when nothing
        // claims it — see the pasteboard CommandGroup in `SkagwayApp`. Intercepting ⌘A in
        // this monitor is what repeatedly broke "select all text" in focused fields: the monitor
        // runs before menu dispatch, and no snapshot-in-advance focus check here can beat the
        // menu action's at-action-time responder-chain routing.

        // ⌘⇧A — Clear Collection. Works in both List and grid (unlike ⌘A, `Table` has no native
        // "deselect all" to defer to, so this needs to be handled here for List too). Unlike ⌘A,
        // there's no native text-editing meaning for ⌘⇧A to defer to, so — unless actively renaming
        // a file — this always claims the shortcut, even while a field (e.g. in the Inspector) is
        // focused; otherwise a focused field would silently swallow it with no visible effect.
        if event.keyCode == 0,  // 'a'
           event.modifierFlags.intersection(commandModifiers) == [.command, .shift],
           !lvm.isEditingText {
            DispatchQueue.main.async { lvm.deselectAllVideos() }
            return nil
        }

        // ⌘⌥C — Clear all filters (matches pill "Clear all" and View menu).
        if event.keyCode == 8,  // 'c'
           event.modifierFlags.intersection(commandModifiers) == [.command, .option],
           !lvm.isEditingText,
           lvm.hasActiveFilters {
            DispatchQueue.main.async { lvm.resetAllFilters() }
            return nil
        }

        return event
    }

}
