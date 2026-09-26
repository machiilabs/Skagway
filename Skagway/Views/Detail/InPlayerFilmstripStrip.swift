import AppKit
import SwiftUI

/// Horizontal 1×N frame strip for the floating / fullscreen player transport chrome.
/// Fades with `PlaybackTimelineBar` via the shared `controlsVisible` parent opacity — do not
/// add a separate idle timer here.
///
/// Spans the **same width as the scrubber track**. Frame count N is chosen from that width so
/// each cell stays ~16:9 (dedicated bake — not the Inspector filmstrip).
///
/// Pointer seek and hover preview live on `PlaybackTimelineBar` (one zone with the scrubber):
/// x maps linearly to time. This view is display + VoiceOver step-by-frame only.
struct InPlayerFilmstripStrip: View {
    @Bindable var viewModel: LibraryViewModel
    let video: Video
    let stripHeight: CGFloat

    @State private var stripImage: NSImage?
    @State private var cellTimes: [Double] = []
    @State private var frameCount: Int = ThumbnailService.playerStripMinFrames
    @State private var loadTask: Task<Void, Never>?

    private var playback: InlinePlaybackController { viewModel.playback }

    private var playheadIndex: Int {
        ThumbnailService.playerStripPlayheadIndex(
            seconds: playback.currentTimeSeconds,
            duration: max(playback.durationSeconds, video.duration ?? 0),
            frameCount: frameCount
        )
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let n = ThumbnailService.playerStripFrameCount(
                trackWidth: width,
                stripHeight: stripHeight
            )

            ZStack(alignment: .topLeading) {
                if let stripImage {
                    Image(nsImage: stripImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: width, height: stripHeight)
                        .allowsHitTesting(false)
                } else {
                    Color.black.opacity(0.35)
                        .frame(width: width, height: stripHeight)
                        .allowsHitTesting(false)
                }

                HStack(spacing: 0) {
                    ForEach(0..<max(frameCount, 1), id: \.self) { index in
                        Rectangle()
                            .fill(Color.clear)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .trailing) {
                                if index < frameCount - 1 {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.18))
                                        .frame(width: 1)
                                }
                            }
                            .overlay {
                                if index == playheadIndex, frameCount > 0 {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .strokeBorder(Color.appAccent, lineWidth: 2)
                                        .padding(1)
                                }
                            }
                    }
                }
                .frame(width: width, height: stripHeight)
                .allowsHitTesting(false)
            }
            .frame(width: width, height: stripHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(earlyFrame == nil ? "Filmstrip" : "Filmstrip. \(PlayerStripEarlyFrame.message)")
            .accessibilityValue(accessibilityPlayheadLabel)
            .accessibilityHint("Scrub to seek, or adjust to step by frame")
            .accessibilityAdjustableAction { direction in
                guard !cellTimes.isEmpty else { return }
                let next: Int
                switch direction {
                case .increment:
                    next = min(cellTimes.count - 1, playheadIndex + 1)
                case .decrement:
                    next = max(0, playheadIndex - 1)
                @unknown default:
                    return
                }
                playback.seek(toSeconds: cellTimes[next], resumePlayback: true)
            }
            .onAppear {
                scheduleLoad(frameCount: n)
            }
            .onChange(of: n) { _, newN in
                scheduleLoad(frameCount: newN)
            }
        }
        .frame(height: stripHeight)
        .preference(key: PlayerStripEarlyFrameKey.self, value: earlyFrame)
        .onChange(of: video.filePath) { _, _ in
            stripImage = nil
            cellTimes = []
            scheduleLoad(frameCount: frameCount)
        }
        .onChange(of: viewModel.playerStripRefreshId) { _, _ in
            guard viewModel.playerStripRefreshPaths.contains(video.filePath) else { return }
            stripImage = nil
            cellTimes = []
            scheduleLoad(frameCount: frameCount)
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    /// Set once a real strip is up and a cell had to repeat an earlier picture.
    private var earlyFrame: PlayerStripEarlyFrame? {
        guard stripImage != nil else { return nil }
        let duration = max(playback.durationSeconds, video.duration ?? 0)
        guard let index = ThumbnailService.playerStripEarlyCellIndex(
            cellTimes: cellTimes,
            duration: duration,
            frameCount: frameCount
        ) else { return nil }
        return PlayerStripEarlyFrame(index: index, frameCount: frameCount)
    }

    private var accessibilityPlayheadLabel: String {
        guard !cellTimes.isEmpty, playheadIndex < cellTimes.count else { return "Loading" }
        return "Near \(cellTimes[playheadIndex].formattedDuration)"
    }

    private func scheduleLoad(frameCount n: Int) {
        frameCount = n
        loadTask?.cancel()
        loadTask = Task {
            await loadStrip(frameCount: n)
        }
    }

    private func loadStrip(frameCount n: Int) async {
        let cached = viewModel.thumbnailService.loadPlayerStrip(for: video.filePath, frameCount: n)
        let times = viewModel.thumbnailService.loadPlayerStripCellTimes(
            for: video.filePath,
            frameCount: n
        ) ?? []
        if !Task.isCancelled {
            stripImage = cached
            cellTimes = times
        }
        do {
            let image = try await viewModel.thumbnailService.generatePlayerStrip(
                for: video,
                frameCount: n
            )
            guard !Task.isCancelled else { return }
            stripImage = image
            cellTimes = viewModel.thumbnailService.loadPlayerStripCellTimes(
                for: video.filePath,
                frameCount: n
            ) ?? []
        } catch {
            // Leave placeholder; scrubber still works.
        }
    }
}

