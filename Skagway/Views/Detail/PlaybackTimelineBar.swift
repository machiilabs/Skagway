import AppKit
import SwiftUI

/// Skagway-owned transport: the sole scrubber (AVPlayerView controls are `.none`).
/// Optional in-player filmstrip sits above the scrubber and shares this view’s `controlsVisible` fade.
struct PlaybackTimelineBar: View {
    @Bindable var viewModel: LibraryViewModel
    /// When false, the bar is faded (panel hover chrome / full-screen idle).
    var controlsVisible: Bool = true

    /// Tall hit target for the scrubber. Track sits near the *bottom* of this so chrome below stays close.
    static let scrubHitHeight: CGFloat = 28
    /// Row under the scrubber: play / skip / speed, plus bookmark return chip under the ghost playhead.
    static let transportControlsHeight: CGFloat = 28
    /// IPF max height in Windowed / Full screen (native composite row is 54pt).
    static let filmstripStripHeight: CGFloat = 54
    /// IPF max height in Compact (protect picture budget).
    static let filmstripStripHeightThin: CGFloat = 36

    /// Scrubber + transport only (no filmstrip).
    static var baseBarHeight: CGFloat { scrubHitHeight + transportControlsHeight }

    /// Total transport chrome height for the current player prefs / mode.
    static func barHeight(showFilmstrip: Bool, thinFilmstrip: Bool) -> CGFloat {
        guard showFilmstrip else { return baseBarHeight }
        return baseBarHeight + (thinFilmstrip ? filmstripStripHeightThin : filmstripStripHeight)
    }

    static func barHeight(for viewModel: LibraryViewModel) -> CGFloat {
        barHeight(
            showFilmstrip: viewModel.showFilmstripInPlayer,
            thinFilmstrip: viewModel.isPlayerCompactMode
        )
    }

    /// Max reserved height (strip on, normal thickness) — fullscreen host / static callers.
    static var barHeight: CGFloat { baseBarHeight + filmstripStripHeight }

    /// Vertical center of the thin scrubber line within `scrubHitHeight` (near the bottom).
    static let trackCenterYFromBottom: CGFloat = 6

    private var showFilmstrip: Bool { viewModel.showFilmstripInPlayer }
    private var stripHeight: CGFloat {
        viewModel.isPlayerCompactMode ? Self.filmstripStripHeightThin : Self.filmstripStripHeight
    }
    /// Strip is reserved only while a current video is playing (same gate as the strip view).
    private var showingStrip: Bool { showFilmstrip && playback.currentVideo != nil }
    /// Filmstrip + scrubber hit area (one pointer zone). Transport sits below.
    private var timelineStackHeight: CGFloat {
        (showingStrip ? stripHeight : 0) + Self.scrubHitHeight
    }
    private var totalHeight: CGFloat {
        Self.barHeight(showFilmstrip: showFilmstrip, thinFilmstrip: viewModel.isPlayerCompactMode)
    }

    private static let previewWidth: CGFloat = 160
    /// Public so fullscreen chrome can reserve vertical room above the bar.
    static let scrubPreviewHeight: CGFloat = 90
    private static let previewHeight: CGFloat = scrubPreviewHeight

    @State private var isDragging = false
    @State private var dragSeconds: Double = 0
    @State private var wasPlayingBeforeDrag = false
    /// Playhead when a scrub click/drag began — restored if the click turns into a double-click bookmark.
    @State private var playheadBeforeScrub: Double?
    /// Set by double-click-to-bookmark so the scrub gesture doesn’t commit a seek to the pointer.
    @State private var suppressSeekCommit = false

    /// Scrub-hover preview (frame at pointer time), not bookmark popovers.
    @State private var hoverFraction: CGFloat?
    @State private var hoverSeconds: Double?
    @State private var hoverPreview: NSImage?
    @State private var hoverRequestID = 0
    /// Bookmark under the pointer (same AppKit hover path as scrub preview — system tooltips lose here).
    @State private var hoverBookmarkTitle: String?
    @State private var hoverBookmarkFraction: CGFloat?
    /// Filmstrip+scrubber column in the bar’s coordinate space (preview x + return-chip y).
    @State private var trackFrame: CGRect = .zero
    /// Bookmark being renamed from the diamond context menu.
    @State private var renameBookmarkTarget: VideoBookmark?
    @State private var renameBookmarkDraft: String = ""

