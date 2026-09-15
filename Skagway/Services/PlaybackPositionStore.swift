import Foundation

/// Persists last-known playback positions per video.
///
/// Today this is intentionally lightweight (UserDefaults) and keyed by file path so
/// it works even before a video has a database id (or if the DB is reset).
///
/// Reads are backed by an in-memory cache (loaded once, kept current on every write) rather than
/// decoding the whole positions dictionary from UserDefaults on every call — `loadSeconds` is
/// called once per visible grid card (for the resume-progress bar), so it needs to stay a cheap
/// dictionary lookup even for a library with thousands of videos.
enum PlaybackPositionStore {
    private static let defaults = UserDefaults.standard
    private static let key = PrefsKeys.playbackLastPositionsByPath
    private static var cache: [String: Double] = (defaults.dictionary(forKey: key) as? [String: Double]) ?? [:]

    static func loadSeconds(filePath: String) -> Double? {
        cache[filePath]
    }

    static func saveSeconds(_ seconds: Double, filePath: String) {
        saveSecondsBatch([filePath: seconds])
    }

    /// Write many paths in one UserDefaults round-trip (Import Metadata).
    static func saveSecondsBatch(_ updates: [String: Double]) {
        guard !updates.isEmpty else { return }
        for (path, seconds) in updates {
            cache[path] = seconds
        }
        defaults.set(cache, forKey: key)
    }

    static func clear(filePath: String) {
        cache.removeValue(forKey: filePath)
        defaults.set(cache, forKey: key)
    }

    /// Move resume positions when file paths change (rename / move / Location Relink).
    static func remapPaths(_ mappings: [(from: String, to: String)]) {
        guard !mappings.isEmpty else { return }
        var changed = false
        for pair in mappings {
            guard let seconds = cache.removeValue(forKey: pair.from) else { continue }
            cache[pair.to] = seconds
            changed = true
        }
        if changed {
            defaults.set(cache, forKey: key)
        }
    }
}
