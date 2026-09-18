import CoreGraphics
import Foundation

/// Viewport pin for the browser’s focused / selected clip — used so Inspector show/hide can put
/// that clip back in the **same on-screen slot** after the pane width (and grid column count) change.
final class BrowserScrollPinStore {
    struct Pin: Equatable {
        let videoId: String
        /// Document Y of the row’s vertical mid minus the visible top (same space as clip/table).
        let offsetFromVisibleTop: CGFloat
    }

    var pin: Pin?
}