    private var playback: InlinePlaybackController { viewModel.playback }

    private var displaySeconds: Double {
        isDragging ? dragSeconds : playback.currentTimeSeconds
    }

    private var duration: Double {
        max(playback.durationSeconds, 0)
    }

    /// Fixed width for elapsed/duration columns so the filmstrip aligns with the scrubber track.
    private static let timeColumnWidth: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            // Filmstrip + scrubber share width and one pointer zone (linear scrub + hover preview).
            HStack(spacing: 10) {
                VStack(spacing: 0) {
                    if showingStrip {
                        Color.clear.frame(height: stripHeight)
                    }
                    Text(displaySeconds.formattedDuration)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.appTextSecondary)
                        .frame(width: Self.timeColumnWidth, height: Self.scrubHitHeight, alignment: .trailing)
                }
                .frame(width: Self.timeColumnWidth)

                timelineInteractiveColumn

                VStack(spacing: 0) {
                    if showingStrip {
                        Color.clear.frame(height: stripHeight)
                    }
                    Text(duration > 0 ? duration.formattedDuration : "–:––")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.appTextSecondary)
                        .frame(width: Self.timeColumnWidth, height: Self.scrubHitHeight, alignment: .leading)
                }
                .frame(width: Self.timeColumnWidth)
            }
            .padding(.horizontal, 12)
            .frame(height: timelineStackHeight)

            // Play / skip / speed / volume sit *below* the track so they never compress it horizontally.
            // Leading cluster is priority; trailing flexible space clears FloatingPlayerPanel size/close
            // chrome (do not use a large minLength — that was crushing speed/volume in Compact).
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    transportIconButton(
                        "gobackward.15",
                        help: "Skip back \(Int(InlinePlaybackController.skipSeconds))s (⌥←)"
                    ) {
                        playback.skipBy(-InlinePlaybackController.skipSeconds)
                    }

                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appTextPrimary)
                    .help(playback.isPlaying ? "Pause" : "Play")

                    transportIconButton(
                        "goforward.15",
                        help: "Skip forward \(Int(InlinePlaybackController.skipSeconds))s (⌥→)"
                    ) {
                        playback.skipBy(InlinePlaybackController.skipSeconds)
                    }

                    playbackSpeedMenu

                    volumeControl
                }
                .layoutPriority(1)
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.transportControlsHeight)
        }
        // Fixed height — without this, ZStack proposes the full player size and the bar expands.
        .frame(maxWidth: .infinity)
        .frame(height: totalHeight)
        .coordinateSpace(name: Self.barSpaceName)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        // Preview lives on the bar (not inside the track GeometryReader) so it can rise into
        // the video without being clipped by the track’s layout bounds.
        .overlay(alignment: .topLeading) {
            scrubPreviewOverlay
            bookmarkNameOverlay
            returnPointChipOverlay
        }
        .onPreferenceChange(ScrubTrackFrameKey.self) { trackFrame = $0 }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(.easeOut(duration: 0.2), value: controlsVisible)
        .alert(
            "Rename Bookmark",
            isPresented: Binding(
                get: { renameBookmarkTarget != nil },
                set: { if !$0 { renameBookmarkTarget = nil } }
            )
        ) {
            TextField("Name", text: $renameBookmarkDraft)
            Button("Cancel", role: .cancel) {
                renameBookmarkTarget = nil
            }
            Button("Save") {
                commitRenameBookmark()
            }
        } message: {
            Text("Enter a name for this bookmark.")
        }
    }

    private func commitRenameBookmark() {
        guard let bookmark = renameBookmarkTarget else { return }
        renameBookmarkTarget = nil
        let draft = renameBookmarkDraft
        Task {
            await viewModel.renameBookmark(bookmark, title: draft)
        }
    }

    private var playbackSpeedMenu: some View {
        Menu {
            ForEach(InlinePlaybackController.playbackRateChoices, id: \.self) { rate in
                Button {
                    playback.setPlaybackRate(rate)
                } label: {
                    if abs(playback.playbackRate - rate) < 0.001 {
                        Label(
                            InlinePlaybackController.formatPlaybackRate(rate),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(InlinePlaybackController.formatPlaybackRate(rate))
                    }
                }
            }
        } label: {
            Text(InlinePlaybackController.formatPlaybackRate(playback.playbackRate))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.appTextPrimary)
                .frame(minWidth: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Playback speed")
    }

    private var volumeControl: some View {
        // Prefer mute + slider; fall back to mute-only when the compact panel is too narrow.
        ViewThatFits(in: .horizontal) {
            volumeMuteAndSlider
            volumeMuteButton
        }
    }

    private var volumeMuteAndSlider: some View {
        HStack(spacing: 4) {
            volumeMuteButton
            Slider(
                value: Binding(
                    get: { Double(playback.isMuted ? 0 : playback.volume) },
                    set: { playback.setVolume(Float($0)) }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .tint(Color.white.opacity(0.85))
            .frame(width: 64)
            .accessibilityLabel("Volume")
        }
    }

    private var volumeMuteButton: some View {
        Button {
            playback.toggleMute()
        } label: {
            Image(systemName: playback.volumeSymbolName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.appTextPrimary)
        .help(playback.isMuted || playback.volume < 0.001 ? "Unmute" : "Mute")
    }

    private func transportIconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.appTextPrimary)
        .help(help)
    }

    @ViewBuilder
    private var scrubPreviewOverlay: some View {
        // Bookmark title chip and scrub preview can both show — they don’t collide in practice.
        if let hoverFraction, let hoverSeconds, trackFrame.width > 1 {
            let xInBar = trackFrame.minX + hoverFraction * trackFrame.width
            scrubPreviewCard(seconds: hoverSeconds)
                .position(
                    x: clampedPreviewCenterX(xInBar, trackMinX: trackFrame.minX, trackWidth: trackFrame.width),
                    y: -Self.previewHeight / 2 - 10
                )
                .allowsHitTesting(false)
                .zIndex(100)
        }
    }

    @ViewBuilder
    private var bookmarkNameOverlay: some View {
        if let title = hoverBookmarkTitle,
           let fraction = hoverBookmarkFraction,
           trackFrame.width > 1 {
            let xInBar = trackFrame.minX + fraction * trackFrame.width
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.75), in: Capsule())
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                .position(
                    x: clampedPreviewCenterX(xInBar, trackMinX: trackFrame.minX, trackWidth: trackFrame.width),
                    y: -10
                )
                .allowsHitTesting(false)
                .zIndex(101)
        }
    }

    /// “Return to …” chip centered under the ghost playhead (bookmark jump origin).
    @ViewBuilder
    private var returnPointChipOverlay: some View {
        if let returnSeconds = playback.returnPointSeconds,
           duration > 0,
           trackFrame.width > 1 {
            let fraction = min(max(returnSeconds / duration, 0), 1)
            let xInBar = trackFrame.minX + fraction * trackFrame.width
            Button {
                playback.returnToSavedPoint()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                    Text(returnSeconds.formattedDuration)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(Color.appTextPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.18))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Return to \(returnSeconds.formattedDuration)")
            .accessibilityLabel("Return to \(returnSeconds.formattedDuration)")
            .position(
                x: clampedReturnChipCenterX(xInBar),
                y: trackFrame.maxY + Self.transportControlsHeight / 2
            )
            .zIndex(50)
        }
    }

    private func clampedReturnChipCenterX(_ x: CGFloat) -> CGFloat {
        // Approximate chip half-width so it stays inside the track.
        let half: CGFloat = 52
        let minX = trackFrame.minX + half
        let maxX = trackFrame.minX + trackFrame.width - half
        return min(max(x, minX), max(minX, maxX))
    }

    /// Filmstrip (optional) stacked on the scrubber track. One GeometryReader so pointer x
    /// maps to time the same way on both, and hover preview is a single enter/exit zone.
    private var timelineInteractiveColumn: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let trackY = geo.size.height - Self.trackCenterYFromBottom

            VStack(spacing: 0) {
                if showingStrip, let video = playback.currentVideo {
                    InPlayerFilmstripStrip(
                        viewModel: viewModel,
                        video: video,
                        stripHeight: stripHeight
                    )
                    .frame(width: width, height: stripHeight)
                    .allowsHitTesting(false)
                }

                trackVisuals(width: width)
                    .frame(width: width, height: Self.scrubHitHeight)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .help("Click to seek · Double-click to bookmark at pointer")
            // Single-click/drag seeks across strip + track; double-click bookmarks at pointer.
            .gesture(scrubGesture(trackWidth: width))
            .simultaneousGesture(
                SpatialTapGesture(count: 2, coordinateSpace: .local)
                    .onEnded { value in
                        bookmarkFromDoubleClick(x: value.location.x, trackWidth: width)
                    }
            )
            // DragGesture(minimumDistance: 0) often blocks SwiftUI’s onContinuousHover on macOS;
            // AppKit tracking still receives mouse-moved while gestures handle click/drag seek.
            .background {
                ScrubHoverTracker(
                    onMove: { point in
                        updateScrubHover(x: point.x, trackWidth: width)
                    },
                    onExit: {
                        if !isDragging { clearScrubHover() }
                    }
                )
            }
            .background {
                Color.clear.preference(
                    key: ScrubTrackFrameKey.self,
                    value: geo.frame(in: .named(Self.barSpaceName))
                )
            }
            // Bookmarks above scrub gestures so diamond clicks win over seek.
            .overlay {
                ForEach(viewModel.bookmarksForPlayback) { bookmark in
                    bookmarkTick(bookmark, trackWidth: width, trackY: trackY)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: timelineStackHeight)
    }

    @ViewBuilder
    private func trackVisuals(width: CGFloat) -> some View {
        let progress = duration > 0 ? min(max(displaySeconds / duration, 0), 1) : 0
        let playheadX = progress * width
        // Keep the thin track near the bottom of the hit area so transport/chrome sit close under it.
        let trackY = Self.scrubHitHeight - Self.trackCenterYFromBottom
        let ghostX: CGFloat? = {
            guard let returnSeconds = playback.returnPointSeconds, duration > 0 else { return nil }
            let fraction = min(max(returnSeconds / duration, 0), 1)
            return fraction * width
        }()

        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.clear)

            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(height: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, Self.trackCenterYFromBottom - 2)

            Capsule()
                .fill(Color.appAccent)
                .frame(width: max(playheadX, 0), height: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, Self.trackCenterYFromBottom - 2)

            // Ghost playhead: leave point when jumping via bookmark (same size as live head).
            if let ghostX {
                Circle()
                    .fill(Color(nsColor: .systemGray))
                    .frame(width: 12, height: 12)
                    .position(x: ghostX, y: trackY)
                    .allowsHitTesting(false)
            }

            Circle()
                .fill(Color.white)
                .frame(width: 12, height: 12)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .position(x: playheadX, y: trackY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Double-click where a single click would seek → bookmark at pointer, leave playhead where it was.
    private func bookmarkFromDoubleClick(x: CGFloat, trackWidth: CGFloat) {
        suppressSeekCommit = true
        let restore = playheadBeforeScrub ?? playback.currentTimeSeconds
        let resume = wasPlayingBeforeDrag
        isDragging = false
        addBookmarkAtTrackX(x, trackWidth: trackWidth)
        playback.seek(toSeconds: restore, resumePlayback: resume)
    }

    /// Bookmark at the scrub-preview / pointer time — does not seek or pause playback.
    private func addBookmarkAtTrackX(_ x: CGFloat, trackWidth: CGFloat) {
        guard duration > 0, let video = playback.currentVideo else { return }
        let fraction = min(max(x / max(trackWidth, 1), 0), 1)
        // Prefer the live hover time (matches the preview card) when present.
        let seconds = hoverSeconds ?? (fraction * duration)
        Task {
            await viewModel.addBookmark(for: video, atSeconds: seconds)
        }
    }

    private func scrubPreviewCard(seconds: Double) -> some View {
        VStack(spacing: 4) {
            Group {
                if let hoverPreview {
                    Image(nsImage: hoverPreview)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.black.opacity(0.5)
                }
            }
            .frame(width: Self.previewWidth, height: Self.previewHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            )

            Text(seconds.formattedDuration)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.65), in: Capsule())
        }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
    }

    private static let barSpaceName = "PlaybackTimelineBar"

    private func clampedPreviewCenterX(_ x: CGFloat, trackMinX: CGFloat, trackWidth: CGFloat) -> CGFloat {
        let half = Self.previewWidth / 2
        let minX = trackMinX + half
        let maxX = trackMinX + trackWidth - half
        return min(max(x, minX), max(minX, maxX))
    }

    private func updateScrubHover(x: CGFloat, trackWidth: CGFloat) {
        guard duration > 0, let video = playback.currentVideo else {
            clearScrubHover()
            return
        }
        let fraction = min(max(x / trackWidth, 0), 1)
        let seconds = fraction * duration

        let hitPx: CGFloat = 14
        var nearestTitle: String?
        var nearestFraction: CGFloat?
        var nearestDist = CGFloat.greatestFiniteMagnitude
        for bookmark in viewModel.bookmarksForPlayback {
            let bf = min(max(bookmark.seconds / duration, 0), 1)
            let dist = abs(bf * trackWidth - x)
            if dist <= hitPx, dist < nearestDist {
                nearestDist = dist
                nearestTitle = bookmark.title
                nearestFraction = bf
            }
        }

        // Skip no-op updates — thrashing @State was breaking FloatingPlayerPanel `.onHover` auto-hide.
        let fractionUnchanged = hoverFraction.map { abs($0 - fraction) < 0.001 } ?? false
        let bookmarkUnchanged =
            hoverBookmarkTitle == nearestTitle
            && (
                (hoverBookmarkFraction == nil && nearestFraction == nil)
                    || (
                        hoverBookmarkFraction != nil
                            && nearestFraction != nil
                            && abs(hoverBookmarkFraction! - nearestFraction!) < 0.0001
                    )
            )
        if fractionUnchanged && bookmarkUnchanged {
            return
        }

        hoverBookmarkTitle = nearestTitle
        hoverBookmarkFraction = nearestFraction

        guard !fractionUnchanged else { return }

        hoverFraction = fraction
        hoverSeconds = seconds

        let thumbService = viewModel.thumbnailService
        if let cached = thumbService.cachedScrubPreviewImage(for: video, atSeconds: seconds) {
            hoverPreview = cached
        }

        hoverRequestID &+= 1
        let requestID = hoverRequestID
        Task {
            let image = await thumbService.scrubPreviewImage(for: video, atSeconds: seconds)
            guard requestID == hoverRequestID, let image else { return }
            hoverPreview = image
        }
    }

    private func clearScrubHover() {
        hoverRequestID &+= 1
        hoverFraction = nil
        hoverSeconds = nil
        hoverPreview = nil
        hoverBookmarkTitle = nil
        hoverBookmarkFraction = nil
    }

    private func scrubGesture(trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0 else { return }
                if !isDragging {
                    isDragging = true
                    suppressSeekCommit = false
                    wasPlayingBeforeDrag = playback.isPlaying
                    playheadBeforeScrub = playback.currentTimeSeconds
                    // Scrubber interaction invalidates the bookmark “return to” chip.
                    playback.clearReturnPointFromScrub()
                }
                guard !suppressSeekCommit else { return }
                let fraction = min(max(value.location.x / trackWidth, 0), 1)
                dragSeconds = fraction * duration
                playback.seek(toSeconds: dragSeconds, resumePlayback: false)
                // Preview only while actually dragging — a plain click must not leave a thumbnail up.
                let dragged = hypot(value.translation.width, value.translation.height) > 2
                if dragged {
                    updateScrubHover(x: value.location.x, trackWidth: trackWidth)
                }
            }
            .onEnded { value in
                defer {
                    isDragging = false
                    playheadBeforeScrub = nil
                    clearScrubHover()
                }
                guard duration > 0 else { return }
                if suppressSeekCommit {
                    suppressSeekCommit = false
                    return
                }
                let fraction = min(max(value.location.x / trackWidth, 0), 1)
                let seconds = fraction * duration
                let resume = wasPlayingBeforeDrag
                playback.clearReturnPointFromScrub()
                playback.seek(toSeconds: seconds, resumePlayback: resume)
            }
    }

    @ViewBuilder
    private func bookmarkTick(_ bookmark: VideoBookmark, trackWidth: CGFloat, trackY: CGFloat) -> some View {
        let fraction = duration > 0 ? min(max(bookmark.seconds / duration, 0), 1) : 0
        let x = fraction * trackWidth
        let hit: CGFloat = 22

        BookmarkDiamondControl(
            onActivate: { viewModel.jumpToBookmark(bookmark) },
            onRename: {
                renameBookmarkDraft = bookmark.title
                renameBookmarkTarget = bookmark
            },
            onDelete: {
                Task { await viewModel.deleteBookmark(bookmark) }
            }
        )
        .frame(width: hit, height: hit)
        .position(x: x, y: max(hit / 2, trackY - 10))
    }
}

