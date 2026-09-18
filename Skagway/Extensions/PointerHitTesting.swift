import AppKit

/// After a full-pane overlay (floating player) dismisses, the cursor may still sit over a
/// SwiftUI control that never received `mouseEntered` — taps then silently no-op until the
/// pointer moves. Synthesize a `mouseMoved` so hover and gesture hit-testing rebind.
enum PointerHitTesting {
    static func refreshHover(in window: NSWindow? = NSApp.keyWindow) {
        guard let window else { return }
        let location = window.mouseLocationOutsideOfEventStream
        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) else { return }
        window.sendEvent(event)
    }
}
