import AVFoundation
import AppKit
import SwiftUI

/// Drives List hover-panel playback from AppKit show/hide — avoids relying on `onAppear`
/// when an `NSHostingView` reuses its root view across Table re-renders.
@Observable
@MainActor
final class ListHoverPreviewDriver {
    private(set) var generation: UInt64 = 0
    private(set) var shouldPlay = false

    func requestStart() {
        shouldPlay = true
        generation &+= 1
    }

    func requestStop() {
        shouldPlay = false
        generation &+= 1
    }
}

/// Ensures only one grid card runs a live hover preview at a time (large libraries).
@MainActor
enum HoverPreviewExclusive {
    private static var generation: UInt64 = 0

    static func claim() -> UInt64 {
        generation &+= 1
        return generation
    }

    static func isCurrent(_ token: UInt64) -> Bool {
        token == generation
    }

    /// Bumps generation so any in-flight preview loop exits (e.g. when full playback starts).
    static func invalidateAll() {
        generation &+= 1
    }
}

/// Silent `AVPlayerLayer` host for card hover previews (no controls, fill-crop).
struct HoverPreviewPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> HoverPreviewNSView {
        let view = HoverPreviewNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: HoverPreviewNSView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: HoverPreviewNSView, coordinator: ()) {
        nsView.player = nil
    }
}

final class HoverPreviewNSView: NSView {
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

/// Live cycling scrub on an existing file — no sidecar / DB preview asset.
@MainActor
enum HoverPreviewPlayback {
    /// Delay so sweeping the mouse across the grid doesn't spawn players.
    static let startDelayMs: UInt64 = 400
    /// How long each scrub segment plays.
    static let segmentMs: UInt64 = 900
    /// Number of waypoints between ~10% and ~90% of duration.
    static let segmentCount: Int = 8

    static func run(
        url: URL,
        knownDuration: Double?,
        token: UInt64,
        assignPlayer: (AVPlayer?) -> Void
    ) async {
        try? await Task.sleep(nanoseconds: startDelayMs * 1_000_000)
        guard !Task.isCancelled, HoverPreviewExclusive.isCurrent(token) else { return }

        let duration = await resolveDuration(url: url, known: knownDuration)
        guard duration > 2.5 else { return }
        guard !Task.isCancelled, HoverPreviewExclusive.isCurrent(token) else { return }

        let player = AVPlayer(url: url)
        player.isMuted = true
        // Keep previews light; exact frame less important than snappy seeks.
        player.automaticallyWaitsToMinimizeStalling = false
        assignPlayer(player)

        // Wait briefly for the first item to become ready enough to seek/play.
        if let item = player.currentItem {
            for _ in 0..<40 {
                if Task.isCancelled || !HoverPreviewExclusive.isCurrent(token) {
                    teardown(player: player, assignPlayer: assignPlayer)
                    return
                }
                if item.status == .readyToPlay || item.status == .failed { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if item.status == .failed {
                teardown(player: player, assignPlayer: assignPlayer)
                return
            }
        }

        var index = 0
        while !Task.isCancelled, HoverPreviewExclusive.isCurrent(token) {
            let step = Double(index % segmentCount)
            // 10% … ~90%
            let fraction = 0.10 + step * (0.80 / Double(max(segmentCount - 1, 1)))
            let seconds = max(0, min(duration - 0.25, duration * fraction))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            await player.seek(to: time, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
            guard !Task.isCancelled, HoverPreviewExclusive.isCurrent(token) else { break }
            player.play()
            try? await Task.sleep(nanoseconds: segmentMs * 1_000_000)
            player.pause()
            index += 1
        }

        teardown(player: player, assignPlayer: assignPlayer)
    }

    private static func teardown(player: AVPlayer, assignPlayer: (AVPlayer?) -> Void) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        assignPlayer(nil)
    }

    private static func resolveDuration(url: URL, known: Double?) async -> Double {
        if let known, known > 1 { return known }
        let asset = AVURLAsset(url: url)
        do {
            let t = try await asset.load(.duration)
            let s = t.seconds
            return s.isFinite && s > 0 ? s : 30
        } catch {
            return 30
        }
    }
}
