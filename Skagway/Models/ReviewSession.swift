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
/// Focus can sit outside the set (scan a maybe). With 2+ collected and review focus cleared,
/// Inspector batch-edits the whole set. Plain-click a collected clip to single-inspect it;
/// plain-click that same focused clip again to return to batch.
struct ReviewSession: Equatable {
    var focusedId: String?
    var selectedIds: Set<String> = []

    /// Batch inspect when 2+ collected and review focus is cleared.
    var isSetMode: Bool {
        guard selectedIds.count > 1 else { return false }
        return focusedId == nil
    }

    /// Videos Inspector tags, rates, and edits — the collected set when 2+ are selected
    /// and focus is cleared; otherwise the focused clip.
    var actionIds: Set<String> {
        if isSetMode { return selectedIds }
        if let focusedId { return [focusedId] }
        return selectedIds
    }

    mutating func focus(_ id: String) {
        focusedId = id
    }

    mutating func clearFocus() {
        focusedId = nil
    }

    /// Plain click (no modifiers). With 2+ collected: click the focused collected clip → batch;
    /// otherwise focus that clip (from batch or from another focus). Outside the multi-set → focus.
    @discardableResult
    mutating func applyPlainClick(on id: String, lastClickedId: String?) -> String {
        _ = lastClickedId
        guard selectedIds.contains(id), selectedIds.count > 1 else {
            focus(id)
            return id
        }
        if focusedId == id {
            clearFocus()
        } else {
            focus(id)
        }
        return id
    }

    mutating func toggleInSet(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    mutating func activateBatchInspectIfMultiCollected() {
        if selectedIds.count > 1 {
            clearFocus()
        }
    }

    mutating func toggleInSetForCollectionEdit(_ id: String) {
        let adding = !selectedIds.contains(id)
        toggleInSet(id)
        if adding {
            activateBatchInspectIfMultiCollected()
        }
    }

    mutating func selectOnly(_ id: String) {
        selectedIds = [id]
        focusedId = id
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

    /// List `Table` selection — mirrors Grid modifier-click semantics.
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
            activateBatchInspectIfMultiCollected()
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
                toggleInSetForCollectionEdit(clicked)
            }
            return clicked ?? lastClickedId
        }

        if flags.contains(.shift) {
            // Table `newIds` follow review focus (often focus→click). Collection range must anchor
            // on `lastClickedId` (e.g. last ⌘-click), like Grid — not the Table's native span.
            let anchor = lastClickedId ?? focusedId
            let tableAnchor = previousTableFocusId ?? focusedId
            guard let anchor,
                  let aIdx = allVideoIds.firstIndex(of: anchor),
                  let clicked = Self.listShiftClickEndpoint(
                    in: newIds,
                    anchor: tableAnchor,
                    orderedIds: allVideoIds
                  ),
                  let cIdx = allVideoIds.firstIndex(of: clicked)
            else {
                selectedIds.formUnion(newIds)
                activateBatchInspectIfMultiCollected()
                return lastClickedId
            }
            let range = min(aIdx, cIdx)...max(aIdx, cIdx)
            selectedIds.formUnion(Set(range.map { allVideoIds[$0] }))
            activateBatchInspectIfMultiCollected()
            return clicked
        }

        if let id = newIds.first {
            return applyPlainClick(on: id, lastClickedId: lastClickedId)
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
