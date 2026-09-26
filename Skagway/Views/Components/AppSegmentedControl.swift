import SwiftUI

/// A custom segmented control styled for the Cinematic Blue design system.
/// Provides a sliding pill selection indicator with glass/surface treatment
/// instead of the stock segmented picker.
struct AppSegmentedControl<Selection: Hashable>: View {
    @Binding var selection: Selection
    let items: [Selection]
    private let makeLabel: (Selection) -> AnyView
    private let makeTooltip: ((Selection) -> String)?

    @Namespace private var namespace

    init<Label: View>(
        selection: Binding<Selection>,
        items: [Selection],
        tooltip: ((Selection) -> String)? = nil,
        @ViewBuilder label: @escaping (Selection) -> Label
    ) {
        self._selection = selection
        self.items = items
        self.makeTooltip = tooltip
        self.makeLabel = { AnyView(label($0)) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let isSelected = selection == item

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        selection = item
                    }
                } label: {
                    makeLabel(item)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextSecondary)
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, 3)
                        // On macOS, .plain buttons hit-test against the label's rendered content
                        // (icon/text glyphs), not the full frame — without this, the gap between an
                        // icon and its text (e.g. "List"/"Grid") is a dead zone. Must be applied to
                        // the label content itself; applying it only outside .buttonStyle below is
                        // not sufficient.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                .fill(Color.appAccent.opacity(0.20))
                                .matchedGeometryEffect(id: "selectionPill", in: namespace)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                        .stroke(Color.appAccent.opacity(0.45), lineWidth: 1)
                                )
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                .help(makeTooltip?(item) ?? "")
            }
        }
        .modifier(SegmentedBarChrome())
    }
}

/// Glass bar shared by the view switcher and the sort control so they read as one pair.
struct SegmentedBarChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(3)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(Material.appSubtleGlass)
                    .background(Color.appSurface.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }
}

/// Grid / List / Storyboard. Storyboard is a split button: the label uses the remembered
/// density, and the arrow picks Normal or Compact. The arrow is always present so the bar
/// width (and the Sort control beside it) does not change with the view.
struct LibraryViewModeSwitch: View {
    var viewMode: ViewMode
    var storyboardDensity: StoryboardDensity
    var onSelectMode: (ViewMode) -> Void
    var onSelectDensity: (StoryboardDensity) -> Void

    @Namespace private var namespace

    private let spring = Animation.spring(response: 0.28, dampingFraction: 0.78)

    var body: some View {
        HStack(spacing: 2) {
            modeButton(.grid, title: "Grid", systemImage: "square.grid.2x2", help: "Grid view (⌘1)")
            modeButton(.list, title: "List", systemImage: "list.bullet", help: "List view (⌘2)")
            storyboardSegment
        }
        .modifier(SegmentedBarChrome())
    }

    private func modeButton(_ mode: ViewMode, title: String, systemImage: String, help: String) -> some View {
        let isSelected = viewMode == mode
        return Button {
            guard viewMode != mode else { return }
            withAnimation(spring) { onSelectMode(mode) }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextSecondary)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { selectionPill(isSelected) }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
        .help(help)
    }

    private var storyboardSegment: some View {
        let isSelected = viewMode == .storyboard
        return HStack(spacing: 0) {
            Button {
                guard viewMode != .storyboard else { return }
                withAnimation(spring) { onSelectMode(.storyboard) }
            } label: {
                Label("Storyboard", systemImage: "square.grid.3x2")
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextSecondary)
                    .padding(.leading, AppSpacing.sm)
                    .padding(.trailing, 4)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Storyboard view (⌘3)")

            Rectangle()
                .fill(Color.appTextSecondary.opacity(0.35))
                .frame(width: 1, height: 14)

            Menu {
                ForEach(StoryboardDensity.allCases) { density in
                    Button {
                        withAnimation(spring) { onSelectDensity(density) }
                    } label: {
                        if density == storyboardDensity {
                            Label(density.label, systemImage: "checkmark")
                        } else {
                            Text(density.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.appTextPrimary : Color.appTextSecondary)
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Storyboard density — Normal or Compact")
            .accessibilityLabel("Storyboard density")
        }
        .background { selectionPill(isSelected) }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
    }

    @ViewBuilder
    private func selectionPill(_ isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                .fill(Color.appAccent.opacity(0.20))
                .matchedGeometryEffect(id: "selectionPill", in: namespace)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                        .stroke(Color.appAccent.opacity(0.45), lineWidth: 1)
                )
        }
    }
}