// MARK: - Track geometry

private struct ScrubTrackFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}

// MARK: - Hover tracking (AppKit)

/// Pass-through mouse tracker. `hitTest` returns nil so SwiftUI drag/seek still works.
/// Uses `NSTrackingArea` in the floating panel. In the borderless fullscreen window,
/// tracking areas are unreliable over `NSHostingView`, so a **window-scoped** local
/// event monitor is added only there (not app-wide over the library window).
private struct ScrubHoverTracker: NSViewRepresentable {
    var onMove: (CGPoint) -> Void
    var onExit: () -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onMove = onMove
        view.onExit = onExit
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        nsView.onMove = onMove
        nsView.onExit = onExit
    }

    final class TrackerView: NSView {
        var onMove: ((CGPoint) -> Void)?
        var onExit: (() -> Void)?
        private var tracking: NSTrackingArea?
        private var mouseMonitor: Any?
        private var pointerInside = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
            rebuildTracking()
            refreshEventMonitor()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeEventMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            rebuildTracking()
        }

        /// Borderless = Skagway’s edge-to-edge fullscreen player (not the titled library window).
        private var isFullscreenPlayerWindow: Bool {
            window?.styleMask.contains(.borderless) == true
        }

        private func refreshEventMonitor() {
            removeEventMonitor()
            guard isFullscreenPlayerWindow, window != nil else { return }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved]
            ) { [weak self] event in
                guard let self else { return event }
                guard event.window === self.window else { return event }
                // Seek drag owns the pointer while the button is down.
                if NSEvent.pressedMouseButtons & (1 << 0) != 0 {
                    return event
                }
                let point = self.convert(event.locationInWindow, from: nil)
                let inside = self.bounds.contains(point)
                if inside {
                    self.pointerInside = true
                    self.onMove?(point)
                } else if self.pointerInside {
                    self.pointerInside = false
                    self.onExit?()
                }
                return event
            }
        }

        private func removeEventMonitor() {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
            pointerInside = false
        }

        private func rebuildTracking() {
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseMoved(with event: NSEvent) {
            pointerInside = true
            onMove?(convert(event.locationInWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            pointerInside = true
            onMove?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            pointerInside = false
            onExit?()
        }
    }
}

/// AppKit-backed diamond so clicks/cursor win over the scrubber’s tracking/gestures.
private struct BookmarkDiamondControl: NSViewRepresentable {
    var onActivate: () -> Void
    var onRename: () -> Void
    var onDelete: () -> Void

    func makeNSView(context: Context) -> BookmarkDiamondNSView {
        let view = BookmarkDiamondNSView()
        view.onActivate = onActivate
        view.onRename = onRename
        view.onDelete = onDelete
        return view
    }

    func updateNSView(_ nsView: BookmarkDiamondNSView, context: Context) {
        nsView.onActivate = onActivate
        nsView.onRename = onRename
        nsView.onDelete = onDelete
    }
}

private final class BookmarkDiamondNSView: NSView {
    var onActivate: (() -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click opens the context menu (macOS convention).
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }
        onActivate?()
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    private func showContextMenu(with event: NSEvent) {
        let menu = NSMenu()
        let rename = NSMenuItem(
            title: "Rename Bookmark…",
            action: #selector(renameBookmarkAction(_:)),
            keyEquivalent: ""
        )
        rename.target = self
        menu.addItem(rename)
        let delete = NSMenuItem(
            title: "Delete Bookmark",
            action: #selector(deleteBookmarkAction(_:)),
            keyEquivalent: ""
        )
        delete.target = self
        menu.addItem(delete)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func renameBookmarkAction(_ sender: Any?) {
        onRename?()
    }

    @objc private func deleteBookmarkAction(_ sender: Any?) {
        onDelete?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let side = min(bounds.width, bounds.height) * 0.45
        let cx = bounds.midX
        let cy = bounds.midY
        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx, y: cy - side / 2))
        path.addLine(to: CGPoint(x: cx + side / 2, y: cy))
        path.addLine(to: CGPoint(x: cx, y: cy + side / 2))
        path.addLine(to: CGPoint(x: cx - side / 2, y: cy))
        path.closeSubpath()
        ctx.setFillColor(NSColor(srgbRed: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255, alpha: 1).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }
}
