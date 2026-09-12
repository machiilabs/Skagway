import Foundation

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
}
