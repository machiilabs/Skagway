import Foundation

/// Compiles a `FilterGroup` into a fast per-video predicate — the single matcher shared by saved
/// Collections and (Phase 3) the live advanced filter. Everything that doesn't depend on the video
/// (parsed numbers/dates, lowercased strings, compiled regex) is computed once at construction;
/// the returned closure is evaluated per video.
///
/// Built-in attribute behavior is a faithful port of `CollectionRepository.compileRule` (same field
/// derivations, MB→bytes / minutes→seconds scaling, day-granularity date compares) so re-pointing
/// Collections onto this matcher is behavior-preserving. It additionally supports the `.between`
/// range operator and custom-metadata-field conditions, both of which existing collections never use.
struct FilterMatcher {
    /// `customValues` is the tested video's custom metadata (fieldId → raw stored string).
    private typealias Predicate = (Video, [Tag], [UUID: String]) -> Bool

    private let predicate: Predicate

    /// - Parameter customFields: definitions for any `.custom` fields referenced, so their stored
    ///   string values can be parsed per type. A condition referencing a missing/unknown custom
    ///   field never matches.
    init(group: FilterGroup, customFields: [UUID: CustomMetadataFieldDefinition]) {
        self.predicate = Self.compileGroup(group, customFields: customFields)
    }

    func matches(_ video: Video, tags: [Tag], customValues: [UUID: String]) -> Bool {
        predicate(video, tags, customValues)
    }

    // MARK: - Tree compilation

    private static func compileGroup(_ group: FilterGroup, customFields: [UUID: CustomMetadataFieldDefinition]) -> Predicate {
        let preds: [Predicate] = group.nodes.map { node in
            switch node {
            case .condition(let c): return compileCondition(c, customFields: customFields)
            case .group(let g): return compileGroup(g, customFields: customFields)
            }
        }
        let mode = group.mode
        return { v, tags, cvals in
            // Preserve `GroupedMatcher` semantics exactly: an empty group matches nothing. Callers
            // that mean "no filter" must guard on `FilterGroup.isEmpty` before applying the matcher.
            guard !preds.isEmpty else { return false }
            switch mode {
            case .all: return preds.allSatisfy { $0(v, tags, cvals) }
            case .any: return preds.contains { $0(v, tags, cvals) }
            }
        }
    }

    private static func compileCondition(_ c: FilterCondition, customFields: [UUID: CustomMetadataFieldDefinition]) -> Predicate {
        switch c.field {
        case .builtin(let attr):
            let base = compileBuiltin(attr, c.comparison, c.value, c.value2)
            return { v, tags, _ in base(v, tags) }
        case .custom(let id):
            guard let def = customFields[id] else { return { _, _, _ in false } }
            return compileCustom(fieldId: id, valueType: def.valueType, cmp: c.comparison, value: c.value, value2: c.value2)
        }
    }

    // MARK: - Built-in attributes (port of CollectionRepository.compileRule + between)

