import SwiftUI

/// Elegant top-descending filters drawer for the Curated Wall variant.
/// Always presented above the wall content when open. Changes are live (no Apply).
/// Styled to feel part of the cinematic gallery experience (blue accents, refined materials, generous breathing).
struct CuratedWallFiltersDrawer: View {
    @Bindable var viewModel: LibraryViewModel
    /// Reports the drawer's natural content height (header + cards at the current width) so the
    /// resize handle can cap the height there — dragging taller than this would just add empty
    /// space / a pointless scroll region. Recomputed when the width (column packing) or the number
    /// of filter items changes.
    var onNaturalHeightChanged: ((CGFloat) -> Void)? = nil

    @State private var tagSearch: String = ""
    @State private var newTagText: String = ""
    @State private var hoverRating: Int?
    @State private var showNewCollectionSheet = false
    @State private var editingCollection: VideoCollection?
    @State private var tagPendingRename: Tag?
    @State private var tagPendingDelete: Tag?
    @State private var measuredHeaderHeight: CGFloat = 0
    @State private var measuredCardsHeight: CGFloat = 0
    @State private var renameText: String = ""
    @State private var showSaveAsCollection = false
    @State private var saveAsName = ""
    @State private var isSavingCollection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .background(GeometryReader { p in
                    Color.clear.preference(key: DrawerHeaderHeightKey.self, value: p.size.height)
                })

            GeometryReader { geo in
                ScrollView(.vertical) {
                    Group {
                        switch viewModel.filtersDrawerMode {
                        case .quick:
                            // Cards pack column-major so reading order is preserved as the wall
                            // restacks: at full width the four units sit 4-across; as it narrows
                            // they collapse to fewer columns.
                            cardColumns(availableWidth: geo.size.width)
                        case .advanced:
                            advancedFilterBody
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    // Fill the full drawer width so the vertical scrollbar sits at the right edge.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Measure natural content height so the call site can cap resizing.
                    .background(GeometryReader { p in
                        Color.clear.preference(key: DrawerCardsHeightKey.self, value: p.size.height)
                    })
                }
            }
            // Height is controlled by the presentation site (Animated well in ContentView).
        }
        .onPreferenceChange(DrawerHeaderHeightKey.self) { h in
            measuredHeaderHeight = h
            reportNaturalHeight()
        }
        .onPreferenceChange(DrawerCardsHeightKey.self) { h in
            measuredCardsHeight = h
            reportNaturalHeight()
        }
        .background(
            Color.appSurface
                .opacity(0.96)
                .background(Material.ultraThin)
        )
        .overlay(
            Rectangle()
                .fill(Color.appDivider)
                .frame(height: 1),
            alignment: .bottom
        )
        .sheet(isPresented: $showNewCollectionSheet) {
            CollectionEditorView(
                dbPool: viewModel.dbPool,
                collection: nil,
                customFields: viewModel.customMetadataFieldDefinitions,
                tags: viewModel.tags,
                onSave: { Task { await viewModel.loadCollections() } }
            )
        }
        .sheet(item: $editingCollection) { collection in
            CollectionEditorView(
                dbPool: viewModel.dbPool,
                collection: collection,
                customFields: viewModel.customMetadataFieldDefinitions,
                tags: viewModel.tags,
                onSave: { Task { await viewModel.loadCollections() } }
            )
        }
        .alert("Save as Collection", isPresented: $showSaveAsCollection) {
            TextField("Collection name", text: $saveAsName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task { await saveAsCollection() }
            }
            .disabled(saveAsName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingCollection)
        } message: {
            Text("Creates a smart collection from the current Advanced Filter. The live filter stays active.")
        }
    }

    // MARK: - Responsive column packing

    // The four Quick Filter units in reading order. Rating + Duration are grouped so they always
    // travel together. Advanced Filter is a separate drawer mode (not a fifth card).
    private let unitWidths: [CGFloat] = [260, 240, 320, 360]

    @ViewBuilder
    private func unitView(_ index: Int) -> some View {
        switch index {
        case 0: smartLibrariesCard
        case 1: collectionsCard
        case 2: ratingDurationColumn
        default: tagsCard
        }
    }

