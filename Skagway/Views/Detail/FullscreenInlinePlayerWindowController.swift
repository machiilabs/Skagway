import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Hosts inline playback in a separate window so the main library window stays normal.
/// Edge-to-edge mode uses a borderless window at `NSScreen.frame` (no `toggleFullScreen` space animation).
@MainActor
final class FullscreenInlinePlayerWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let playerView = AVPlayerView()
    private var subtitleHost: NSHostingView<SubtitleOverlayContainer>?
    private var chromeView: FullscreenTransportChromeView?
    private var mouseCatcher: FullscreenMouseMoveCatcher?
    private var onEnded: (() -> Void)?
    /// Esc stops playback entirely (preserves “last was fullscreen” for start preference).
    private var onStopPlayback: (() -> Void)?
    private var didEnd = false
    private var keyDownMonitor: Any?
    private var mouseMonitor: Any?
    private var savedPresentationOptions: NSApplication.PresentationOptions = []
    private var didApplyPresentationOptions = false

    func present(
        player: AVPlayer,
        title: String,
        startWindowInFullscreen: Bool,
        subtitleTrack: SubtitleTrack,
        viewModel: LibraryViewModel,
        onStopPlayback: @escaping () -> Void,
        onEnded: @escaping () -> Void
    ) {
        self.onEnded = onEnded
        self.onStopPlayback = onStopPlayback

        playerView.player = player
        playerView.controlsStyle = .none
        playerView.showsFullScreenToggleButton = !startWindowInFullscreen

        let host = NSHostingView(rootView: SubtitleOverlayContainer(track: subtitleTrack))
        self.subtitleHost = host

        let chrome = FullscreenTransportChromeView(
            viewModel: viewModel,
            exitTarget: self,
            exitAction: #selector(closeButtonTapped),
            onStopPlayback: onStopPlayback
        )
        chrome.onDidHide = { [weak self] in
            // Lightweight only — rebuilding tracking areas here re-shows chrome immediately.
            self?.window?.acceptsMouseMovedEvents = true
        }
        self.chromeView = chrome

        if startWindowInFullscreen {
            presentEdgeToEdge(title: title)
        } else {
            presentTitledWindow(title: title)
        }
    }

    private func presentEdgeToEdge(title: String) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            presentTitledWindow(title: title)
            return
        }

        let frame = screen.frame
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))

        embedFullSize(playerView, in: content)
        if let host = subtitleHost {
            embedFullSizePassThrough(host, in: content)
        }
        embedMouseCatcher(in: content)
        if let chrome = chromeView {
            embedFullscreenChrome(chrome, in: content)
        }

        let w = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.contentView = content
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.isOpaque = true
        w.backgroundColor = .black
        w.isMovable = false
        w.acceptsMouseMovedEvents = true
        w.setFrame(frame, display: true)
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        savedPresentationOptions = NSApplication.shared.presentationOptions
        NSApplication.shared.presentationOptions = [.hideMenuBar, .hideDock]
        didApplyPresentationOptions = true

        installEventMonitors()
        chromeView?.beginIdleCycle()
    }

    private func presentTitledWindow(title: String) {
        playerView.showsFullScreenToggleButton = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        embedFullSize(playerView, in: content)
        if let host = subtitleHost {
            embedFullSizePassThrough(host, in: content)
        }
        embedMouseCatcher(in: content)
        if let chrome = chromeView {
            embedFullscreenChrome(chrome, in: content)
        }

        let w = NSWindow(
            contentRect: content.bounds,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.contentView = content
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = true
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)

        installEventMonitors()
        chromeView?.beginIdleCycle()
    }

    /// Playlist advance replaces the `AVPlayer` instance; retarget the fullscreen view without
    /// tearing down the window.
    func updatePlayback(player: AVPlayer, title: String) {
        playerView.player = player
        window?.title = title
    }

    private func embedFullSize(_ child: NSView, in parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = true
        child.frame = parent.bounds
        child.autoresizingMask = [.width, .height]
        parent.addSubview(child)
    }

    private func embedFullSizePassThrough(_ child: NSView, in parent: NSView) {
        let wrap = PassThroughView(frame: parent.bounds)
        wrap.autoresizingMask = [.width, .height]
        child.frame = wrap.bounds
        child.autoresizingMask = [.width, .height]
        wrap.addSubview(child)
        parent.addSubview(wrap)
    }

    private func embedMouseCatcher(in parent: NSView) {
        let catcher = FullscreenMouseMoveCatcher(frame: parent.bounds)
        catcher.autoresizingMask = [.width, .height]
        catcher.onMouseMoved = { [weak self] locationInWindow in
            self?.chromeView?.noteMouseActivity(locationInWindow: locationInWindow, force: false)
        }
        parent.addSubview(catcher)
        mouseCatcher = catcher
    }

    /// Full-window clear chrome host (bottom transport + top traffic lights; hit-tests only interactive bands).
    private func embedFullscreenChrome(_ chrome: NSView, in parent: NSView) {
        chrome.translatesAutoresizingMaskIntoConstraints = true
        chrome.frame = parent.bounds
        chrome.autoresizingMask = [.width, .height]
        parent.addSubview(chrome)
    }

    private func installEventMonitors() {
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window else { return event }
            // Esc → stop playback (same as windowed). ⌃⌘F → exit to floating player.
            if event.keyCode == 53 {
                MainActor.assumeIsolated {
                    self.onStopPlayback?()
                }
                return nil
            }
            if event.keyCode == 3,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .command] {
                self.closeWindow()
                return nil
            }
            return event
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved,
                .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .scrollWheel,
            ]
        ) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window else { return event }
            let location = event.locationInWindow
            return MainActor.assumeIsolated { () -> NSEvent? in
                if event.type == .scrollWheel {
                    self.chromeView?.noteScrollWheel(locationInWindow: location, event: event)
                    // Scrubber bar and filmstrip scrub like the picture.
                    if self.chromeView?.isOverTransportBar(locationInWindow: location) == true {
                        self.playerView.forwardWheelScrub(event)
                        return nil
                    }
                } else {
                    let isClickOrDrag = event.type != .mouseMoved
                    self.chromeView?.noteMouseActivity(locationInWindow: location, force: isClickOrDrag)
                }
                return event
            }
        }
    }

    @objc private func closeButtonTapped() {
        closeWindow()
    }

    func closeWindow() {
        guard window != nil else {
            finishEndedIfNeeded()
            return
        }
        window?.close()
    }

    private func finishEndedIfNeeded() {
        guard !didEnd else { return }
        didEnd = true
        if didApplyPresentationOptions {
            NSApplication.shared.presentationOptions = savedPresentationOptions
            didApplyPresentationOptions = false
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        chromeView?.shutdown()
        chromeView?.removeFromSuperview()
        chromeView = nil
        mouseCatcher?.onMouseMoved = nil
        mouseCatcher?.removeFromSuperview()
        mouseCatcher = nil
        playerView.player = nil
        subtitleHost?.removeFromSuperview()
        subtitleHost = nil
        window?.delegate = nil
        window = nil
        onEnded?()
        onEnded = nil
        onStopPlayback = nil
    }

    func windowWillClose(_ notification: Notification) {
        finishEndedIfNeeded()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.acceptsMouseMovedEvents = true
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !didEnd, let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didEnd else { return }
            let key = NSApp.keyWindow
            if let key {
                if key.parent === window || key.isSheet { return }
                if key.level.rawValue >= NSWindow.Level.popUpMenu.rawValue { return }
            }
            window.acceptsMouseMovedEvents = true
            window.makeKey()
        }
    }
}

private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
