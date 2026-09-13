import SwiftUI

/// Very lightweight removable pill row shown under the header when the Curated Wall filters drawer is closed
/// but some filters (smart lib / collection / tags / rating / duration) are active.
/// Matches the refined, low-chrome aesthetic of the wall.
struct ActiveFilterPills: View {
    @Bindable var viewModel: LibraryViewModel

    var body: some View {
        if viewModel.hasActiveFilters {
            HStack(spacing: 6) {
                // Scrollable pills only — "Clear all" lives outside this ScrollView (below) so it
                // stays reachable even when there are enough pills to overflow the visible width,
                // instead of scrolling out of view as just another trailing item.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        // Sidebar / smart filter pill
                        if let f = viewModel.sidebarFilter, f != .all {
                            sidebarFilterPill(for: f)
                        }

                        // Rating
                        if let rating = viewModel.selectedRatingStars.min() {
                            let text: String = {
                                if rating == 0 { return "No stars" }
                                if viewModel.ratingFilterOrHigher, rating < 5 { return "Rating \(rating)+" }
                                return "Rating \(rating)"
                            }()
                            pill(text: text, systemImage: rating == 0 ? "star.slash" : "star", onRemove: {
                                viewModel.clearRatingFilter()
                            })
                        }

                        // Tags
                        if !viewModel.selectedTagIds.isEmpty {
                            let count = viewModel.selectedTagIds.count
                            pill(text: count == 1 ? "1 tag" : "\(count) tags", systemImage: "tag", onRemove: {
                                viewModel.clearTagFilters()
                            })
                        }

                        // Duration
                        if viewModel.minDurationSeconds != nil || viewModel.maxDurationSeconds != nil {
                            let txt: String = {
                                if let mn = viewModel.minDurationSeconds, let mx = viewModel.maxDurationSeconds {
                                    return "\(Int(mn/60))–\(Int(mx/60)) min"
                                } else if let mn = viewModel.minDurationSeconds {
                                    return "≥\(Int(mn/60)) min"
                                } else if let mx = viewModel.maxDurationSeconds {
                                    return "≤\(Int(mx/60)) min"
                                }
                                return "Duration"
                            }()
                            pill(text: txt, systemImage: "clock", onRemove: {
                                viewModel.clearDurationFilter()
                            })
                        }

                        // Quality
                        if !viewModel.selectedQualityBuckets.isEmpty {
                            let ordered = ResolutionBucket.allCases
                                .map(\.rawValue)
                                .filter { viewModel.selectedQualityBuckets.contains($0) }
                            pill(text: "Quality: " + ordered.joined(separator: ", "), systemImage: "rectangle.and.arrow.up.right.and.arrow.down.left", onRemove: {
                                viewModel.clearQualityFilter()
                            })
                        }

                        // Advanced Filter — one summary pill, not per-condition.
                        if let summary = viewModel.activeAdvancedFilterSummary {
                            pill(
                                text: summary.count > 48 ? "Advanced Filter" : summary,
                                systemImage: "slider.horizontal.3",
                                onTap: { viewModel.openFiltersDrawer(mode: .advanced) },
                                onRemove: { viewModel.clearAdvancedFilter() }
                            )
                        }
                    }
                }

                Button("Clear all") {
                    viewModel.resetAllFilters()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.appAccent)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.appSurface.opacity(0.4))
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func sidebarFilterPill(for filter: SidebarFilter) -> some View {
        if case .collection(let collection) = filter, collection.isSmart {
            pill(
                text: sidebarPillText(for: filter),
                systemImage: icon(for: filter),
                onTap: { viewModel.previewCollectionInAdvancedFilter(collection) },
                onRemove: { viewModel.sidebarFilter = .all }
            )
        } else {
            pill(
                text: sidebarPillText(for: filter),
                systemImage: icon(for: filter),
                onRemove: { viewModel.sidebarFilter = .all }
            )
        }
    }

    private func pill(
        text: String,
        systemImage: String,
        onTap: (() -> Void)? = nil,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Button {
                if let onTap { onTap() } else { onRemove() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: systemImage)
                        .font(.caption)
                    Text(text)
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appTextPrimary)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove filter")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.appAccent.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(Color.appAccent.opacity(0.25), lineWidth: 1)
        )
    }

    private func sidebarPillText(for filter: SidebarFilter) -> String {
        if case .collection(let collection) = filter, collection.isSmart,
           let label = viewModel.collectionFilterPillLabel(for: collection) {
            return label
        }
        return pillText(for: filter)
    }

    private func pillText(for filter: SidebarFilter) -> String {
        switch filter {
        case .all: return "All"
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        case .topRated: return "Top Rated"
        case .duplicates: return "Duplicates"
        case .corrupt: return "Corrupt"
        case .missing: return "Missing"
        case .recentlyConverted: return "Recently Converted"
        case .recentlyApplied: return "Last Metadata Import"
        case .lastAdded: return "Last Added"
        case .collection(let c): return c.name
        }
    }

    private func icon(for filter: SidebarFilter) -> String {
        switch filter {
        case .all: return "film.stack"
        case .recentlyAdded: return "clock"
        case .recentlyPlayed: return "play.circle"
        case .topRated: return "star.fill"
        case .duplicates: return "doc.on.doc"
        case .corrupt: return "exclamationmark.triangle"
        case .missing: return "questionmark.circle"
        case .recentlyConverted: return "arrow.triangle.2.circlepath"
        case .recentlyApplied: return "square.and.arrow.down.on.square"
        case .lastAdded: return "plus.rectangle.on.folder"
        case .collection(let c): return c.isAlbum ? "rectangle.stack" : "folder"
        }
    }
}