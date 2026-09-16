import SwiftUI
import AppKit

/// Step-by-step Location A → Location B remapping wizard.
///
/// 1. Old folder from catalog paths (never a vanished-folder filesystem picker)
/// 2. New folder via normal chooser (old folder stays visible) + match preview
/// 3. Confirm and **Repair**
///
/// Reads live from `viewModel.locationRelinkPresentation` so the sheet can open
/// immediately while the folder catalog finishes loading in the background.
struct LocationRelinkSheet: View {
    @Bindable var viewModel: LibraryViewModel

    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable {
        case oldFolder = 1
        case newFolder = 2
        case confirm = 3
        case done = 4

        var title: String {
            switch self {
            case .oldFolder: return "Old folder"
            case .newFolder: return "New folder"
            case .confirm: return "Repair"
            case .done: return "Done"
            }
        }
    }

    @State private var step: Step = .oldFolder
    @State private var oldRoot: String = ""
    @State private var newRoot: String = ""
    @State private var oldRootSearch: String = ""
    @State private var preview: LocationRelink.Preview?
    @State private var includeNeedsAttention = false
    @State private var appliedCount: Int = 0

    private var presentation: LibraryViewModel.LocationRelinkPresentation {
        viewModel.locationRelinkPresentation
            ?? LibraryViewModel.LocationRelinkPresentation(
                preferredOldRoot: nil,
                candidates: [],
                isLoadingCandidates: true,
                suggestedNewRoot: nil
            )
    }

    private var isApplying: Bool { viewModel.isApplyingLocationRelink }
    private var isLoadingCandidates: Bool { presentation.isLoadingCandidates }

