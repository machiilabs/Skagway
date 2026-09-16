import SwiftUI
import AppKit
import AVFoundation

/// Dedicated elegant gallery card for the Curated Wall.
/// Track B card chrome: vignette, title scrim, coherent on-thumb badges, premium selection/hover.
struct CuratedWallCard: View {
    let video: Video
    let selectionState: CardSelectionState
    let isRenaming: Bool
    let isEditingTitle: Bool
    @Binding var renameText: String
    @Binding var titleEditText: String
    let thumbnailService: ThumbnailService
    /// Wall media: poster still vs 2×3 storyboard collage.
    var displayMode: WallCardMediaMode = .poster
    /// True while this video has an active (queued or in-flight) cross-volume move — shows a
    /// spinner badge over the thumbnail so the "frozen" state is visible without right-clicking.
    var isMoving: Bool = false
    /// Fraction (0...1) watched, from the saved resume position — draws a thin progress bar along
    /// the bottom of the thumbnail, Netflix/Hulu "continue watching" style. `nil`/0 hides it.
    var resumeFraction: Double? = nil
    /// When false (e.g. main floating player is open), skip live hover scrub to avoid fighting AVFoundation.
    var hoverPreviewEnabled: Bool = true
    /// Bumped after Repair Links / filmstrip regen so `.task(id:)` reloads (poster + storyboard).
    var thumbnailReloadId: Int = 0
    /// Accent grip drawn on the thumbnail while an album is the active filter (visual only).
    var showAlbumReorderHandle: Bool = false
    var renameFocus: FocusState<Bool>.Binding
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void
    var onCommitTitle: () -> Void
    var onCancelTitle: () -> Void
    var onRenameEditingChanged: (Bool) -> Void
    /// Storyboard View: click a collage cell → seek/play at that cell’s stored sample time.
    var onStoryboardCellPlay: ((CGPoint, CGSize) -> Void)? = nil

    private var isInlineEditing: Bool { isRenaming || isEditingTitle }
    private var isStoryboard: Bool { displayMode == .storyboard }

    @State private var thumbnail: NSImage?
    @State private var isHovering = false
    @State private var previewPlayer: AVPlayer?
    @State private var previewTask: Task<Void, Never>?
    /// Cancelled + replaced every time the task below (re)starts, so a slow detail-preview fetch from
    /// a *previous* thumbnailPath (e.g. right before a "Regenerate Thumbnail") can't land after a
    /// newer one and overwrite it with a stale image — `.task(id:)`'s auto-cancellation only covers
    /// its own structured body, not this nested unstructured `Task`.
    @State private var detailUpgradeTask: Task<Void, Never>?

    /// Poster cards stay at 188. Storyboard sizes to the collage aspect (`ThumbnailService.storyboardCompositeSize`
    /// 960×360) so width drives frame size — no letterbox dead space under a fixed tall frame.
    private let posterThumbHeight: CGFloat = 188
    private static let storyboardAspectRatio: CGFloat = 960.0 / 360.0
    private let corner: CGFloat = 8
    private let titleScrimFade: Animation = .easeInOut(duration: 0.5)
    private let focusDash = StrokeStyle(lineWidth: 2, dash: [6, 4])
    private let focusThumbDash = StrokeStyle(lineWidth: 1.5, dash: [5, 4])

