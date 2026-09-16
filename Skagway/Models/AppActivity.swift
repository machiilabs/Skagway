import Foundation

/// Kind of long-running work shown in the global activity strip.
enum AppActivityKind: String, Equatable {
    case scanning
    case fingerprinting
    case importingMetadata
    case exportingMetadata
    case reencoding
    case moving
    case deleting
    case repairingLinks
    case message
    case error
}

/// Action when the user clicks an activity chip / primary row.
enum AppActivityAction: Equatable {
    case openConversionQueue
    case openMoveQueue
}

extension Notification.Name {
    /// Posted by the app menu to open the Re-encode Queue sheet in ContentView.
    static let openConversionQueue = Notification.Name("Skagway.openConversionQueue")
    /// Posted by the app menu to open the Move Queue sheet in ContentView.
    static let openMoveQueue = Notification.Name("Skagway.openMoveQueue")
}

/// One unit of work for the bottom activity strip.
struct AppActivity: Identifiable, Equatable {
    let id: String
    let kind: AppActivityKind
    let title: String
    /// 0...1 when determinate; `nil` for indeterminate.
    let fraction: Double?
    let isError: Bool
    /// When false, the strip shows a static glyph instead of a spinner (idle review states).
    let isBusy: Bool
    let action: AppActivityAction?

    init(
        id: String,
        kind: AppActivityKind,
        title: String,
        fraction: Double? = nil,
        isError: Bool = false,
        isBusy: Bool? = nil,
        action: AppActivityAction? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.fraction = fraction
        self.isError = isError
        // Messages / errors are never "busy"; other kinds default to busy unless overridden.
        switch kind {
        case .message, .error:
            self.isBusy = false
        default:
            self.isBusy = isBusy ?? true
        }
        self.action = action
    }
}

/// Snapshot for the bottom activity strip (Option B).
struct ActivityStripState: Equatable {
    /// Headline activity (left): fullest treatment.
    var primary: AppActivity?
    /// Concurrent jobs as compact pills (right).
    var secondaries: [AppActivity]

    var isVisible: Bool { primary != nil || !secondaries.isEmpty }

    static let empty = ActivityStripState(primary: nil, secondaries: [])
}
