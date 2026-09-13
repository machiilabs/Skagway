import SwiftUI

/// Live Advanced Filter boolean editor. Edits a working `FilterGroup` with the same two-level
/// ALL/ANY + type-aware value controls as the Collections editor, writing through `group` on every
/// change so the library filter updates live. Incomplete rules are omitted from the published
/// group (so mid-typing doesn't match incorrectly); an empty tree publishes `nil`.
struct AdvancedFilterRulesEditor: View {
    @Binding var group: FilterGroup?
    var customFields: [CustomMetadataFieldDefinition] = []
    var tags: [Tag] = []

    @State private var outerMatchMode: MatchMode = .all
    @State private var groups: [EditableGroup] = [EditableGroup()]
    /// Suppresses publish→load feedback when we just wrote `group` ourselves.
    @State private var isPublishing = false

    struct EditableRule: Identifiable, Equatable {
        let id: UUID
        var field: FilterField
        var comparison: RuleComparison
        var value: String
        var value2: String

        init(
            id: UUID = UUID(),
            field: FilterField = .builtin(.name),
            comparison: RuleComparison = .contains,
            value: String = "",
            value2: String = ""
        ) {
            self.id = id
            self.field = field
            self.comparison = comparison
            self.value = value
            self.value2 = value2
        }
    }

    struct EditableGroup: Identifiable, Equatable {
        let id: UUID
        var matchMode: MatchMode
        var rules: [EditableRule]

        init(id: UUID = UUID(), matchMode: MatchMode = .all, rules: [EditableRule] = [EditableRule()]) {
            self.id = id
            self.matchMode = matchMode
            self.rules = rules
        }
    }