    /// Distribute `count` ordered units into `columns` groups, preserving order and giving
    /// earlier columns the surplus (e.g. 4 units / 3 columns -> [[0,1], [2], [3]]).
    private func distribute(count: Int, into columns: Int) -> [[Int]] {
        var result: [[Int]] = []
        var idx = 0
        for col in 0..<columns {
            let remainingUnits = count - idx
            let remainingCols = columns - col
            let take = Int((Double(remainingUnits) / Double(remainingCols)).rounded(.up))
            result.append(Array(idx..<(idx + take)))
            idx += take
        }
        return result
    }

    /// Column-major layout: picks the largest column count (1...4) whose combined width fits
    /// the available drawer width, then stacks the ordered units into those columns. Each
    /// column is as wide as its widest unit, and cards fill that width.
    private func cardColumns(availableWidth: CGFloat) -> some View {
        let spacing: CGFloat = 12
        let horizontalPadding: CGFloat = 16
        let usable = availableWidth - horizontalPadding * 2
        let count = unitWidths.count

        func layoutWidth(_ groups: [[Int]]) -> CGFloat {
            let columnsWidth = groups.reduce(CGFloat(0)) { sum, idxs in
                sum + (idxs.map { unitWidths[$0] }.max() ?? 0)
            }
            return columnsWidth + spacing * CGFloat(max(0, groups.count - 1))
        }

        var chosen = 1
        for columns in stride(from: count, through: 1, by: -1) {
            if layoutWidth(distribute(count: count, into: columns)) <= usable {
                chosen = columns
                break
            }
        }

        let groups = distribute(count: count, into: chosen)

        return HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(groups.enumerated()), id: \.offset) { offset, idxs in
                let columnWidth = idxs.map { unitWidths[$0] }.max() ?? 0
                // The last column always stretches to fill the remaining width so its cards
                // reach the drawer's right edge instead of leaving a gap beside them.
                let isLastColumn = offset == groups.count - 1
                VStack(spacing: spacing) {
                    ForEach(idxs, id: \.self) { i in
                        unitView(i)
                    }
                }
                .frame(
                    minWidth: columnWidth,
                    maxWidth: isLastColumn ? .infinity : columnWidth,
                    alignment: .leading
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Filter")
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)

            Picker("Mode", selection: $viewModel.filtersDrawerMode) {
                Text("Quick").tag(LibraryViewModel.FiltersDrawerMode.quick)
                Text("Advanced").tag(LibraryViewModel.FiltersDrawerMode.advanced)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)

            if viewModel.hasActiveFilters {
                Text("Matching: \(viewModel.filteredVideos.count)")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)
                    .monospacedDigit()
            }

            Spacer()