    var body: some View {
        let isSelected = selectionState.isSelected
        let isFocused = selectionState.isFocused
        let titleVisible = !isInlineEditing && previewPlayer == nil
        VStack(alignment: .leading, spacing: isStoryboard ? 2 : 6) {
            ZStack(alignment: .bottom) {
                thumbMedia
                    .modifier(StoryboardThumbSizing(
                        isStoryboard: isStoryboard,
                        aspectRatio: Self.storyboardAspectRatio,
                        posterHeight: posterThumbHeight
                    ))
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .contentShape(Rectangle())
                    .overlay {
                        if isStoryboard, let onStoryboardCellPlay, !isMoving, !isInlineEditing {
                            GeometryReader { geo in
                                Color.clear
                                    .contentShape(Rectangle())
                                    .highPriorityGesture(
                                        SpatialTapGesture()
                                            .onEnded { value in
                                                onStoryboardCellPlay(value.location, geo.size)
                                            }
                                    )
                            }
                        }
                    }
                    .overlay {
                        // Soft vignette — cheap radial falloff (no blur filters on the hot path).
                        RadialGradient(
                            colors: [.clear, .black.opacity(isHovering ? 0.32 : 0.22)],
                            center: .center,
                            startRadius: 36,
                            endRadius: 150
                        )
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottom) {
                        // Keep in hierarchy and fade — sudden remove felt abrupt when preview starts.
                        if !isInlineEditing {
                            titleScrim
                                .opacity(titleVisible ? 1 : 0)
                                .animation(titleScrimFade, value: titleVisible)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        topBadgeCluster
                            .padding(isStoryboard ? 4 : 6)
                    }
                    .overlay(alignment: .topLeading) {
                        if showAlbumReorderHandle {
                            AlbumReorderHandleBadge()
                                .padding(.top, isSelected ? 26 : 0)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let resumeFraction, resumeFraction > 0 {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.black.opacity(0.35))
                                    Rectangle()
                                        .fill(
                                            LinearGradient(
                                                colors: [Color.appAccent, Color.yellow.opacity(0.95)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: max(2, geo.size.width * resumeFraction))
                                }
                            }
                            .frame(height: 3)
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay { thumbBorder(isSelected: isSelected, isFocused: isFocused, isHovering: isHovering) }
                    .shadow(
                        color: .black.opacity(isHovering ? 0.28 : (isSelected ? 0.20 : 0.12)),
                        radius: isHovering ? 10 : 6,
                        y: isHovering ? 4 : 2
                    )
                    .scaleEffect(isHovering && !isSelected ? 1.015 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: isHovering)

                if isMoving {
                    movingOverlay
                }
            }

            // Under-thumb row stays compact (date + stars) so card height is stable with on-scrim titles.
            VStack(alignment: .leading, spacing: 1) {
                if isInlineEditing {
                    TextField("", text: isEditingTitle ? $titleEditText : $renameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.appAccent, lineWidth: 1.5)
                        )
                        .focused(renameFocus)
                        .onSubmit {
                            if isEditingTitle { onCommitTitle() } else { onCommitRename() }
                        }
                        .onExitCommand {
                            if isEditingTitle { onCancelTitle() } else { onCancelRename() }
                        }
                        .onAppear { onRenameEditingChanged(true) }
                        .onDisappear { onRenameEditingChanged(false) }
                }

                HStack(spacing: 6) {
                    Text(video.dateAdded.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appTextTertiary)

                    Spacer(minLength: 0)

                    if video.rating > 0 {
                        HStack(spacing: 1) {
                            ForEach(0..<video.rating, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.yellow)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 2)
        }
        .padding(isStoryboard ? 4 : 8)
        .background(
            RoundedRectangle(cornerRadius: corner + 2, style: .continuous)
                .fill(
                    isSelected
                        ? Color(red: 12 / 255, green: 20 / 255, blue: 30 / 255)
                        : (isHovering ? Color.appSurface.opacity(0.55) : Color.clear)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: corner + 2, style: .continuous))
        .overlay { cardBorder(isSelected: isSelected, isFocused: isFocused) }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                if !isStoryboard { startHoverPreviewIfAllowed() }
            } else {
                stopHoverPreview()
            }
        }
        .onChange(of: selectionState.isSelected) { _, _ in
            if isHovering {
                startHoverPreviewIfAllowed()
            }
        }
        .onChange(of: hoverPreviewEnabled) { _, enabled in
            if !enabled { stopHoverPreview() }
        }
        .onChange(of: isMoving) { _, moving in
            if moving { stopHoverPreview() }
        }
        .onDisappear {
            stopHoverPreview()
            selectionState.isHovering = false
        }
        .task(id: "\(video.filePath)|\(video.thumbnailPath ?? "")|\(displayMode.rawValue)|\(thumbnailReloadId)") {
            // Clear first so a recycled LazyVGrid cell never keeps a pre-remap still.
            thumbnail = nil
            detailUpgradeTask?.cancel()
            detailUpgradeTask = nil
            switch displayMode {
            case .poster:
                if let lo = thumbnailService.loadThumbnail(for: video.filePath) {
                    thumbnail = lo
                }
                detailUpgradeTask = Task {
                    if let hi = await thumbnailService.detailPreviewImage(for: video, longEdge: 720) {
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            self.thumbnail = hi
                        }
                    }
                }
            case .storyboard:
                if let cached = thumbnailService.loadStoryboard(for: video.filePath) {
                    thumbnail = cached
                } else if let poster = thumbnailService.loadThumbnail(for: video.filePath) {
                    // Fast first paint while the 2×3 collage builds.
                    thumbnail = poster
                }
                detailUpgradeTask = Task {
                    do {
                        let collage = try await thumbnailService.generateStoryboard(for: video)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            self.thumbnail = collage
                        }
                    } catch {
                        // Leave poster/placeholder; avoid noisy errors while scrolling.
                    }
                }
            }
        }
    }

    // MARK: - Chrome pieces (SwiftUI-only; no extra bitmap assets)

    @ViewBuilder
    private func thumbBorder(isSelected: Bool, isFocused: Bool, isHovering: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if isSelected {
            shape.strokeBorder(Color.appAccent.opacity(0.95), lineWidth: 1.5)
        } else if isFocused {
            shape.strokeBorder(Color.appAccent.opacity(0.55), style: focusThumbDash)
        } else {
            shape.strokeBorder(Color.white.opacity(isHovering ? 0.22 : 0.10), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func cardBorder(isSelected: Bool, isFocused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner + 2, style: .continuous)
        if isSelected {
            shape.stroke(Color.appAccent.opacity(0.85), lineWidth: 2)
            if isFocused {
                shape.stroke(Color.white.opacity(0.55), style: focusDash)
            }
        } else if isFocused {
            shape.stroke(Color.white.opacity(0.55), style: focusDash)
        }
    }

    private var thumbMedia: some View {
        Color.appSurface
            .overlay {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        // Storyboard must show all six frames; poster fills the card.
                        .aspectRatio(contentMode: displayMode == .storyboard ? .fit : .fill)
                } else {
                    Image(systemName: displayMode == .storyboard ? "square.grid.3x2" : "film")
                        .font(.title2)
                        .foregroundStyle(Color.appTextTertiary.opacity(0.5))
                }
            }
            .overlay {
                if let previewPlayer {
                    HoverPreviewPlayerView(player: previewPlayer)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
    }

    private var titleScrim: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(
                colors: [.clear, .black.opacity(0.55), .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: isStoryboard ? 44 : 56)
            .overlay(alignment: .bottomLeading) {
                Text(video.displayTitle)
                    .font(.system(size: isStoryboard ? 10 : 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 1, y: 1)
                    .lineLimit(isStoryboard ? 1 : 2)
                    .padding(.horizontal, isStoryboard ? 6 : 8)
                    .padding(.bottom, isStoryboard ? 4 : 7)
            }
        }
        .allowsHitTesting(false)
    }

    private var topBadgeCluster: some View {
        HStack(spacing: 4) {
            if video.subtitlePresence.showsBadge {
                chromeBadge {
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 9, weight: .semibold))
                }
                .help(video.subtitlePresence.badgeHelp)
                .accessibilityLabel(video.subtitlePresence.badgeHelp)
            }
            if let dur = video.formattedDuration {
                chromeBadge {
                    Text(dur)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func chromeBadge<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }

    private var movingOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.black.opacity(0.45))
            VStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Moving…")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .modifier(StoryboardThumbSizing(
            isStoryboard: isStoryboard,
            aspectRatio: Self.storyboardAspectRatio,
            posterHeight: posterThumbHeight
        ))
        .allowsHitTesting(false)
    }

    /// Poster: fixed height. Storyboard: width-driven 960∶360 so collage frames fill the cell (no letterbox).
    private struct StoryboardThumbSizing: ViewModifier {
        let isStoryboard: Bool
        let aspectRatio: CGFloat
        let posterHeight: CGFloat

        func body(content: Content) -> some View {
            if isStoryboard {
                content.aspectRatio(aspectRatio, contentMode: .fit)
            } else {
                content.frame(height: posterHeight)
            }
        }
    }

    // MARK: - Hover preview

    private func startHoverPreviewIfAllowed() {
        guard !isStoryboard, hoverPreviewEnabled, !isMoving, !isInlineEditing else { return }
        previewTask?.cancel()
        previewTask = nil
        if let previewPlayer {
            previewPlayer.pause()
            previewPlayer.replaceCurrentItem(with: nil)
        }
        previewPlayer = nil

        let token = HoverPreviewExclusive.claim()
        let url = video.url
        let duration = video.duration
        previewTask = Task { @MainActor in
            await HoverPreviewPlayback.run(
                url: url,
                knownDuration: duration,
                token: token,
                assignPlayer: { player in
                    self.previewPlayer = player
                }
            )
        }
    }

    private func stopHoverPreview() {
        previewTask?.cancel()
        previewTask = nil
        if let previewPlayer {
            previewPlayer.pause()
            previewPlayer.replaceCurrentItem(with: nil)
        }
        previewPlayer = nil
    }
}
