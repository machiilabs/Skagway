import GRDB
import SwiftUI

struct CollectionEditorView: View {
    let dbPool: DatabasePool
    let collection: VideoCollection?
    /// Custom metadata fields, so rules can target them (and value editors know their type).
    var customFields: [CustomMetadataFieldDefinition] = []
    /// Existing tags, offered as a menu when a rule targets the Tag attribute.
    var tags: [Tag] = []
    /// Smart collections and albums for Membership rule targets.
    var collections: [VideoCollection] = []
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var outerMatchMode: MatchMode = .all
    @State private var groups: [EditableGroup] = [EditableGroup()]
    @State private var saveError: String?
    @State private var isSaving = false

    struct EditableRule: Identifiable {
        let id = UUID()
        var field: FilterField = .builtin(.name)
        var comparison: RuleComparison = .equals
        var value: String = ""
        var value2: String = ""
    }

    struct EditableGroup: Identifiable {
        let id = UUID()
        var matchMode: MatchMode = .all
        var rules: [EditableRule] = [EditableRule()]
    }

    private var repository: CollectionRepository {
        CollectionRepository(dbPool: dbPool)
    }

    private var customFieldsById: [UUID: CustomMetadataFieldDefinition] {
        Dictionary(uniqueKeysWithValues: customFields.map { ($0.id, $0) })
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !groups.isEmpty
            && groups.allSatisfy { group in
                !group.rules.isEmpty && group.rules.allSatisfy { ruleIsValid($0) }
            }
    }

    private func ruleIsValid(_ rule: EditableRule) -> Bool {
        guard rule.comparison.usesValue else { return true }
        guard !rule.value.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if case .builtin(.membership) = rule.field {
            return MembershipTarget(storageToken: rule.value) != nil
        }
        if rule.comparison.usesSecondValue {
            return !rule.value2.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            groupsArea
            Divider()
            footer
        }
        .frame(width: 660, height: 500)
        .onAppear { loadExisting() }
        .alert("Couldn’t Save Collection", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text("Collection Name:")
                .fontWeight(.medium)
            TextField("e.g. Large Files", text: $name)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
    }

    private var groupsArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Match")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)

                modeToggle($outerMatchMode)

                Text("of the following groups:")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)
            }

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, _ in
                        groupCard(groupIndex: groupIndex)
                    }

                    Button(action: addGroup) {
                        Label("Add Group", systemImage: "plus.circle.fill")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccent)
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
        }
        .padding()
    }

    private func groupCard(groupIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Match videos where")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)

                modeToggle($groups[groupIndex].matchMode)

                Text("of the following are true:")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)

                Spacer()

                Button(action: { removeGroup(at: groupIndex) }) {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.appTextSecondary)
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
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { mode.wrappedValue = mode.wrappedValue == .all ? .any : .all } }) {
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

    private func ruleRow(groupIndex: Int, ruleIndex: Int) -> some View {
        let rule = $groups[groupIndex].rules[ruleIndex]
        let fields = customFieldsById
        return HStack(spacing: 8) {
            // Attribute: built-in fields, then custom fields (sectioned).
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
            .frame(width: 140)
            .onChange(of: rule.wrappedValue.field) { _, newField in
                let supported = newField.supportedComparisons(customFields: fields)
                if !supported.contains(rule.wrappedValue.comparison) {
                    rule.wrappedValue.comparison = supported.first ?? .equals
                }
                // Prefill a default for controls that always show something (date picker, stars),
                // so a freshly-picked date/rating field isn't invalid-because-empty.
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
            .frame(width: 150)
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

            Button(action: { addRule(toGroup: groupIndex) }) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)

            Button(action: { removeRule(at: ruleIndex, inGroup: groupIndex) }) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .disabled(groups[groupIndex].rules.count <= 1)
        }
    }

    /// Type-aware value editor: the control fits the field's kind (stars for rating, a date picker
    /// for dates, a tag menu for tags, numeric/text fields otherwise), and shows a second control
    /// for the `.between` range operator.
    @ViewBuilder
    private func ruleValueEditor(_ rule: Binding<EditableRule>, fields: [UUID: CustomMetadataFieldDefinition]) -> some View {
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
        case .membership:
            MembershipTargetPicker(storageToken: rule.value, collections: collections)
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
        case .membership:
            value.wrappedValue = MembershipTarget.smartLibrary(.recentlyAdded).storageToken
        default: break
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button(collection == nil ? "Create" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSaving)
        }
        .padding()
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

    private func loadExisting() {
        guard let existing = collection else {
            groups = [EditableGroup()]
            return
        }
        name = existing.name
        outerMatchMode = existing.matchMode
        Task {
            guard let id = existing.id else { return }
            let dbGroups = (try? await repository.fetchRuleGroups(for: id)) ?? []
            let dbRules = (try? await repository.fetchRules(for: id)) ?? []
            if dbGroups.isEmpty {
                groups = [EditableGroup()]
            } else {
                let rulesByGroup = Dictionary(grouping: dbRules, by: \.groupId)
                groups = dbGroups.sorted { $0.orderIndex < $1.orderIndex }.map { g in
                    let groupRules = (rulesByGroup[g.id ?? -1] ?? []).map { r in
                        EditableRule(field: r.attribute, comparison: r.comparison, value: r.value, value2: r.value2 ?? "")
                    }
                    return EditableGroup(matchMode: g.matchMode, rules: groupRules.isEmpty ? [EditableRule()] : groupRules)
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            let groupInputs: [(mode: MatchMode, rules: [CollectionRule])] = groups.map { g in
                (
                    mode: g.matchMode,
                    rules: g.rules.map { r in
                        CollectionRule(
                            collectionId: 0,
                            groupId: 0,
                            attribute: r.field,
                            comparison: r.comparison,
                            value: r.value.trimmingCharacters(in: .whitespaces),
                            value2: r.comparison.usesSecondValue ? r.value2.trimmingCharacters(in: .whitespaces) : nil
                        )
                    }
                )
            }
            var draft: VideoCollection
            if var existing = collection {
                existing.name = trimmedName
                existing.matchMode = outerMatchMode
                draft = existing
            } else {
                draft = VideoCollection(
                    name: trimmedName,
                    dateCreated: Date(),
                    matchMode: outerMatchMode,
                    kind: .smart
                )
            }
            do {
                _ = try await repository.saveSmartCollection(draft, groups: groupInputs)
                onSave()
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}