            if viewModel.filtersDrawerMode == .advanced {
                Button("Save as Collection…") {
                    saveAsName = suggestedCollectionName
                    showSaveAsCollection = true
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(Color.appAccent)
                .disabled(!viewModel.hasActiveAdvancedFilter || isSavingCollection)
                .help("Persist this filter as a named Collection")

                if viewModel.hasActiveAdvancedFilter {
                    Button("Clear") {
                        viewModel.clearAdvancedFilter()
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(Color.appAccent)
                    .help("Remove all Advanced Filter conditions")
                }
            } else if viewModel.hasActiveFilters {
                Button("Clear all") {
                    viewModel.resetAllFilters()
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(Color.appAccent)
                .help("Clear Quick Filter (sidebar, tags, rating, duration, quality)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.appBackground.opacity(0.6))
    }

    /// Full-width Advanced Filter editor — exclusive drawer mode, not mixed with Quick Filter cards.
    private var advancedFilterBody: some View {
        AdvancedFilterRulesEditor(
            group: $viewModel.advancedFilterGroup,
            customFields: viewModel.customMetadataFieldDefinitions,
            tags: viewModel.tags
        )
        .id(viewModel.advancedFilterEditorSessionID)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suggestedCollectionName: String {
        if let summary = viewModel.activeAdvancedFilterSummary, !summary.isEmpty {
            return summary.count > 40 ? String(summary.prefix(37)) + "…" : summary
        }
        return ""
    }

    private func saveAsCollection() async {
        isSavingCollection = true
        defer { isSavingCollection = false }
        _ = await viewModel.saveAdvancedFilterAsCollection(name: saveAsName)
    }

    // Reusable card container for a filter category.
    // Used so Smart Libraries / Collections / Rating / Duration / Tags appear as distinct cards.
    private func makeFilterCard<Content: View, Accessory: View>(
        title: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionLabel(title)
                Spacer()
                accessory()
            }
            content()
        }
        .padding(10)
        // Fill the allotted column width so the card background stretches edge-to-edge
        // instead of shrinkwrapping to its content (keeps equal-width columns equal).
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.appSurface.opacity(0.5)
                .background(Material.ultraThin)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(Color.appDivider.opacity(0.4), lineWidth: 1)
        )
    }

    private func libraryRow(_ title: String, icon: String, count: Int, filter: SidebarFilter) -> some View {
        let isSelected = viewModel.sidebarFilter == filter
        return Button {
            viewModel.sidebarFilter = filter
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(isSelected ? Color.appAccent : Color.appTextSecondary)
                    .frame(width: 16)
                Text(title)
                    .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextSecondary)
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.appAccent.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Like `libraryRow`, but with a trailing rescan button — the missing-file count is a
    /// point-in-time filesystem check (`refreshMissingCount()`), not something kept live, so it
    /// can go stale (a drive gets reconnected, a file moves back). This lets you force a fresh
    /// scan without switching away from and back to the Missing filter.
    private func missingLibraryRow(count: Int) -> some View {
        let isSelected = viewModel.sidebarFilter == .missing
        return HStack(spacing: 4) {
            Button {
                viewModel.sidebarFilter = .missing
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(isSelected ? Color.appAccent : Color.appTextSecondary)
                        .frame(width: 16)
                    Text("Missing")
                        .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextSecondary)
                    Spacer()
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.appTextTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await viewModel.refreshMissingCount() }
            } label: {
                if viewModel.isRefreshingMissing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appTextTertiary)
            .disabled(viewModel.isRefreshingMissing)
            .help("Rescan for missing files")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.appAccent.opacity(0.12) : Color.clear)
        )
    }

    // MARK: - Cards (horizontal wrapping layout in the drawer)

    private var smartLibrariesCard: some View {
        makeFilterCard(title: "SMART LIBRARIES") {
            VStack(spacing: 2) {
                libraryRow("All Videos", icon: "film.stack", count: viewModel.libraryCounts.all, filter: .all)

                if viewModel.showRecentlyAdded {
                    libraryRow("Recently Added", icon: "clock", count: viewModel.libraryCounts.recentlyAdded, filter: .recentlyAdded)
                }
                if viewModel.showRecentlyPlayed {
                    libraryRow("Recently Played", icon: "play.circle", count: viewModel.libraryCounts.recentlyPlayed, filter: .recentlyPlayed)
                }
                if viewModel.showTopRated {
                    libraryRow("Top Rated", icon: "star.fill", count: viewModel.libraryCounts.topRated, filter: .topRated)
                }
                if viewModel.showDuplicates {
                    libraryRow("Duplicates", icon: "doc.on.doc", count: viewModel.libraryCounts.duplicates, filter: .duplicates)
                }
                if viewModel.showCorrupt {
                    libraryRow("Corrupt", icon: "exclamationmark.triangle", count: viewModel.libraryCounts.corrupt, filter: .corrupt)
                }
                if viewModel.showMissing {
                    missingLibraryRow(count: viewModel.libraryCounts.missing)
                }
                if viewModel.showRecentlyConverted {
                    libraryRow("Recently Converted", icon: "arrow.triangle.2.circlepath", count: viewModel.libraryCounts.recentlyConverted, filter: .recentlyConverted)
                }
                if viewModel.libraryCounts.lastAdded > 0 {
                    libraryRow("Last Added", icon: "plus.rectangle.on.folder", count: viewModel.libraryCounts.lastAdded, filter: .lastAdded)
                }
                if viewModel.libraryCounts.recentlyApplied > 0 {
                    libraryRow("Last Metadata Import", icon: "square.and.arrow.down.on.square", count: viewModel.libraryCounts.recentlyApplied, filter: .recentlyApplied)
                }
            }
        }
    }

