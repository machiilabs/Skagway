import CoreGraphics
import Foundation

extension Notification.Name {
    /// Posted after Inspector show/hide so pin controllers can restore without an `@Observable` token
    /// (a token bump was forcing CuratedWallGrid to re-evaluate every cached card).
    static let skagwayBrowserScrollPinRestore = Notification.Name("Skagway.browserScrollPinRestore")
}

/// Viewport pin for the browser’s focused / selected clip — used so Inspector show/hide can put
/// that clip back in the **same on-screen slot** after the pane width (and grid column count) change.
/// Not `@Observable` — mutated in place so scroll tracking does not thrash the UI.
final class BrowserScrollPinStore {
    struct Pin: Equatable {
        let videoId: String
        /// Document Y of the row’s vertical mid minus the visible top (same space as clip/table).
        let offsetFromVisibleTop: CGFloat
    }

    var pin: Pin?
    /// Set just before Inspector width change; consumed by `BrowserScrollPinController`.
    var pendingRestore: Pin?
}
