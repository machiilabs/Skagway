import Foundation

/// Waiting in-player scrubber bakes. Index 0 is next.
/// The clip in front is the one the user most recently selected.
/// Rapid selection only keeps the newest handful; older paths fall off the tail.
struct PlayerStripWarmupQueue: Equatable {
    static let capacity = 8

    private(set) var paths: [String] = []

    var isEmpty: Bool { paths.isEmpty }

    mutating func prioritize(_ path: String) {
        guard !path.isEmpty else { return }
        if let index = paths.firstIndex(of: path) {
            paths.remove(at: index)
        }
        paths.insert(path, at: 0)
        if paths.count > Self.capacity {
            paths.removeLast(paths.count - Self.capacity)
        }
    }

    mutating func remove(_ path: String) {
        if let index = paths.firstIndex(of: path) {
            paths.remove(at: index)
        }
    }

    mutating func removeAll() {
        paths.removeAll()
    }

    mutating func popNext() -> String? {
        guard !paths.isEmpty else { return nil }
        return paths.removeFirst()
    }
}
