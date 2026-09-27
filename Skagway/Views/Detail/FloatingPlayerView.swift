import AVKit
import AppKit
import SwiftUI

/// `AVPlayerView` subclass that intercepts **Shift+Space** for "restart from beginning". Plain Space
/// is left to AVPlayerView's native play/pause. AVPlayerView otherwise treats Shift+Space as plain
/// Space (ignoring the modifier), so without this it would just toggle play/pause.
final class KeyAwarePlayerView: AVPlayerView {
    var onRestartFromBeginning: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // keyCode 49 = Space.
        if event.keyCode == 49, event.modifierFlags.contains(.shift) {
            onRestartFromBeginning?()
            return
        }
        super.keyDown(with: event)
    }
}

extension AVPlayerView {
    /// Hands a wheel event from Skagway's scrubber chrome to AVKit's own wheel scrub, so the bar and
    /// filmstrip scrub exactly like the picture. AVKit handles the wheel in a private content subview,
    /// not on `AVPlayerView`, so the event goes to whatever the player hit-tests at its center.
    func forwardWheelScrub(_ event: NSEvent) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let pointInSuperview = superview.map { convert(center, to: $0) } ?? center
        let target = hitTest(pointInSuperview) ?? subviews.first ?? self
        target.scrollWheel(with: event)
    }

    /// Nearest `AVPlayerView` that overlaps `view` on screen, searching outward from `view`.
    static func nearest(overlapping view: NSView) -> AVPlayerView? {
        guard view.window != nil else { return nil }
        let frameInWindow = view.convert(view.bounds, to: nil)
        func search(_ root: NSView) -> AVPlayerView? {
            if let player = root as? AVPlayerView,
               !player.isHiddenOrHasHiddenAncestor,
               player.convert(player.bounds, to: nil).intersects(frameInWindow)
            {
                return player
            }
            for child in root.subviews {
                if let found = search(child) { return found }
            }
            return nil
        }
        var ancestor = view.superview
        while let current = ancestor {
            if let found = search(current) { return found }
            ancestor = current.superview
        }
        return nil
    }
}

/// Hosts an `AVPlayer` in a floating-controls `AVPlayerView`. Used by every inline playback host
/// (inspector hero, overlay panel). Takes first responder while mounted so keyboard transport
/// (Space / Shift+Space) reaches it.
struct FloatingPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var showsFullscreenButton: Bool = true
    var onRestartFromBeginning: (() -> Void)? = nil

    func makeNSView(context: Context) -> KeyAwarePlayerView {
        let view = KeyAwarePlayerView()
        view.player = player
        // Skagway owns the sole scrubber (`PlaybackTimelineBar`); hide AVKit transport.
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = showsFullscreenButton
        view.onRestartFromBeginning = onRestartFromBeginning
        // Do not steal first responder. Space is handled by the local key monitor in ContentView
        // which guards against focused text fields; the player does not need focus for that to work.
        return view
    }

    func updateNSView(_ nsView: KeyAwarePlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        // Re-assert: AppKit can restore floating controls when the player item changes.
        nsView.controlsStyle = .none
        nsView.showsFullScreenToggleButton = showsFullscreenButton
        nsView.onRestartFromBeginning = onRestartFromBeginning
    }
}