    private var filteredOldRoots: [LocationRelink.OldRootCandidate] {
        let q = oldRootSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return presentation.candidates }
        return presentation.candidates.filter {
            $0.path.localizedCaseInsensitiveContains(q)
                || $0.subtitle.localizedCaseInsensitiveContains(q)
        }
    }

    private var selectedOldCandidate: LocationRelink.OldRootCandidate? {
        presentation.candidates.first {
            $0.path.caseInsensitiveCompare(oldRoot) == .orderedSame
        }
    }

    private var reconnectableCount: Int {
        guard let preview else { return 0 }
        return preview.reconnectCount + (includeNeedsAttention ? preview.needsAttentionCount : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Repair Links")
                .font(.title2.weight(.semibold))

            if step != .done {
                stepIndicator
            }

            Group {
                switch step {
                case .oldFolder:
                    oldFolderStep
                case .newFolder:
                    newFolderStep
                case .confirm:
                    confirmStep
                case .done:
                    doneStep
                }
            }

            Spacer(minLength: 0)

            footerButtons
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 540)
        .onAppear {
            applyPreferredSelectionIfNeeded()
            if let suggested = presentation.suggestedNewRoot {
                newRoot = suggested
                recomputePreview()
            }
        }
        .onChange(of: presentation.isLoadingCandidates) { _, loading in
            if !loading {
                applyPreferredSelectionIfNeeded()
            }
        }
        .onChange(of: presentation.candidates.count) { _, _ in
            applyPreferredSelectionIfNeeded()
        }
        .onChange(of: presentation.preferredOldRoot) { _, _ in
            applyPreferredSelectionIfNeeded()
        }
    }

    private func applyPreferredSelectionIfNeeded() {
        guard !isLoadingCandidates else { return }
        if let preferred = presentation.preferredOldRoot, !preferred.isEmpty,
           presentation.candidates.contains(where: { $0.path.caseInsensitiveCompare(preferred) == .orderedSame })
        {
            oldRoot = preferred
        } else if oldRoot.isEmpty || !presentation.candidates.contains(where: {
            $0.path.caseInsensitiveCompare(oldRoot) == .orderedSame
        }) {
            oldRoot = presentation.candidates.first?.path ?? ""
        }
    }

    // MARK: - Step indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach([Step.oldFolder, .newFolder, .confirm], id: \.rawValue) { s in
                if s.rawValue > 1 {
                    Rectangle()
                        .fill(step.rawValue >= s.rawValue ? Color.appAccent : Color.appTextTertiary.opacity(0.35))
                        .frame(height: 2)
                        .frame(maxWidth: 28)
                        .padding(.horizontal, 6)
                }
                stepChip(s)
            }
            Spacer(minLength: 0)
        }
    }

    private func stepChip(_ s: Step) -> some View {
        let active = step == s
        let completed = step.rawValue > s.rawValue
        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(active || completed ? Color.appAccent : Color.appTextTertiary.opacity(0.25))
                    .frame(width: 22, height: 22)
                if completed {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(s.rawValue)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(active || completed ? .white : Color.appTextSecondary)
                }
            }
            Text(s.title)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Color.appTextPrimary : Color.appTextSecondary)
        }
    }

    // MARK: - Step 1: Old folder

    private var oldFolderStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose the old folder")
                .font(.headline)
            Text("Pick the location your library still points at. These come from your catalog and data sources — not from browsing a folder that may no longer exist.")
                .font(.callout)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoadingCandidates {
                buildingFolderListPlaceholder
                    .frame(minHeight: 240, maxHeight: .infinity)
            } else {
                if presentation.candidates.count > 8 {
                    TextField("Search folders…", text: $oldRootSearch)
                        .textFieldStyle(.roundedBorder)
                }
                oldRootList
                    .frame(minHeight: 240, maxHeight: .infinity)
            }
        }
    }

    private var buildingFolderListPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Building folder list…")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.appTextPrimary)
            ProgressView()
                .progressViewStyle(.linear)
            Text("Scanning library folders — Continue unlocks when this finishes.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Building folder list")
    }

    private var oldRootList: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(
                get: { oldRoot.isEmpty ? nil : oldRoot },
                set: { oldRoot = $0 ?? "" }
            )) {
                if filteredOldRoots.isEmpty {
                    Text(oldRootSearch.isEmpty ? "No known library folders." : "No folders match “\(oldRootSearch)”.")
                        .foregroundStyle(Color.appTextSecondary)
                } else {
                    ForEach(filteredOldRoots) { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.path)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .fontWeight(
                                    candidate.path.caseInsensitiveCompare(oldRoot) == .orderedSame
                                        ? .semibold : .regular
                                )
                            Text(candidate.subtitle)
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                        .tag(candidate.path)
                        .id(candidate.path)
                        .padding(.vertical, 2)
                        .listRowBackground(
                            candidate.path.caseInsensitiveCompare(oldRoot) == .orderedSame
                                ? Color.appAccent.opacity(0.14)
                                : Color.clear
                        )
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .disabled(isApplying)
            .onAppear {
                scrollSelectedOldRootIntoView(using: proxy)
            }
            .onChange(of: oldRoot) { _, _ in
                scrollSelectedOldRootIntoView(using: proxy)
            }
            .onChange(of: oldRootSearch) { _, _ in
                scrollSelectedOldRootIntoView(using: proxy)
            }
            .onChange(of: presentation.candidates.count) { _, _ in
                scrollSelectedOldRootIntoView(using: proxy)
            }
        }
    }

    private func scrollSelectedOldRootIntoView(using proxy: ScrollViewProxy) {
        guard !oldRoot.isEmpty, !isLoadingCandidates else { return }
        // List may not have laid out the pre-selected row yet — retry briefly.
        let target = oldRoot
        let delays: [TimeInterval] = [0, 0.05, 0.15, 0.35]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(delay == 0 ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    // MARK: - Step 2: New folder

    private var newFolderStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose the new folder")
                .font(.headline)
            Text("Select the folder on disk that replaces the old location. Relative paths under it should match.")
                .font(.callout)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            labeledPathCard(
                label: "Remapping from",
                path: oldRoot,
                detail: selectedOldCandidate.map { "\($0.videoCount) clip\($0.videoCount == 1 ? "" : "s") in catalog" }
            )

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New folder")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                    Text(newRoot.isEmpty ? "No folder selected yet" : newRoot)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(newRoot.isEmpty ? Color.appTextTertiary : Color.appTextPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(newRoot.isEmpty ? "Choose Folder…" : "Change…") {
                    pickNewRoot()
                }
                .disabled(isApplying)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.appTextSecondary.opacity(0.08))
            )

            if let preview {
                summaryRow(preview)
                candidateList(preview)
                    .frame(minHeight: 140, maxHeight: .infinity)

                if preview.needsAttentionCount > 0 {
                    Toggle("Include flagged matches (size mismatch or path collision)", isOn: $includeNeedsAttention)
                }
            } else if !newRoot.isEmpty {
                Text("No clips under the old folder to rematch.")
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
    }

    // MARK: - Step 3: Confirm / Repair

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isApplying ? "Repairing…" : "Confirm repair")
                .font(.headline)
            Text("This updates library paths only — files stay where they are. Ratings, collections, and tags are kept. You can undo afterward.")
                .font(.callout)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            labeledPathCard(label: "Old folder", path: oldRoot, detail: nil)
            Image(systemName: "arrow.down")
                .foregroundStyle(Color.appTextSecondary)
                .frame(maxWidth: .infinity)
            labeledPathCard(label: "New folder", path: newRoot, detail: nil)

            if let preview {
                summaryRow(preview)
                if includeNeedsAttention && preview.needsAttentionCount > 0 {
                    Text("Flagged matches will be included.")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }

            if isApplying {
                relinkProgressSection
            } else {
                Text("\(reconnectableCount) clip\(reconnectableCount == 1 ? "" : "s") will be repaired.")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private var relinkProgressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = viewModel.locationRelinkProgress {
                if progress.total > 0 {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(progress.statusText)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .monospacedDigit()
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Repairing…")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        .padding(.top, 4)
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "Repaired \(appliedCount) clip\(appliedCount == 1 ? "" : "s").",
                systemImage: "checkmark.circle.fill"
            )
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.appTextPrimary)

            Text("Use Edit → Undo Repair Links if you need to reverse this.")
                .foregroundStyle(Color.appTextSecondary)

            labeledPathCard(label: "From", path: oldRoot, detail: nil)
            labeledPathCard(label: "To", path: newRoot, detail: nil)
        }
    }

    // MARK: - Shared pieces

    private func labeledPathCard(label: String, path: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appTextSecondary)
            Text(path)
                .lineLimit(3)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.appTextSecondary.opacity(0.08))
        )
    }

    private func summaryRow(_ preview: LocationRelink.Preview) -> some View {
        HStack(spacing: 16) {
            Label("\(preview.reconnectCount) ready", systemImage: "link")
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

    // MARK: - Footer

    private var footerButtons: some View {
        HStack {
            switch step {
            case .oldFolder:
                Button("Cancel") {
                    viewModel.locationRelinkPresentation = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isApplying)
                Spacer()
                Button("Continue") {
                    newRoot = ""
                    preview = nil
                    includeNeedsAttention = false
                    step = .newFolder
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoadingCandidates || oldRoot.isEmpty)

            case .newFolder:
                Button("Back") {
                    step = .oldFolder
                }
                .disabled(isApplying)
                Spacer()
                Button("Continue") {
                    step = .confirm
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newRoot.isEmpty || reconnectableCount == 0 || isApplying)

            case .confirm:
                Button("Back") {
                    step = .newFolder
                }
                .disabled(isApplying)
                Spacer()
                Button("Repair") {
                    Task { await runRelink() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reconnectableCount == 0 || isApplying)

            case .done:
                Spacer()
                Button("Done") {
                    viewModel.locationRelinkPresentation = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Actions

    private func pickNewRoot() {
        if let path = viewModel.pickNewLocationForRelink() {
            newRoot = path
            recomputePreview()
        }
    }

    private func recomputePreview() {
        guard !oldRoot.isEmpty, !newRoot.isEmpty else {
            preview = nil
            return
        }
        preview = viewModel.buildLocationRelinkPreview(oldRoot: oldRoot, newRoot: newRoot)
    }

    private func runRelink() async {
        guard let preview else { return }
        let count = await viewModel.applyLocationRelink(
            preview: preview,
            includeNeedsAttention: includeNeedsAttention
        )
        if count > 0 {
            appliedCount = count
            step = .done
        }
    }
}
