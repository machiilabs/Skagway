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
                } else {
                    Color.black.opacity(0.35)
                        .frame(width: width, height: stripHeight)
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

                if picturesEndEarly {
                    Text("Pictures end before the file does.")
                        .font(.system(size: stripHeight < 48 ? 10 : 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.62)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 3)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: stripHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(picturesEndEarly ? "Filmstrip. Pictures end before the file does." : "Filmstrip")
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

    private var picturesEndEarly: Bool {
        guard stripImage != nil else { return false }
        let duration = max(playback.durationSeconds, video.duration ?? 0)
        return ThumbnailService.playerStripPicturesEndEarly(
            cellTimes: cellTimes,
            duration: duration,
            frameCount: frameCount
        )
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