    private var collectionsCard: some View {
        makeFilterCard(title: "COLLECTIONS", accessory: {
            clearFilterAccessory {
                if case .collection = viewModel.sidebarFilter {
                    viewModel.sidebarFilter = .all
                }
            }
        }) {
            VStack(alignment: .leading, spacing: 2) {
                if viewModel.collections.isEmpty {
                    Text("No collections yet")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                } else if viewModel.collections.count > 6 {
                    // Alphabetical, not ranked — there's no meaningful "top" subset to prefer,
                    // so always show everything and scroll internally past the usual height
                    // instead of growing this card unbounded.
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(viewModel.collections, id: \.listId) { collection in
                                collectionRow(collection)
                            }
                        }
                    }
                    .frame(maxHeight: 168)
                    .scrollIndicators(.visible)
                } else {
                    ForEach(viewModel.collections, id: \.listId) { collection in
                        collectionRow(collection)
                    }
                }

                HStack(spacing: 12) {
                    Button { showNewCollectionSheet = true } label: {
                        Label("New Collection", systemImage: "plus")
                            .font(.caption)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccent)

                    Button { viewModel.presentNewEmptyAlbum() } label: {
                        Label("New Album", systemImage: "rectangle.stack.badge.plus")
                            .font(.caption)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccent)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func collectionRow(_ collection: VideoCollection) -> some View {
        let isSelected: Bool = {
            if case .collection(let c) = viewModel.sidebarFilter, c.id == collection.id { return true }
            return false
        }()
        let synopsis = collection.isSmart ? viewModel.collectionFilterSummary(for: collection) : nil
        VStack(alignment: .leading, spacing: 2) {
            Button {
                viewModel.sidebarFilter = .collection(collection)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collection.isAlbum ? "rectangle.stack" : "folder")
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.appAccent : Color.appTextTertiary)
                        .frame(width: 14)
                    Text(collection.name)
                        .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextSecondary)
                        .lineLimit(1)
                    Spacer()
                    if let id = collection.id, let c = viewModel.collectionCounts[id] {
                        Text("\(c)").font(.caption.monospacedDigit()).foregroundStyle(Color.appTextTertiary)
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.appAccent.opacity(0.12) : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected, let synopsis, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
                    .lineLimit(2)
                    .padding(.leading, 28)
                    .padding(.trailing, 8)
            }
        }
        .contextMenu {
            if collection.isSmart {
                Button("Edit as Advanced Filter\u{2026}") {
                    viewModel.editCollectionAsAdvancedFilter(collection)
                }
                Button("Edit Collection\u{2026}") { editingCollection = collection }
            } else {
                Button("Rename Album\u{2026}") {
                    viewModel.presentRenameAlbum(collection)
                }
            }
            Divider()
            Button(collection.isAlbum ? "Delete Album" : "Delete Collection", role: .destructive) {
                Task { await viewModel.deleteCollection(collection) }
            }
        }
    }

    // Rating, Duration, and Quality are grouped into a single fixed-width column so they wrap as
    // one unit and keep matching widths.
    private var ratingDurationColumn: some View {
        VStack(spacing: 12) {
            ratingCard
            durationCard
            qualityCard
        }
    }

