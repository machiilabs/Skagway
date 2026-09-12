import AppKit
import Foundation

/// ⌘ / ⇧ / ⌥ List clicks build on the current set; plain clicks replace or move focus.
enum ListSelectionModifiers {
    static func usesExtendedSelection(_ flags: NSEvent.ModifierFlags) -> Bool {
        let mods = flags.intersection(.deviceIndependentFlagsMask)
        return mods.contains(.command) || mods.contains(.shift) || mods.contains(.option)
    }
}

/// Always-on split between the clip you are reviewing and the collected working set.
///
/// Focus can sit outside the set (scan a maybe). The set is what bulk tag / rating / delete
/// apply to once you ask Inspector to show it.
struct ReviewSession: Equatable {
    var focusedId: String?
    var selectedIds: Set<String> = []
    var inspectorPrefersSelection = false

    var isSetMode: Bool {
        selectedIds.count > 1 && (inspectorPrefersSelection || focusedId == nil)
    }

    /// Videos Inspector tags, rates, and edits. The focused clip while reviewing; the set after
    /// you finish collecting (or click the N-selected chip).
    var actionIds: Set<String> {
        if isSetMode { return selectedIds }
        if let focusedId { return [focusedId] }
        return selectedIds
    }

    mutating func focus(_ id: String) {
        focusedId = id
        inspectorPrefersSelection = false
    }

    mutating func toggleInSet(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
        if selectedIds.count < 2 {
            inspectorPrefersSelection = false
        }
    }

    mutating func selectOnly(_ id: String) {
        selectedIds = [id]
        focusedId = id
        inspectorPrefersSelection = false
    }

    mutating func inspectSet() {
        guard selectedIds.count > 1 else { return }
        inspectorPrefersSelection = true
    }

    mutating func playbackStopped() {
        if selectedIds.count > 1 {
            inspectorPrefersSelection = true
        }
    }

    mutating func moveFocus(step: Int, orderedIds: [String]) {
        guard step != 0, !orderedIds.isEmpty else { return }
        let currentIndex: Int
        if let id = focusedId, let idx = orderedIds.firstIndex(of: id) {
            currentIndex = idx
        } else if step > 0 {
            currentIndex = -1
        } else {
            currentIndex = orderedIds.count
        }
        let next = currentIndex + step
        guard orderedIds.indices.contains(next) else { return }
        focus(orderedIds[next])
    }

    mutating func prune(validIds: Set<String>) {
        selectedIds = selectedIds.intersection(validIds)
        if let id = focusedId, !validIds.contains(id) {
            focusedId = selectedIds.first
        }
        if selectedIds.count < 2 {
            inspectorPrefersSelection = false
        }
    }

    mutating func remapPath(from old: String, to new: String) {
        if focusedId == old { focusedId = new }
        if selectedIds.contains(old) {
            selectedIds.remove(old)
            selectedIds.insert(new)
        }
    }

    func reviewedId(lastSelectedId: String?) -> String? {
        if isSetMode {
            if let lastSelectedId, selectedIds.contains(lastSelectedId) {
                return lastSelectedId
            }
            return selectedIds.first
        }
        return focusedId ?? lastSelectedId ?? selectedIds.first
    }

    /// List `Table` selection while Review is on — mirrors Grid modifier-click semantics.
    mutating func applyListTableSelection(
        newIds: Set<String>,
        allVideoIds: [String],
        previousTableFocusId: String?,
        lastClickedId: String?,
        flags: NSEvent.ModifierFlags
    ) -> String? {
        let allSet = Set(allVideoIds)
        let previousTable = Set(previousTableFocusId.map { [$0] } ?? [])

        if flags.contains(.command), newIds == allSet, !allSet.isEmpty {
            selectedIds = newIds
            return lastClickedId
        }

        let optionOnly = flags.contains(.option)
            && !flags.contains(.command)
            && !flags.contains(.shift)
        if optionOnly, let id = newIds.first {
            selectOnly(id)
            return id
        }

        if flags.contains(.command) {
            let clicked = newIds.subtracting(previousTable).first ?? newIds.first
            if let clicked {
                toggleInSet(clicked)
            }
            return clicked ?? lastClickedId
        }

        if flags.contains(.shift) {
            selectedIds = newIds
            if let clicked = Self.listShiftClickEndpoint(in: newIds, anchor: lastClickedId, orderedIds: allVideoIds) {
                focus(clicked)
                return clicked
            }
            return lastClickedId
        }

        if let id = newIds.first {
            focus(id)
            return id
        }
        return lastClickedId
    }

    static func listShiftClickEndpoint(in ids: Set<String>, anchor: String?, orderedIds: [String]) -> String? {
        guard let anchor,
              let anchorIdx = orderedIds.firstIndex(of: anchor)
        else {
            return ids.first
        }
        return ids.max { lhs, rhs in
            let li = orderedIds.firstIndex(of: lhs) ?? anchorIdx
            let ri = orderedIds.firstIndex(of: rhs) ?? anchorIdx
            return abs(li - anchorIdx) < abs(ri - anchorIdx)
        }
    }
}