    private static func compileBuiltin(_ attr: RuleAttribute, _ cmp: RuleComparison, _ raw: String, _ raw2: String?) -> (Video, [Tag]) -> Bool {
        switch attr {
        case .name:
            let m = StringMatcher(cmp, raw); return { v, _ in m.matches(v.displayTitle) || m.matches(v.fileName) }
        case .path:
            let m = StringMatcher(cmp, raw); return { v, _ in m.matches(v.filePath) }
        case .fileExtension:
            let m = StringMatcher(cmp, raw); return { v, _ in m.matches((v.filePath as NSString).pathExtension) }
        case .parentFolder:
            let m = StringMatcher(cmp, raw)
            return { v, _ in
                let parent = ((v.filePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
                return m.matches(parent)
            }
        case .volume:
            let m = StringMatcher(cmp, raw)
            return { v, _ in
                let comps = (v.filePath as NSString).pathComponents
                let vol = comps.count >= 3 && comps[0] == "/" && comps[1] == "Volumes" ? comps[2] : "/"
                return m.matches(vol)
            }
        case .codec:
            let m = StringMatcher(cmp, raw); return { v, _ in m.matches(v.codec ?? "") }
        case .tag:
            let m = StringMatcher(cmp, raw); return { _, tags in tags.contains { m.matches($0.name) } }
        case .fileSize:
            let lo = Int64((Double(raw) ?? 0) * 1_000_000)
            let hi = raw2.flatMap { Double($0) }.map { Int64($0 * 1_000_000) }
            return { v, _ in matchNumeric(v.fileSize, cmp, lo, hi) }
        case .duration:
            let lo = (Double(raw) ?? 0) * 60
            let hi = raw2.flatMap { Double($0) }.map { $0 * 60 }
            return { v, _ in
                guard let dur = v.duration else { return false }
                return matchNumeric(dur, cmp, lo, hi)
            }
        case .height:
            let lo = Int(raw) ?? 0
            let hi = raw2.flatMap { Int($0) }
            return { v, _ in
                guard let h = v.height else { return false }
                return matchNumeric(h, cmp, lo, hi)
            }
        case .width:
            let lo = Int(raw) ?? 0
            let hi = raw2.flatMap { Int($0) }
            return { v, _ in
                guard let w = v.width else { return false }
                return matchNumeric(w, cmp, lo, hi)
            }
        case .quality:
            // Value is a comma-separated set of ResolutionBucket labels; equals = is any of,
            // notEquals = is none of. Empty selection never matches.
            let buckets = ResolutionBucket.decode(raw)
            return { v, _ in
                guard !buckets.isEmpty, let label = v.resolutionLabel else { return false }
                let hit = buckets.contains(label)
                switch cmp {
                case .equals: return hit
                case .notEquals: return !hit
                default: return false
                }
            }
        case .playCount:
            let lo = Int(raw) ?? 0
            let hi = raw2.flatMap { Int($0) }
            return { v, _ in matchNumeric(v.playCount, cmp, lo, hi) }
        case .rating:
            let lo = Int(raw) ?? 0
            let hi = raw2.flatMap { Int($0) }
            return { v, _ in matchNumeric(v.rating, cmp, lo, hi) }
        case .dateImported:
            let lo = parseDay(raw)
            let hi = raw2.flatMap { parseDay($0) }
            return { v, _ in matchDay(v.dateAdded, cmp, lo, hi) }
        case .dateCreated:
            let lo = parseDay(raw)
            let hi = raw2.flatMap { parseDay($0) }
            return { v, _ in
                guard let date = v.creationDate else { return false }
                return matchDay(date, cmp, lo, hi)
            }
        }
    }

    // MARK: - Custom fields

    private static func compileCustom(fieldId: UUID, valueType: CustomMetadataValueType, cmp: RuleComparison, value: String, value2: String?) -> Predicate {
        switch cmp {
        case .isEmpty:
            return { _, _, cvals in customValueIsEmpty(cvals[fieldId], valueType: valueType) }
        case .isNotEmpty:
            return { _, _, cvals in !customValueIsEmpty(cvals[fieldId], valueType: valueType) }
        default:
            break
        }

        switch valueType {
        case .string, .text:
            let m = StringMatcher(cmp, value)
            return { _, _, cvals in
                guard let raw = cvals[fieldId] else { return false }
                return m.matches(raw)
            }
        case .number:
            let lo = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            let hi = value2.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return { _, _, cvals in
                guard let raw = cvals[fieldId],
                      let n = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                      let lo else { return false }
                return matchNumeric(n, cmp, lo, hi)
            }
        case .date, .dateTime:
            let lo = parseDay(value)
            let hi = value2.flatMap { parseDay($0) }
            let isDateTime = valueType == .dateTime
            return { _, _, cvals in
                guard let raw = cvals[fieldId] else { return false }
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = isDateTime ? (isoFrac.date(from: t) ?? isoPlain.date(from: t)) : isoDay.date(from: t)
                guard let date = parsed else { return false }
                return matchDay(date, cmp, lo, hi)
            }
        case .boolean:
            let want = CustomMetadataValueType.normalizeBooleanStorage(value)
            return { _, _, cvals in
                guard let want,
                      let raw = cvals[fieldId],
                      let have = CustomMetadataValueType.normalizeBooleanStorage(raw)
                else { return false }
                switch cmp {
                case .equals: return have == want
                case .notEquals: return have != want
                default: return false
                }
            }
        }
    }

    /// Unset row, whitespace-only text/number/date, or boolean that doesn't normalize.
    private static func customValueIsEmpty(_ raw: String?, valueType: CustomMetadataValueType) -> Bool {
        guard let raw else { return true }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch valueType {
        case .string, .text, .number, .date, .dateTime:
            return trimmed.isEmpty
        case .boolean:
            return CustomMetadataValueType.normalizeBooleanStorage(trimmed) == nil
        }
    }

    // MARK: - Comparison primitives (ported from CollectionRepository)

    private struct StringMatcher {
        let op: RuleComparison
        let rhsLower: String
        let regex: Regex<Substring>?

        init(_ op: RuleComparison, _ rhs: String) {
            self.op = op
            self.rhsLower = rhs.lowercased()
            self.regex = op == .matches ? (try? Regex(rhs, as: Substring.self)) : nil
        }

        func matches(_ lhs: String) -> Bool {
            let l = lhs.lowercased()
            switch op {
            case .equals: return l == rhsLower
            case .notEquals: return l != rhsLower
            case .contains: return l.contains(rhsLower)
            case .startsWith: return l.hasPrefix(rhsLower)
            case .endsWith: return l.hasSuffix(rhsLower)
            case .matches:
                guard let regex else { return false }
                return l.contains(regex)
            default: return false
            }
        }
    }

    private static func matchNumeric<T: Comparable>(_ lhs: T, _ op: RuleComparison, _ rhs: T, _ rhs2: T?) -> Bool {
        switch op {
        case .equals: return lhs == rhs
        case .notEquals: return lhs != rhs
        case .lessThan: return lhs < rhs
        case .greaterThan: return lhs > rhs
        case .lessThanOrEqual: return lhs <= rhs
        case .greaterThanOrEqual: return lhs >= rhs
        case .between:
            guard let rhs2 else { return false }
            return lhs >= rhs && lhs <= rhs2
        default: return false
        }
    }

    private static func matchDay(_ lhs: Date, _ op: RuleComparison, _ lo: Date?, _ hi: Date?) -> Bool {
        let lhsDay = Calendar.current.startOfDay(for: lhs)
        switch op {
        case .equals:
            guard let lo else { return false }
            return lhsDay == lo
        case .lessThan:
            guard let lo else { return false }
            return lhsDay < lo
        case .greaterThan:
            guard let lo else { return false }
            return lhsDay > lo
        case .between:
            guard let lo, let hi else { return false }
            return lhsDay >= lo && lhsDay <= hi
        default:
            return false
        }
    }

    private static func parseDay(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        guard let date = formatter.date(from: dateString) else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    // Formatters for custom date/dateTime stored values (mirror CustomFieldValueParser).
    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
