import SwiftUI

/// Bottom activity strip (Option B): primary status + secondary job pills.
/// Hidden when idle. Sits under the browser/inspector split — not over the floating player.
struct ActivityStripView: View {
    let state: ActivityStripState
    var onAction: (AppActivityAction) -> Void

    var body: some View {
        if state.isVisible {
            HStack(spacing: 10) {
                if let primary = state.primary {
                    primaryRow(primary)
                }
                Spacer(minLength: 8)
                ForEach(state.secondaries) { activity in
                    secondaryPill(activity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 28)
            .background(Color.appSurface.opacity(0.55))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.appTextTertiary.opacity(0.25))
                    .frame(height: 1)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func primaryRow(_ activity: AppActivity) -> some View {
        let content = HStack(spacing: 8) {
            leadingGlyph(activity)
            Text(activity.title)
                .font(.system(size: 12, weight: activity.isError ? .semibold : .medium))
                .foregroundStyle(activity.isError ? Color.white : Color.appTextSecondary)
                .lineLimit(1)
            if let fraction = activity.fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(activity.isError ? Color.white.opacity(0.9) : Color.appAccent)
                    .frame(maxWidth: 180)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, activity.isError ? 10 : 0)
        .padding(.vertical, activity.isError ? 4 : 0)
        .background {
            if activity.isError {
                Capsule().fill(Color.red.opacity(0.75))
            }
        }

        if let action = activity.action {
            Button { onAction(action) } label: { content }
                .buttonStyle(.plain)
                .help(helpText(for: action))
        } else {
            content
        }
    }

    @ViewBuilder
    private func secondaryPill(_ activity: AppActivity) -> some View {
        let label = HStack(spacing: 5) {
            leadingGlyph(activity, mini: true)
            Text(activity.title)
                .font(.system(size: 11, weight: activity.isError ? .semibold : .regular))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(activity.isError ? Color.white : (isBusy(activity) ? Color.appAccent : Color.appTextSecondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(
                activity.isError
                    ? Color.red.opacity(0.75)
                    : Color.appAccent.opacity(isBusy(activity) ? 0.14 : 0.08)
            )
        )
        .contentShape(Rectangle())

        if let action = activity.action {
            Button { onAction(action) } label: { label }
                .buttonStyle(.plain)
                .help(helpText(for: action))
        } else {
            label
        }
    }

    @ViewBuilder
    private func leadingGlyph(_ activity: AppActivity, mini: Bool = false) -> some View {
        if activity.isError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: mini ? 9 : 11, weight: .semibold))
        } else if isBusy(activity) {
            ProgressView()
                .controlSize(mini ? .mini : .small)
        } else {
            Image(systemName: symbolName(for: activity.kind))
                .font(.system(size: mini ? 9 : 11, weight: .semibold))
        }
    }

    private func isBusy(_ activity: AppActivity) -> Bool {
        activity.isBusy && !activity.isError
    }

    private func symbolName(for kind: AppActivityKind) -> String {
        switch kind {
        case .scanning: return "magnifyingglass"
        case .fingerprinting: return "fingerprint"
        case .importingMetadata, .exportingMetadata: return "square.and.arrow.down"
        case .reencoding: return "arrow.triangle.2.circlepath"
        case .moving: return "folder"
        case .deleting: return "trash"
        case .repairingLinks: return "link"
        case .message: return "info.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func helpText(for action: AppActivityAction) -> String {
        switch action {
        case .openConversionQueue: return "Re-encode queue — click to manage"
        case .openMoveQueue: return "Move queue — click to manage"
        }
    }
}
