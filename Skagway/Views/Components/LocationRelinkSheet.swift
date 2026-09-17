import SwiftUI
import AppKit

/// Unified **Reconnect** sheet — Evidence Destinations only.
/// Banner and File → Reconnect… open the same product: add folders → match → preview → Apply → Undo.
struct LocationRelinkSheet: View {
    @Bindable var viewModel: LibraryViewModel

    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case destinations
        case confirm
        case done
    }

    @State private var step: Step = .destinations
    @State private var preview: LocationRelink.Preview?
    @State private var includeNeedsAttention = false
    @State private var appliedCount: Int = 0
    @State private var destinationIndexes: [LocationRelink.DestinationIndex] = []
    @State private var isIndexingDestination = false

    private var isApplying: Bool { viewModel.isApplyingLocationRelink }

    private var reconnectableCount: Int {
        guard let preview else { return 0 }
        return preview.reconnectCount + (includeNeedsAttention ? preview.needsAttentionCount : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reconnect")
                .font(.title2.weight(.semibold))

            Group {
                switch step {
                case .destinations:
                    destinationsBody
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
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            recomputePreview()
        }
        .onChange(of: viewModel.reconnectMissingClipCount) { _, _ in
            recomputePreview()
        }
    }

    // MARK: - Destinations

    private var destinationsBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add folders where missing clips landed. Skagway matches by filename (and soft size) only under folders you choose — nothing is rewritten until you confirm.")
                .font(.callout)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            sessionSummaryCards

            HStack {
                Button {
                    addEvidenceDestination()
                } label: {
                    Label("Add destination…", systemImage: "folder.badge.plus")
                }
                .disabled(isApplying || isIndexingDestination)

                if isIndexingDestination {
                    ProgressView()
                        .controlSize(.small)
                    Text("Indexing…")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
                Spacer()
            }

            if !destinationIndexes.isEmpty {
                destinationsList
            }

            if let preview {
                evidenceGroupedList(preview)
                    .frame(minHeight: 160, maxHeight: .infinity)

                if preview.needsAttentionCount > 0 {
                    Toggle(
                        "Include flagged matches (size mismatch, collisions, or ambiguous names)",
                        isOn: $includeNeedsAttention
                    )
                }
            } else if destinationIndexes.isEmpty {
                Text("No destinations yet — add at least one folder that contains moved clips.")
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
    }

    /// Session totals: Ready / Needs attention / Unmatched (replaces the old missing-filename box).
    private var sessionSummaryCards: some View {
        let ready = preview?.reconnectCount ?? 0
        let attention = preview?.needsAttentionCount ?? 0
        let unmatched = preview?.stillMissingCount ?? viewModel.reconnectMissingClipCount
        return HStack(spacing: 10) {
            summaryCard(
                title: "\(ready) ready",
                systemImage: "link",
                accent: .green
            )
            summaryCard(
                title: "\(attention) need attention",
                systemImage: "exclamationmark.triangle",
                accent: .orange
            )
            summaryCard(
                title: "\(unmatched) unmatched",
                systemImage: "questionmark.circle",
                accent: Color.appTextSecondary
            )
        }
    }

    private func summaryCard(title: String, systemImage: String, accent: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(accent)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.appTextSecondary.opacity(0.08))
        )
    }

    private var destinationsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(destinationIndexes, id: \.root) { index in
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.appTextSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(index.root)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(index.fileCount) video file\(index.fileCount == 1 ? "" : "s") indexed")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        destinationIndexes.removeAll {
                            $0.root.caseInsensitiveCompare(index.root) == .orderedSame
                        }
                        recomputePreview()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(isApplying)
                }
            }
        }
    }

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isApplying ? "Reconnecting…" : "Confirm reconnect")
                .font(.headline)
            Text("This updates library paths only — files stay where they are. Ratings, collections, and tags are kept. You can undo afterward.")
                .font(.callout)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            sessionSummaryCards

            if includeNeedsAttention, let preview, preview.needsAttentionCount > 0 {
                Text("Flagged matches will be included.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            if isApplying {
                relinkProgressSection
            } else {
                Text("\(reconnectableCount) clip\(reconnectableCount == 1 ? "" : "s") will be reconnected.")
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
                Text("Reconnecting…")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        .padding(.top, 4)
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "Reconnected \(appliedCount) clip\(appliedCount == 1 ? "" : "s").",
                systemImage: "checkmark.circle.fill"
            )
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.appTextPrimary)

            Text("Use Edit → Undo Reconnect if you need to reverse this.")
                .foregroundStyle(Color.appTextSecondary)

            if !destinationIndexes.isEmpty {
                Text("Destinations: \(destinationIndexes.map(\.root).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(3)
            }
        }
    }

    private func evidenceGroupedList(_ preview: LocationRelink.Preview) -> some View {
        let grouped = LocationRelink.groupEvidenceCandidates(preview.candidates)
        return List {
            ForEach(grouped.byDestination, id: \.destination) { group in
                Section {
                    ForEach(group.ready) { candidate in
                        candidateRow(candidate)
                    }
                    ForEach(group.needsAttention) { candidate in
                        candidateRow(candidate)
                    }
                } header: {
                    Text("\(group.ready.count) Ready · \(group.needsAttention.count) Needs attention under \(group.destination)")
                        .font(.caption)
                        .lineLimit(2)
                }
            }
            if !grouped.unmatched.isEmpty {
                Section("Unmatched (\(grouped.unmatched.count))") {
                    ForEach(grouped.unmatched) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func candidateRow(_ candidate: LocationRelink.Candidate) -> some View {
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
                    Text(candidate.oldPath)
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if candidate.kind == .reconnect {
                    Text(candidate.newPath)
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
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
            case .destinations:
                Button("Cancel") {
                    viewModel.locationRelinkPresentation = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isApplying)
                Spacer()
                Button("Continue") {
                    step = .confirm
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reconnectableCount == 0 || isApplying || isIndexingDestination)

            case .confirm:
                Button("Back") {
                    step = .destinations
                }
                .disabled(isApplying)
                Spacer()
                Button("Reconnect") {
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

    private func addEvidenceDestination() {
        guard let path = viewModel.pickEvidenceDestination() else { return }
        if destinationIndexes.contains(where: { $0.root.caseInsensitiveCompare(path) == .orderedSame }) {
            recomputePreview()
            return
        }
        isIndexingDestination = true
        Task {
            let index = await viewModel.indexEvidenceDestination(at: path)
            destinationIndexes.append(index)
            isIndexingDestination = false
            recomputePreview()
        }
    }

    private func recomputePreview() {
        preview = viewModel.buildReconnectSessionPreview(
            wholeFolder: nil,
            destinationIndexes: destinationIndexes
        )
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