    private var customFieldsById: [UUID: CustomMetadataFieldDefinition] {
        Dictionary(uniqueKeysWithValues: customFields.map { ($0.id, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text("Match")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)

                modeToggle($outerMatchMode)

                Text("of the following groups:")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)

                Spacer(minLength: 0)
            }

            VStack(spacing: 10) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, _ in
                    groupCard(groupIndex: groupIndex)
                }
            }

            HStack(spacing: 16) {
                Button(action: addGroup) {
                    Label("Add group", systemImage: "plus.circle.fill")
                        .font(.caption)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appAccent)

                Spacer(minLength: 0)

                if group != nil {
                    Button("Reset") {
                        resetEditor()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .help("Clear Advanced Filter")
                }
            }
        }
        .onAppear { loadFromBinding() }
        .onChange(of: group) { _, newValue in
            guard !isPublishing else { return }
            // External clear (Clear all / pill ✕) resets the editor.
            if newValue == nil || newValue?.isEmpty == true {
                resetEditor(publish: false)
            }
        }
        .onChange(of: outerMatchMode) { _, _ in publish() }
        .onChange(of: groups) { _, _ in publish() }
    }

    // MARK: - Group card

    private func groupCard(groupIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Match")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)

                modeToggle($groups[groupIndex].matchMode)

                Text("of the following:")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)

                Spacer()

                Button(action: { removeGroup(at: groupIndex) }) {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.appTextSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(groups.count <= 1)
                .help("Remove group")
            }

            VStack(spacing: 6) {
                ForEach(Array(groups[groupIndex].rules.enumerated()), id: \.element.id) { ruleIndex, _ in
                    ruleRow(groupIndex: groupIndex, ruleIndex: ruleIndex)
                }
            }

            Button(action: { addRule(toGroup: groupIndex) }) {
                Label("Add condition", systemImage: "plus")
                    .font(.caption)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appAccent)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.appSurface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.appDivider, lineWidth: 1)
        )
    }

    private func modeToggle(_ mode: Binding<MatchMode>) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                mode.wrappedValue = mode.wrappedValue == .all ? .any : .all
            }
        }) {
            Text(mode.wrappedValue == .all ? "ALL" : "ANY")
                .font(.callout)
                .fontWeight(.bold)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(mode.wrappedValue == .all ? Color.appAccent : Color.orange)
                )
                .foregroundColor(.white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rule row

    private func ruleRow(groupIndex: Int, ruleIndex: Int) -> some View {
        let rule = $groups[groupIndex].rules[ruleIndex]
        let fields = customFieldsById
        return HStack(spacing: 8) {
            Picker("Attribute", selection: rule.field) {
                ForEach(RuleAttribute.allCases) { attr in
                    Text(attr.label).tag(FilterField.builtin(attr))
                }
                if !customFields.isEmpty {
                    Section("Custom Fields") {
                        ForEach(customFields) { def in
                            Text(def.name).tag(FilterField.custom(def.id))
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(minWidth: 120, idealWidth: 140, maxWidth: 160)
            .onChange(of: rule.wrappedValue.field) { _, newField in
                let supported = newField.supportedComparisons(customFields: fields)
                if !supported.contains(rule.wrappedValue.comparison) {
                    rule.wrappedValue.comparison = supported.first ?? .equals
                }
                if rule.wrappedValue.comparison.usesValue && rule.wrappedValue.value.isEmpty {
                    prefillDefault(rule.value, kind: newField.kind(customFields: fields))
                }
            }

            Picker("Comparison", selection: rule.comparison) {
                ForEach(rule.wrappedValue.field.supportedComparisons(customFields: fields)) { comp in
                    Text(comp.label).tag(comp)
                }
            }
            .labelsHidden()
            .frame(minWidth: 120, idealWidth: 140, maxWidth: 160)
            .onChange(of: rule.wrappedValue.comparison) { _, newComp in
                if !newComp.usesValue {
                    rule.wrappedValue.value = ""
                    rule.wrappedValue.value2 = ""
                } else if newComp.usesSecondValue && rule.wrappedValue.value2.isEmpty {
                    prefillDefault(rule.value2, kind: rule.wrappedValue.field.kind(customFields: fields))
                } else if rule.wrappedValue.value.isEmpty {
                    prefillDefault(rule.value, kind: rule.wrappedValue.field.kind(customFields: fields))
                }
            }

            if rule.wrappedValue.comparison.usesValue {
                ruleValueEditor(rule, fields: fields)
            }

            Spacer(minLength: 0)

            Button(action: { removeRule(at: ruleIndex, inGroup: groupIndex) }) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(groups[groupIndex].rules.count <= 1)
            .help("Remove condition")
        }
    }

    @ViewBuilder
    private func ruleValueEditor(
        _ rule: Binding<EditableRule>,
        fields: [UUID: CustomMetadataFieldDefinition]
    ) -> some View {
        let kind = rule.wrappedValue.field.kind(customFields: fields)
        let isBetween = rule.wrappedValue.comparison.usesSecondValue
        switch kind {
        case .rating:
            HStack(spacing: 6) {
                starRating(rule.value)
                if isBetween {
                    Text("to").foregroundStyle(Color.appTextSecondary)
                    starRating(rule.value2)
                }
            }
        case .date:
            HStack(spacing: 6) {
                DatePicker("", selection: dateBinding(rule.value), displayedComponents: [.date])
                    .labelsHidden()
                if isBetween {
                    Text("to").foregroundStyle(Color.appTextSecondary)
                    DatePicker("", selection: dateBinding(rule.value2), displayedComponents: [.date])
                        .labelsHidden()
                }
            }
        case .tag:
            HStack(spacing: 6) {
                TextField("Tag name", text: rule.value)
                    .textFieldStyle(.roundedBorder)
                if !tags.isEmpty {
                    Menu {
                        ForEach(tags) { tag in
                            Button(tag.name) { rule.wrappedValue.value = tag.name }
                        }
                    } label: {
                        Image(systemName: "tag")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        case .quality:
            qualityChips(rule.value)
        case .boolean:
            Picker("", selection: rule.value) {
                Text("True").tag("true")
                Text("False").tag("false")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 160)
            .onAppear {
                if CustomMetadataValueType.normalizeBooleanStorage(rule.wrappedValue.value) == nil {
                    rule.wrappedValue.value = "true"
                } else if let canon = CustomMetadataValueType.normalizeBooleanStorage(rule.wrappedValue.value) {
                    rule.wrappedValue.value = canon
                }
            }
        case .number:
            HStack(spacing: 6) {
                TextField(rule.wrappedValue.field.valuePlaceholder(customFields: fields), text: rule.value)
                    .textFieldStyle(.roundedBorder)
                if isBetween {
                    Text("and").foregroundStyle(Color.appTextSecondary)
                    TextField(rule.wrappedValue.field.valuePlaceholder(customFields: fields), text: rule.value2)
                        .textFieldStyle(.roundedBorder)
                }
            }
        case .string:
            TextField(rule.wrappedValue.field.valuePlaceholder(customFields: fields), text: rule.value)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func starRating(_ value: Binding<String>) -> some View {
        let current = Int(value.wrappedValue) ?? 0
        return HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= current ? "star.fill" : "star")
                    .foregroundStyle(star <= current ? .yellow : Color.appTextTertiary)
                    .onTapGesture { value.wrappedValue = String(star == current ? 0 : star) }
            }
        }
    }

    /// Multi-select resolution chips. Selection is stored as a comma-separated list of bucket
    /// labels (OR within the set); empty = no match until the user picks at least one.
    private func qualityChips(_ value: Binding<String>) -> some View {
        let selected = ResolutionBucket.decode(value.wrappedValue)
        return HStack(spacing: 4) {
            ForEach(ResolutionBucket.allCases) { bucket in
                let isOn = selected.contains(bucket.rawValue)
                Button {
                    var next = selected
                    if isOn { next.remove(bucket.rawValue) } else { next.insert(bucket.rawValue) }
                    value.wrappedValue = ResolutionBucket.encode(next)
                } label: {
                    Text(bucket.label)
                        .font(.caption)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(isOn ? Color.appAccent.opacity(0.18) : Color.appSurface.opacity(0.6))
                        )
                        .overlay(
                            Capsule().stroke(isOn ? Color.appAccent.opacity(0.5) : Color.clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func dateBinding(_ value: Binding<String>) -> Binding<Date> {
        Binding(
            get: { RuleDateFormat.date(from: value.wrappedValue) ?? Date() },
            set: { value.wrappedValue = RuleDateFormat.string(from: $0) }
        )
    }

    private func prefillDefault(_ value: Binding<String>, kind: FilterFieldKind) {
        switch kind {
        case .date: value.wrappedValue = RuleDateFormat.string(from: Date())
        case .rating: value.wrappedValue = "0"
        case .boolean: value.wrappedValue = "true"
        default: break
        }
    }

    // MARK: - Actions

    private func addRule(toGroup groupIndex: Int) {
        groups[groupIndex].rules.append(EditableRule())
    }

    private func removeRule(at ruleIndex: Int, inGroup groupIndex: Int) {
        guard groups[groupIndex].rules.count > 1 else { return }
        groups[groupIndex].rules.remove(at: ruleIndex)
    }

    private func addGroup() {
        groups.append(EditableGroup())
    }

    private func removeGroup(at index: Int) {
        guard groups.count > 1 else { return }
        groups.remove(at: index)
    }

    private func resetEditor(publish: Bool = true) {
        outerMatchMode = .all
        groups = [EditableGroup()]
        if publish {
            isPublishing = true
            group = nil
            isPublishing = false
        }
    }

    private func ruleIsValid(_ rule: EditableRule) -> Bool {
        guard rule.comparison.usesValue else { return true }
        guard !rule.value.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if rule.comparison.usesSecondValue {
            return !rule.value2.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    private func publish() {
        let nodes: [FilterNode] = groups.compactMap { g in
            let conditions: [FilterNode] = g.rules.compactMap { r in
                guard ruleIsValid(r) else { return nil }
                return .condition(FilterCondition(
                    field: r.field,
                    comparison: r.comparison,
                    value: r.value.trimmingCharacters(in: .whitespaces),
                    value2: r.comparison.usesSecondValue
                        ? r.value2.trimmingCharacters(in: .whitespaces)
                        : nil
                ))
            }
            guard !conditions.isEmpty else { return nil }
            return .group(FilterGroup(mode: g.matchMode, nodes: conditions))
        }

        let next: FilterGroup? = nodes.isEmpty
            ? nil
            : FilterGroup(mode: outerMatchMode, nodes: nodes)

        guard next != group else { return }
        isPublishing = true
        group = next
        isPublishing = false
    }

    private func loadFromBinding() {
        guard let existing = group, !existing.isEmpty else {
            outerMatchMode = .all
            groups = [EditableGroup()]
            return
        }
        outerMatchMode = existing.mode
        let loaded: [EditableGroup] = existing.nodes.compactMap { node in
            switch node {
            case .group(let inner):
                let rules: [EditableRule] = inner.nodes.compactMap { child in
                    guard case .condition(let c) = child else { return nil }
                    return EditableRule(
                        field: c.field,
                        comparison: c.comparison,
                        value: c.value,
                        value2: c.value2 ?? ""
                    )
                }
                return EditableGroup(
                    matchMode: inner.mode,
                    rules: rules.isEmpty ? [EditableRule()] : rules
                )
            case .condition(let c):
                // Flat top-level condition → wrap in a single ALL group for editing.
                return EditableGroup(
                    matchMode: .all,
                    rules: [EditableRule(
                        field: c.field,
                        comparison: c.comparison,
                        value: c.value,
                        value2: c.value2 ?? ""
                    )]
                )
            }
        }
        groups = loaded.isEmpty ? [EditableGroup()] : loaded
    }
}
