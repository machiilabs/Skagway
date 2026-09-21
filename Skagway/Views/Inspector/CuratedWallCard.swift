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
    /// Storyboard packing density (ignored for poster cards).
    var storyboardDensity: StoryboardDensity = .normal
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
    /// Storyboard View: click a collage cell — parent decides select vs seek/play (focus-armed).
    var onStoryboardCellPlay: ((CGPoint, CGSize) -> Void)? = nil
    /// Storyboard View: click title / footer chrome → select only (no seek).
    var onStoryboardChromeSelect: (() -> Void)? = nil

    private var isInlineEditing: Bool { isRenaming || isEditingTitle }
    private var isStoryboard: Bool { displayMode == .storyboard }
    private var isNormalStoryboard: Bool {
        isStoryboard && storyboardDensity == .normal
    }

    /// On-collage title fade height (visual only). Collage cells under the fade still seek/play;
    /// select-without-play is the title *text* plus the under-thumb footer, not this band.
    private var storyboardTitleBandHeight: CGFloat {
        isNormalStoryboard ? 52 : 40
    }
    /// Under-thumb date/rating strip — intentionally fat so select isn’t a hairline.
    private var storyboardFooterMinHeight: CGFloat {
        isNormalStoryboard ? 40 : 28
    }
    private var storyboardCardPadding: CGFloat {
        isNormalStoryboard ? 10 : 6
    }
    private var storyboardFooterVSpacing: CGFloat {
        isNormalStoryboard ? 4 : 2
    }

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
        VStack(alignment: .leading, spacing: isStoryboard ? storyboardFooterVSpacing : 6) {
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
                        if !isInlineEditing {
                            titleScrimGradient
                                .opacity(titleVisible ? 1 : 0)
                                .animation(titleScrimFade, value: titleVisible)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if isStoryboard, let onStoryboardCellPlay, !isMoving, !isInlineEditing {
                            GeometryReader { geo in
                                // Full collage, including cells under the title fade. AppKit mouseUp
                                // so a still cursor still seeks; the fade itself is not a hit target.
                                StoryboardSeekClickOverlay { location in
                                    onStoryboardCellPlay(location, geo.size)
                                }
                            }
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !isInlineEditing {
                            titleLabel
                                .fixedSize()
                                .opacity(titleVisible ? 1 : 0)
                                .animation(titleScrimFade, value: titleVisible)
                                // Poster: visual only (card tap plays). Storyboard: tight select,
                                // not the full-width fade — bottom-row frames still seek/play.
                                .allowsHitTesting(isStoryboard && onStoryboardChromeSelect != nil)
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

            // Under-thumb row: date + stars. Storyboard keeps this intentionally tall for select-only hits.
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
                        .font(.system(size: isNormalStoryboard ? 11 : 9))
                        .foregroundStyle(Color.appTextTertiary)

                    Spacer(minLength: 0)

                    if video.rating > 0 {
                        HStack(spacing: 1) {
                            ForEach(0..<video.rating, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.system(size: isNormalStoryboard ? 10 : 8))
                                    .foregroundStyle(.yellow)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: isStoryboard ? storyboardFooterMinHeight : nil, alignment: .center)
            .padding(.horizontal, isStoryboard ? 4 : 2)
            .contentShape(Rectangle())
            .modifier(StoryboardChromeTap(
                enabled: isStoryboard && onStoryboardChromeSelect != nil && !isInlineEditing,
                onSelect: { onStoryboardChromeSelect?() }
            ))
        }
        .padding(isStoryboard ? storyboardCardPadding : 8)
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
                // First paint must not decode `{hash}_storyboard.jpg`, bake from a filmstrip,
                // or wait on the AV gate. `.task` runs before SwiftUI commits the first frame
                // unless we await — Grid posters are small and sync-load; collage JPEGs are not.
                // Cached collages must never flash the poster: memory hit paints immediately;
                // disk hit stays empty until the JPEG is up; poster is first-bake only.
                if let cached = thumbnailService.residentStoryboard(for: video.filePath) {
                    thumbnail = cached
                    return
                }
                if !thumbnailService.hasStoryboardJPEGOnDisk(for: video.filePath) {
                    if let poster = thumbnailService.residentThumbnail(for: video.filePath)
                        ?? thumbnailService.loadThumbnail(for: video.filePath) {
                        thumbnail = poster
                    }
                }
                await Task.yield()
                guard !Task.isCancelled else { return }

                let path = video.filePath
                let service = thumbnailService
                let (collage, complete) = await Task.detached(priority: .userInitiated) {
                    service.storyboardDisplayCache(for: path)
                }.value
                guard !Task.isCancelled else { return }
                if let collage {
                    thumbnail = collage
                }
                guard !complete else { return }

                detailUpgradeTask = Task {
                    do {
                        let image = try await service.generateStoryboard(for: video)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            self.thumbnail = image
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
        Group {
            if isSelected {
                shape.strokeBorder(Color.appAccent.opacity(0.95), lineWidth: 1.5)
            } else if isFocused {
                shape.strokeBorder(Color.appAccent.opacity(0.55), style: focusThumbDash)
            } else {
                shape.strokeBorder(Color.white.opacity(isHovering ? 0.22 : 0.10), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cardBorder(isSelected: Bool, isFocused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner + 2, style: .continuous)
        Group {
            if isSelected {
                shape.stroke(Color.appAccent.opacity(0.85), lineWidth: 2)
                if isFocused {
                    shape.stroke(Color.white.opacity(0.55), style: focusDash)
                }
            } else if isFocused {
                shape.stroke(Color.white.opacity(0.55), style: focusDash)
            }
        }
        .allowsHitTesting(false)
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

    /// Fade only — never a hit target. Bottom-row collage cells stay seek/play.
    private var titleScrimGradient: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.55), .black.opacity(0.78)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: isStoryboard ? storyboardTitleBandHeight : 56)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    /// Title drawn on the fade. Storyboard: intrinsic-size select-only hit (not full-width).
    private var titleLabel: some View {
        Text(video.displayTitle)
            .font(.system(size: isNormalStoryboard ? 12 : (isStoryboard ? 10 : 11), weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 1, y: 1)
            .lineLimit(isStoryboard ? 1 : 2)
            .padding(.horizontal, isStoryboard ? 6 : 8)
            .padding(.bottom, isStoryboard ? (isNormalStoryboard ? 8 : 4) : 7)
            .contentShape(Rectangle())
            .modifier(StoryboardChromeTap(
                enabled: isStoryboard && onStoryboardChromeSelect != nil,
                onSelect: { onStoryboardChromeSelect?() }
            ))
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

    /// Left-click catcher for collage cells. `DragGesture(minimumDistance: 0)` and
    /// `SpatialTapGesture` stay dead after `onEnded` until `mouseMoved`, so a second
    /// click on the focused cell with a still cursor never fires. AppKit `mouseUp`
    /// does not need a tracking area or hover to arm.
    private struct StoryboardSeekClickOverlay: NSViewRepresentable {
        var onClick: (CGPoint) -> Void

        func makeNSView(context: Context) -> SeekClickView {
            let view = SeekClickView()
            view.onClick = onClick
            return view
        }

        func updateNSView(_ nsView: SeekClickView, context: Context) {
            nsView.onClick = onClick
        }

        final class SeekClickView: NSView {
            var onClick: ((CGPoint) -> Void)?
            private var mouseDownPoint: NSPoint?

            override var isFlipped: Bool { true }

            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

            override func mouseDown(with event: NSEvent) {
                mouseDownPoint = convert(event.locationInWindow, from: nil)
            }

            override func mouseUp(with event: NSEvent) {
                defer { mouseDownPoint = nil }
                guard let start = mouseDownPoint else { return }
                let end = convert(event.locationInWindow, from: nil)
                let moved = hypot(end.x - start.x, end.y - start.y)
                guard moved < 8, bounds.contains(start) else { return }
                onClick?(start)
            }

            /// Left button only — right-click / hover / moved fall through to SwiftUI.
            override func hitTest(_ point: NSPoint) -> NSView? {
                guard bounds.contains(point) else { return nil }
                guard let event = NSApp.currentEvent else { return nil }
                switch event.type {
                case .leftMouseDown:
                    return self
                case .leftMouseDragged, .leftMouseUp:
                    return mouseDownPoint != nil ? self : nil
                default:
                    return nil
                }
            }
        }
    }

    /// Select-only tap for storyboard title / footer chrome (does not start playback).
    private struct StoryboardChromeTap: ViewModifier {
        var enabled: Bool
        let onSelect: () -> Void

        func body(content: Content) -> some View {
            if enabled {
                content
                    .highPriorityGesture(TapGesture().onEnded(onSelect))
            } else {
                content
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
