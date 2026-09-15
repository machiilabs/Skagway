import SwiftUI
import AppKit

/// Preview + Apply sheet for whole-tree Location A → Location B remapping.
struct LocationRelinkSheet: View {
    @Bindable var viewModel: LibraryViewModel
    let presentation: LibraryViewModel.LocationRelinkPresentation

    @Environment(\.dismiss) private var dismiss

    @State private var oldRoot: String = ""
    @State private var newRoot: String = ""
    @State private var preview: LocationRelink.Preview?
    @State private var includeNeedsAttention = false
    @State private var appliedCount: Int?

    private var isApplying: Bool { viewModel.isApplyingLocationRelink }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Relink Location")
                .font(.title2.weight(.semibold))

            Text("Reconnect clips that still live under the same relative folders after a whole-tree move. Ratings, collections, and tags stay put — no re-import.")
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let appliedCount {
                resultsPane(appliedCount)
            } else {
                planningPane
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 420)
        .onAppear {
            oldRoot = presentation.oldRoot
            if let suggested = presentation.suggestedNewRoot {
                newRoot = suggested
                recompute()
            }
        }
    }

    private var planningPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            pathRow(label: "Old location", path: oldRoot) {
                pickOldRoot()
            }
            pathRow(label: "New location", path: newRoot.isEmpty ? "Choose a folder…" : newRoot) {
                pickNewRoot()
            }

            if let preview {
                summaryRow(preview)

                Toggle("Include flagged matches (size mismatch or path collision)", isOn: $includeNeedsAttention)
                    .disabled(preview.needsAttentionCount == 0)

                candidateList(preview)
            } else if !newRoot.isEmpty {
                Text("No clips under the old location.")
                    .foregroundStyle(Color.appTextSecondary)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isApplying)
                Spacer()
                Button("Apply Relink") {
                    Task { await apply() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(applyDisabled)
            }
        }
    }

    private func resultsPane(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Relinked \(count) clip\(count == 1 ? "" : "s").")
                .font(.headline)
            Text("Use Edit → Undo Relink Location if you need to reverse this.")
                .foregroundStyle(Color.appTextSecondary)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var applyDisabled: Bool {
        guard let preview, !isApplying else { return true }
        let n = preview.reconnectCount + (includeNeedsAttention ? preview.needsAttentionCount : 0)
        return n == 0 || newRoot.isEmpty
    }

    private func pathRow(label: String, path: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .frame(width: 100, alignment: .leading)
                .foregroundStyle(Color.appTextSecondary)
            Text(path)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose…", action: action)
                .disabled(isApplying)
        }
    }

    private func summaryRow(_ preview: LocationRelink.Preview) -> some View {
        HStack(spacing: 16) {
            Label("\(preview.reconnectCount) reconnect", systemImage: "link")
            Label("\(preview.needsAttentionCount) need attention", systemImage: "exclamationmark.triangle")
            Label("\(preview.stillMissingCount) still missing", systemImage: "questionmark.circle")
            Spacer()
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Color.appTextPrimary)
    }

    private func candidateList(_ preview: LocationRelink.Preview) -> some View {
        List {
            ForEach(preview.candidates) { candidate in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(for: candidate.kind))
                        .foregroundStyle(color(for: candidate.kind))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.relativePath.isEmpty ? candidate.oldPath : candidate.relativePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if case .needsAttention(let reason) = candidate.kind {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                        } else if case .stillMissing = candidate.kind {
                            Text(candidate.newPath)
                                .font(.caption)
                                .foregroundStyle(Color.appTextTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minHeight: 180)
    }

    private func icon(for kind: LocationRelink.MatchKind) -> String {
        switch kind {
        case .reconnect: return "checkmark.circle"
        case .needsAttention: return "exclamationmark.triangle"
        case .stillMissing: return "questionmark.circle"
        }
    }

    private func color(for kind: LocationRelink.MatchKind) -> Color {
        switch kind {
        case .reconnect: return .green
        case .needsAttention: return .orange
        case .stillMissing: return Color.appTextTertiary
        }
    }

    private func pickOldRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the old library folder location"
        panel.prompt = "Use as Old Location"
        if panel.runModal() == .OK, let url = panel.url {
            oldRoot = LocationRelink.normalizeRoot(url.path)
            recompute()
        }
    }

    private func pickNewRoot() {
        if let path = viewModel.pickNewLocationForRelink() {
            newRoot = path
            recompute()
        }
    }

    private func recompute() {
        guard !oldRoot.isEmpty, !newRoot.isEmpty else {
            preview = nil
            return
        }
        preview = viewModel.buildLocationRelinkPreview(oldRoot: oldRoot, newRoot: newRoot)
    }

    private func apply() async {
        guard let preview else { return }
        let count = await viewModel.applyLocationRelink(
            preview: preview,
            includeNeedsAttention: includeNeedsAttention
        )
        if count > 0 {
            appliedCount = count
        }
    }
}
