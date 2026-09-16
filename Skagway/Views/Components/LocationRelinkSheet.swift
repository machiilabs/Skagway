import SwiftUI
import AppKit

/// Preview + Apply sheet for whole-tree Location A → Location B remapping.
///
/// Old location is chosen from known catalog/data-source paths (never a filesystem picker —
/// that folder usually no longer exists). New location still uses a normal folder picker.
struct LocationRelinkSheet: View {
    @Bindable var viewModel: LibraryViewModel
    let presentation: LibraryViewModel.LocationRelinkPresentation

    @Environment(\.dismiss) private var dismiss

    @State private var oldRoot: String = ""
    @State private var newRoot: String = ""
    @State private var oldRootSearch: String = ""
    @State private var preview: LocationRelink.Preview?
    @State private var includeNeedsAttention = false
    @State private var appliedCount: Int?

    private var isApplying: Bool { viewModel.isApplyingLocationRelink }

    private var filteredOldRoots: [LocationRelink.OldRootCandidate] {
        let q = oldRootSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return presentation.candidates }
        return presentation.candidates.filter {
            $0.path.localizedCaseInsensitiveContains(q)
                || $0.subtitle.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Relink Location")
                .font(.title2.weight(.semibold))

            Text("Choose the old folder from paths already in your library, then pick the new folder on disk. Relative paths stay the same — ratings, collections, and tags stay put.")
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let appliedCount {
                resultsPane(appliedCount)
            } else {
                planningPane
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 520)
        .onAppear {
            if let preferred = presentation.preferredOldRoot, !preferred.isEmpty {
                oldRoot = preferred
            } else {
                oldRoot = presentation.candidates.first?.path ?? ""
            }
            if let suggested = presentation.suggestedNewRoot {
                newRoot = suggested
            }
            recompute()
        }
    }

    private var planningPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Old location")
                .font(.headline)

            Text("From your library catalog — not from browsing the disk.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)

            if presentation.candidates.count > 8 {
                TextField("Search folders…", text: $oldRootSearch)
                    .textFieldStyle(.roundedBorder)
            }

            oldRootList
                .frame(minHeight: 160, maxHeight: 220)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("New location")
                    .frame(width: 100, alignment: .leading)
                    .foregroundStyle(Color.appTextSecondary)
                Text(newRoot.isEmpty ? "Choose a folder…" : newRoot)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…") { pickNewRoot() }
                    .disabled(isApplying || oldRoot.isEmpty)
            }

            if let preview {
                summaryRow(preview)

                Toggle("Include flagged matches (size mismatch or path collision)", isOn: $includeNeedsAttention)
                    .disabled(preview.needsAttentionCount == 0)

                candidateList(preview)
            } else if !oldRoot.isEmpty, !newRoot.isEmpty {
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

    private var oldRootList: some View {
        List(selection: Binding(
            get: { oldRoot.isEmpty ? nil : oldRoot },
            set: { newValue in
                oldRoot = newValue ?? ""
                recompute()
            }
        )) {
            if filteredOldRoots.isEmpty {
                Text(oldRootSearch.isEmpty ? "No known library folders." : "No folders match “\(oldRootSearch)”.")
                    .foregroundStyle(Color.appTextSecondary)
                    .tag("")
            } else {
                ForEach(filteredOldRoots) { candidate in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.path)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(candidate.subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    .tag(candidate.path)
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .disabled(isApplying)
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
        return n == 0 || newRoot.isEmpty || oldRoot.isEmpty
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
        .frame(minHeight: 140)
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
