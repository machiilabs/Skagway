import AVFoundation
import Foundation
import Observation

/// Observable subtitle track: holds parsed cues, observes an `AVPlayer`'s current time,
/// and exposes the currently-visible `SubtitleCue`.
///
/// Designed to be cheap to update at ~10Hz even with several thousand cues — the
/// `findCue(for:)` lookup is O(1) for sequential playback (hint path) and O(log n)
/// for seeks.
@Observable
final class SubtitleTrack {
    /// Parsed cues sorted by `start` time.
    private(set) var cues: [SubtitleCue] = []
    /// The cue whose `[start, end]` range contains the player's current time, or `nil` in a gap.
    private(set) var currentCue: SubtitleCue?
    /// URL the cues were loaded from (for UI display — "Subtitles: foo.srt").
    private(set) var sourceURL: URL?

    /// User-facing toggle. Hides the overlay when `false` without unloading cues.
    /// Default off — the player Captions menu (Off) owns enabling the sidecar overlay.
    var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                updateCurrentCue()
            } else if currentCue != nil {
                currentCue = nil
            }
        }
    }

    private weak var attachedPlayer: AVPlayer?
    private var timeObserver: Any?
    /// Index hint used to keep `findCue(for:)` O(1) during sequential playback.
    private var lastIndex: Int = -1

    // MARK: - Loading

    /// Loads and parses an SRT at `url`. Clears any previous cues. Returns the number of cues parsed.
    @discardableResult
    func load(from url: URL) -> Int {
        let parsed = SRTParser.parseFile(at: url) ?? []
        return applyLoadedCues(parsed, sourceURL: url)
    }

    /// Applies already-parsed cues (e.g. from a background parse). Clears any previous cues.
    @discardableResult
    func applyLoadedCues(_ parsed: [SubtitleCue], sourceURL: URL?) -> Int {
        cues = parsed
        self.sourceURL = sourceURL
        lastIndex = -1
        updateCurrentCue()
        return parsed.count
    }

    /// Clears cues and detaches from any player.
    func unload() {
        detach()
        cues = []
        currentCue = nil
        sourceURL = nil
        lastIndex = -1
    }

    // MARK: - Player attachment

    /// Begins observing `player`'s time and updating `currentCue`. Replaces any prior attachment.
    func attach(to player: AVPlayer) {
        detach()
        attachedPlayer = player
        // 10Hz is visually smooth (humans don't see the 50–100ms boundary jitter at cue edges)
        // and cheap enough to run for the entire playback session.
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.updateCurrentCue()
        }
    }

    /// Removes the time observer. Safe to call even if not attached.
    func detach() {
        if let observer = timeObserver, let player = attachedPlayer {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        attachedPlayer = nil
        lastIndex = -1
    }

    deinit {
        if let observer = timeObserver, let player = attachedPlayer {
            player.removeTimeObserver(observer)
        }
    }

    // MARK: - Lookup

    private func updateCurrentCue() {
        guard isEnabled else {
            if currentCue != nil { currentCue = nil }
            return
        }
        guard let player = attachedPlayer else { return }
        let t = player.currentTime().seconds
        guard t.isFinite, !t.isNaN else { return }

        let (cue, idx) = findCue(for: t)
        if cue?.id != currentCue?.id {
            currentCue = cue
        }
        lastIndex = idx
    }

    /// Returns the cue active at `t`, or `nil` if `t` falls in a gap. Also returns a bounded index
    /// to use as a hint for the next call.
    private func findCue(for t: Double) -> (SubtitleCue?, Int) {
        guard !cues.isEmpty else { return (nil, -1) }

        // Hint path: O(1) for sequential playback.
        if lastIndex >= 0, lastIndex < cues.count {
            let hint = cues[lastIndex]
            if hint.start <= t, t <= hint.end { return (hint, lastIndex) }
            // Advance to next cue if we just crossed into it (very common at 10Hz).
            let nextIdx = lastIndex + 1
            if nextIdx < cues.count {
                let next = cues[nextIdx]
                if next.start <= t, t <= next.end { return (next, nextIdx) }
                // In a gap between `hint` and `next`: keep index so we can skip straight to `next`.
                if t > hint.end, t < next.start { return (nil, lastIndex) }
            } else if t > hint.end {
                return (nil, lastIndex)
            }
        }

        // Binary search: O(log n), taken on seeks or initial frames.
        var lo = 0
        var hi = cues.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let cue = cues[mid]
            if t < cue.start {
                hi = mid - 1
            } else if t > cue.end {
                lo = mid + 1
            } else {
                return (cue, mid)
            }
        }
        // In a gap: return the index of the upcoming cue so the hint path catches it next tick.
        let nextIdx = max(0, min(lo, cues.count - 1))
        return (nil, nextIdx)
    }
}

// MARK: - Sidecar discovery

extension SubtitleTrack {
    /// Finds an `.srt` sidecar for `videoURL`.
    ///
    /// Priority (first existing match wins):
    /// 1. Exact basename + `.srt` / `.SRT` (e.g. `My Movie.mp4` → `My Movie.srt`)
    /// 2. Common language suffixes: `.en.srt`, `.eng.srt`, `.English.srt` (+ uppercase variants)
    /// 3. Any `.srt` in the same folder whose name starts with `<basename>.`
    ///    (catches `.ja.srt`, `.jpn.srt`, `.Japanese.srt`, `.fr.srt`, `.subs.srt`, etc.)
    ///
    /// Uses explicit string path construction rather than `URL.appendingPathExtension(_:)` because
    /// the latter does not always produce the expected `name.xx.srt` for multi-dot extensions.
    static func findSidecarSRT(for videoURL: URL) -> URL? {
        let fm = FileManager.default
        let dir = videoURL.deletingLastPathComponent()
        let base = videoURL.deletingPathExtension().lastPathComponent

        // 1 + 2. Preferred candidates, case variants included so case-sensitive volumes don't miss.
        let specificSuffixes = [
            "srt", "SRT",
            "en.srt", "en.SRT", "En.srt",
            "eng.srt", "eng.SRT", "Eng.srt",
            "English.srt", "english.srt",
        ]
        for suffix in specificSuffixes {
            let candidate = dir.appendingPathComponent("\(base).\(suffix)")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        // 3. Directory scan: any sibling `.srt` sharing the basename prefix.
        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let prefix = "\(base)."
            let matches = contents.filter { url in
                url.pathExtension.lowercased() == "srt" && url.lastPathComponent.hasPrefix(prefix)
            }
            // Shortest name wins — typically the canonical `base.lang.srt` over noisier variants.
            if let best = matches.min(by: { $0.lastPathComponent.count < $1.lastPathComponent.count }) {
                return best
            }
        }

        return nil
    }
}
