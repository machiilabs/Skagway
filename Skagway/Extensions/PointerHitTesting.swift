import AppKit

/// After a full-pane overlay dismisses or a Storyboard card grows a focus ring, the cursor may
/// still sit over a SwiftUI control that never received `mouseEntered`. Synthesize `mouseMoved`
/// so hover chrome rebinds. Collage play/seek does not depend on this — it uses AppKit mouseUp.
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