    private var ratingCard: some View {
        makeFilterCard(title: "RATING") {
            let isUnratedSelected = viewModel.selectedRatingStars.contains(0)
            let level = viewModel.selectedRatingStars.first { $0 > 0 } ?? 0
            let preview = hoverRating ?? level
            let orHigher = viewModel.ratingFilterOrHigher
            let orHigherEnabled = !isUnratedSelected && level != 5

            HStack(spacing: 6) {
                Button {
                    if isUnratedSelected {
                        viewModel.clearRatingFilter()
                    } else {
                        viewModel.selectedRatingStars = [0]
                    }
                    hoverRating = nil
                } label: {
                    ratingCapsule(title: "No Stars", isOn: isUnratedSelected)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Unrated videos only")

                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        let isActive = preview > 0 && star <= preview
                        Button {
                            if star == level {
                                viewModel.clearRatingFilter()
                            } else {
                                viewModel.selectedRatingStars = [star]
                            }
                            hoverRating = nil
                        } label: {
                            Image(systemName: isActive ? "star.fill" : "star")
                                .font(.system(size: 18))
                                .foregroundStyle(isActive ? .yellow : Color.appTextSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(orHigher && orHigherEnabled ? "\(star) stars or higher" : "Rating \(star) only")
                        .onHover { hovering in
                            hoverRating = hovering ? star : nil
                        }
                    }
                }

                Spacer(minLength: 4)

                Button {
                    viewModel.ratingFilterOrHigher.toggle()
                } label: {
                    ratingCapsule(title: "Or Higher", isOn: orHigher && orHigherEnabled)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .layoutPriority(1)
                .disabled(!orHigherEnabled)
                .opacity(orHigherEnabled ? 1 : 0.4)
                .help(orHigherEnabled
                      ? "When on, the selected star includes that rating and every higher one (4 → 4 and 5). When off, only the exact rating matches."
                      : (isUnratedSelected
                         ? "Or Higher doesn’t apply to unrated videos"
                         : "Or Higher doesn’t apply to a 5-star filter"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ratingCapsule(title: String, isOn: Bool) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isOn ? Color.white.opacity(0.32) : Color.clear)
            )
            .overlay(
                Capsule().stroke(
                    isOn ? Color.white.opacity(0.75) : Color.white.opacity(0.45),
                    lineWidth: 1
                )
            )
            .contentShape(Rectangle())
    }

    private var durationCard: some View {
        makeFilterCard(title: "DURATION") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Min")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                    TextField("0", value: Binding(
                        get: { (viewModel.minDurationSeconds ?? 0) / 60.0 },
                        set: { viewModel.minDurationSeconds = $0 > 0 ? $0 * 60 : nil }
                    ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("min")

                    Spacer().frame(width: 12)

                    Text("Max")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                    TextField("", value: Binding(
                        get: { viewModel.maxDurationSeconds.map { $0 / 60 } ?? 0 },
                        set: { viewModel.maxDurationSeconds = ($0 > 0 ? $0 * 60 : nil) }
                    ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("min")

                    if viewModel.minDurationSeconds != nil || viewModel.maxDurationSeconds != nil {
                        Spacer()
                        Button("Clear") {
                            viewModel.clearDurationFilter()
                        }
                        .font(.caption)
                        .foregroundStyle(Color.appAccent)
                        .buttonStyle(.plain)
                    }
                }

                // Presets
                HStack(spacing: 6) {
                    durationPreset("Any", min: nil, max: nil)
                    durationPreset("< 1 min", min: nil, max: 60)
                    durationPreset("1–5 min", min: 60, max: 5 * 60)
                    durationPreset("5–30 min", min: 5 * 60, max: 30 * 60)
                    durationPreset("> 30 min", min: 30 * 60, max: nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var qualityCard: some View {
        makeFilterCard(title: "QUALITY", accessory: {
            if !viewModel.selectedQualityBuckets.isEmpty {
                clearFilterAccessory { viewModel.clearQualityFilter() }
            }
        }) {
            // Adaptive columns so "1080p"/"1440p" stay on one line; chips are intrinsic width.
            let columns = [GridItem(.adaptive(minimum: 52, maximum: 72), spacing: 6)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(ResolutionBucket.allCases) { bucket in
                    let isOn = viewModel.selectedQualityBuckets.contains(bucket.rawValue)
                    Button {
                        var next = viewModel.selectedQualityBuckets
                        if isOn { next.remove(bucket.rawValue) } else { next.insert(bucket.rawValue) }
                        viewModel.selectedQualityBuckets = next
                    } label: {
                        Text(bucket.label)
                            .font(.caption)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(isOn ? Color.appAccent.opacity(0.18) : Color.appSurface.opacity(0.6))
                            )
                            .overlay(
                                Capsule().stroke(isOn ? Color.appAccent.opacity(0.5) : Color.clear, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tagsCard: some View {
        makeFilterCard(title: "TAGS", accessory: {
            clearFilterAccessory { viewModel.clearTagFilters() }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                // Any / All mode
                Picker("Match", selection: $viewModel.tagFilterMode) {
                    Text("Any").tag(MatchMode.any)
                    Text("All").tag(MatchMode.all)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 140)
                .padding(.bottom, 2)

                // Tag search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.appTextTertiary)
                    TextField("Search tags", text: $tagSearch)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Color.appTextPrimary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.appSurface.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 4)

                // New tag — creates a standalone tag (not assigned to any video yet), so it's
                // ready to apply later. Field clears on each add so several can be created in a
                // row without re-focusing or reopening anything.
                HStack(spacing: 6) {
                    TextField("Tag name", text: $newTagText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.appTextPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.appSurface.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onSubmit { createNewTag() }

                    Button { createNewTag() } label: {
                        Label("New Tag", systemImage: "plus")
                            .font(.caption)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccent)
                    .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.bottom, 4)

                // Tags in a compact grid suitable for card width (wraps via outer FlowLayout of cards)
                let filteredTags = viewModel.tags
                    .filter { t in
                        guard let id = t.id else { return false }
                        if tagSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                            return true
                        }
                        return t.name.localizedCaseInsensitiveContains(tagSearch)
                    }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                if filteredTags.isEmpty {
                    Text("No matching tags")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .padding(.vertical, 2)
                } else {
                    let tagColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)
                    LazyVGrid(columns: tagColumns, alignment: .leading, spacing: 4) {
                        ForEach(filteredTags, id: \.id) { tag in
                            tagFilterRow(tag)
                        }
                    }
                }
            }
        }
        .alert("Rename Tag",
               isPresented: Binding(get: { tagPendingRename != nil },
                                    set: { if !$0 { tagPendingRename = nil } })) {
            TextField("Tag name", text: $renameText)
            Button("Rename") {
                if let tag = tagPendingRename {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { Task { await viewModel.renameTag(tag, to: name) } }
                }
                tagPendingRename = nil
            }
            Button("Cancel", role: .cancel) { tagPendingRename = nil }
        }
        .alert("Delete tag \u{201C}\(tagPendingDelete?.name ?? "")\u{201D}?",
               isPresented: Binding(get: { tagPendingDelete != nil },
                                    set: { if !$0 { tagPendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let tag = tagPendingDelete { Task { await viewModel.deleteTag(tag) } }
                tagPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { tagPendingDelete = nil }
        } message: {
            Text("This removes the tag from your library and unassigns it from every video. This can\u{2019}t be undone.")
        }
    }

    private func tagFilterRow(_ tag: Tag) -> some View {
        let id = tag.id ?? -1
        let isActive = viewModel.selectedTagIds.contains(id)
        return TagToggleChip(tag: tag, isActive: isActive, count: viewModel.tagCounts[id] ?? 0) { adding in
            if adding {
                viewModel.selectedTagIds.insert(id)
            } else {
                viewModel.selectedTagIds.remove(id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Rename Tag\u{2026}") { renameText = tag.name; tagPendingRename = tag }
            Divider()
            Button("Delete Tag", role: .destructive) { tagPendingDelete = tag }
        }
    }

    /// Natural drawer height = header + padded cards. Reported once both have measured (> 0) so
    /// the call site never caps against a transient half-measured value.
    private func reportNaturalHeight() {
        guard measuredHeaderHeight > 0, measuredCardsHeight > 0 else { return }
        onNaturalHeightChanged?(measuredHeaderHeight + measuredCardsHeight)
    }

    private func createNewTag() {
        let name = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        newTagText = ""
        Task { await viewModel.createTag(name) }
    }

    // MARK: - Sections (kept for any internal reuse; content now lives in the cards above)

    private func durationPreset(_ label: String, min: Double?, max: Double?) -> some View {
        let isActive = (viewModel.minDurationSeconds == min) && (viewModel.maxDurationSeconds == max)
        // Restructured from the `Button(label) { action }` shorthand to an explicit label closure
        // so `.contentShape` can be applied directly to the label content — a `.plain` button's
        // hit-testing otherwise only covers the rendered text glyphs, not the padded capsule
        // around it, leaving a dead zone a user would expect to be clickable.
        return Button {
            viewModel.minDurationSeconds = min
            viewModel.maxDurationSeconds = max
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isActive ? Color.appAccent.opacity(0.18) : Color.appSurface.opacity(0.6))
                )
                .overlay(
                    Capsule().stroke(isActive ? Color.appAccent.opacity(0.5) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.appAccent)
            .padding(.leading, 4)
    }

    /// Small "Clear filter" link for a card's header row, right-aligned next to its title.
    private func clearFilterAccessory(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Clear filter", systemImage: "xmark")
                .font(.caption2)
                .labelStyle(.titleAndIcon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.appTextSecondary)
    }
}

private struct DrawerHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct DrawerCardsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