/// Which cell had to repeat an earlier picture. The timeline bar draws the warning on it.
struct PlayerStripEarlyFrame: Equatable {
    static let message = "File is longer than video content"
    var index: Int
    var frameCount: Int
}

struct PlayerStripEarlyFrameKey: PreferenceKey {
    static var defaultValue: PlayerStripEarlyFrame? = nil
    static func reduce(value: inout PlayerStripEarlyFrame?, nextValue: () -> PlayerStripEarlyFrame?) {
        // Last writer wins, including nil, so the mark clears when the next clip is fine.
        value = nextValue()
    }
}

/// Warning mark for the repeated frame. Hover shows the system tooltip; click shows the same line.
/// AppKit so the click wins over the scrubber drag, the way bookmark diamonds do.
struct PlayerStripEarlyFrameWarning: NSViewRepresentable {
    func makeNSView(context: Context) -> PlayerStripEarlyFrameWarningView {
        PlayerStripEarlyFrameWarningView()
    }

    func updateNSView(_ nsView: PlayerStripEarlyFrameWarningView, context: Context) {
        nsView.toolTip = PlayerStripEarlyFrame.message
    }
}

final class PlayerStripEarlyFrameWarningView: NSView, NSPopoverDelegate {
    private var popover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = PlayerStripEarlyFrame.message
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
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        showExplanation()
    }

    override func accessibilityPerformPress() -> Bool {
        showExplanation()
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }

    private func showExplanation() {
        let text = PlayerStripEarlyFrame.message
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .labelColor
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let width = ceil(textSize.width) + 20
        let height = ceil(textSize.height) + 14
        label.frame = NSRect(x: 10, y: 7, width: ceil(textSize.width), height: ceil(textSize.height))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.addSubview(label)
        let controller = NSViewController()
        controller.view = container
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.contentSize = NSSize(width: width, height: height)
        pop.contentViewController = controller
        pop.delegate = self
        pop.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        popover = pop
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let base = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: PlayerStripEarlyFrame.message
        ) else { return }
        let side = min(bounds.width, bounds.height)
        let config = NSImage.SymbolConfiguration(pointSize: side * 0.78, weight: .bold)
        guard let symbol = base.withSymbolConfiguration(config) else { return }
        let rect = NSRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        let tinted = NSImage(size: symbol.size, flipped: isFlipped) { dst in
            symbol.draw(in: dst)
            NSColor.systemYellow.set()
            dst.fill(using: .sourceAtop)
            return true
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = .zero
        shadow.set()
        tinted.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}
