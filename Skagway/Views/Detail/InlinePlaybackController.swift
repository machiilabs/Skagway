import AVKit
import AppKit
import Foundation
import SwiftUI

/// The single inline-playback engine, shared by every playback mode (detail-pane hero, floating
/// overlay, and full-screen window). It owns the `AVPlayer` and `SubtitleTrack` and centralizes the
/// behavior that must be identical in every mode:
///
/// - `isPlayable` preflight + missing-file detection, and `AVPlayerItem.status` error surfacing
/// - resume-position load on start **and save on stop** (`PlaybackPositionStore`)
/// - the "Resumed at … / Start at beginning" banner (+ optional auto-fade)
/// - sidecar `.srt` subtitle discovery and a Captions menu (Off / Sidecar / in-band)
/// - `recordPlay`
/// - Space / Shift-Space (play-pause / restart) intents
///
/// Owned by `LibraryViewModel` (`viewModel.playback`) so a single player instance backs all hosts.
/// Host views are thin: they render `player` / `subtitleTrack` / banner / error state and forward the
/// lifecycle calls below.
@MainActor
@Observable
final class InlinePlaybackController {
    @ObservationIgnored private unowned let viewModel: LibraryViewModel

    // Rendered by host views.
    private(set) var player: AVPlayer?
    let subtitleTrack = SubtitleTrack()
    private(set) var didAutoResume = false
    private(set) var resumedFromSeconds: Double?
    var resumeBannerOpacity: Double = 1
    private(set) var playerError: String?
    private(set) var currentVideo: Video?

    /// Wall-clock playhead for `PlaybackTimelineBar` (updated by a periodic observer).
    private(set) var currentTimeSeconds: Double = 0
    /// Duration used by the timeline; prefers item duration, falls back to `Video.duration`.
    private(set) var durationSeconds: Double = 0
    private(set) var isPlaying: Bool = false
    /// Desired playback rate (persists across pause/seek within the session). Applied on play.
    private(set) var playbackRate: Float = 1.0
    /// Session-only leave point after a bookmark jump (ghost playhead + Return chip). Cleared on stop.
    private(set) var returnPointSeconds: Double?
    /// When true, dismiss the return point once playback crosses it from earlier times (jumped backward).
    private var returnPointClearsOnCatchUp = false
    /// Ignore scrubber clear for the rest of this turn after a bookmark jump (diamond click can also hit the scrub gesture).
    private var suppressReturnClearFromScrub = false
    /// Player volume 0…1 (persisted). Applied whenever an `AVPlayer` is created.
    private(set) var volume: Float
    /// When true, audio is muted; `volume` is preserved for unmute.
    private(set) var isMuted: Bool

    /// Per-play captions menu selection (resets on each `start` / `stop`; not persisted).
    private(set) var captionSelection: CaptionSelection = .off
    /// True when a sibling `.srt` was found for the current item.
    private(set) var hasSidecarSRT: Bool = false
    /// Named playable options from the current item’s AV legible group.
    private(set) var inBandCaptionOptions: [InBandCaptionOption] = []

    /// Skip buttons / ⌥←⌥→ while playing.
    static let skipSeconds: Double = 15
    /// ←/→ nudge while playing (smaller than skip).
    static let nudgeSeconds: Double = 5
    static let playbackRateChoices: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    /// Ignore bookmark jumps that barely move the playhead.
    private static let returnPointMinDeltaSeconds: Double = 1.0
    private static let volumeDefaultsKey = "inlinePlayback.volume"
    private static let mutedDefaultsKey = "inlinePlayback.isMuted"

    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var resumeBannerFadeTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// Last non-zero volume; used when unmuting after the slider hit zero.
    @ObservationIgnored private var lastAudibleVolume: Float = 1.0

    init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.volumeDefaultsKey) != nil {
            volume = Self.clampedVolume(defaults.float(forKey: Self.volumeDefaultsKey))
        } else {
            volume = 1.0
        }
        isMuted = defaults.bool(forKey: Self.mutedDefaultsKey)
        if volume > 0.001 {
            lastAudibleVolume = volume
        }
    }

    // MARK: - Lifecycle

    /// Begin playback of `video`. `seconds == 0` lets the saved resume position apply (with banner);
    /// `seconds > 0` is an explicit seek (filmstrip click) that suppresses resume. `ignoreResume`
    /// starts plainly at `seconds` even when a saved position exists (⌥-Space "Play from Beginning").
    func start(video: Video, at seconds: Double, ignoreResume: Bool = false) {
        // New load — drop any session return point from the previous item.
        clearReturnPoint()
        currentVideo = video
        playerError = nil
        statusTask?.cancel()
        // Clear previous track immediately; discovery + SRT parse run off the main thread
        // inside statusTask so SPACE never blocks on directory scans / large sidecar files
        // before the floating panel can appear.
        subtitleTrack.unload()
        resetCaptionSession()

        let videoURL = video.url
        let videoPath = video.filePath

        statusTask = Task { @MainActor in
            // Sidecar discovery (directory listing + SRT parse) off the main actor. Must NOT gate
            // `play()` — large folders make `contentsOfDirectory` take seconds, which used to leave
            // the panel stuck on the first decoded frame until the scan finished.
            let sidecarTask = Task.detached(priority: .userInitiated) {
                () -> (url: URL, cues: [SubtitleCue])? in
                guard let srt = SubtitleTrack.findSidecarSRT(for: videoURL) else { return nil }
                let cues = SRTParser.parseFile(at: srt) ?? []
                return (srt, cues)
            }

            // Pre-flight: ask AVFoundation whether it can play this file before creating the player,
            // so unsupported formats are rejected immediately rather than showing a blank player.
            let asset = AVURLAsset(url: videoURL)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard !Task.isCancelled else { return }
            guard playable else {
                sidecarTask.cancel()
                if FileManager.default.fileExists(atPath: videoPath) {
                    let ext = videoURL.pathExtension.uppercased()
                    playerError = ext.isEmpty
                        ? "This file cannot be played by the built-in player."
                        : "\(ext) files cannot be played by the built-in player."
                } else {
                    playerError = "The file could not be found. The drive may not be mounted."
                    viewModel.noteLibraryFileMissing(path: videoPath)
                }
                surfaceErrorKeepingPanel()
                return
            }

            let newPlayer = AVPlayer(url: videoURL)
            // Keep auto-select off (1155): in-band 608/708 / subtitle tracks otherwise appear as
            // speech-bubble captions even when Live Captions and Accessibility → Captions (SDH)
            // are off. The Captions menu selects nil (Off / Sidecar) or one named option.
            newPlayer.appliesMediaSelectionCriteriaAutomatically = false
            detachTimelineObservers()
            player?.pause()
            player = newPlayer
            viewModel.notifyPlaybackItemChanged()
            applyVolumeToPlayer(newPlayer)
            subtitleTrack.attach(to: newPlayer)
            attachTimelineObservers(to: newPlayer, fallbackDuration: video.duration)
            Task { await self.refreshInBandCaptionOptions(on: newPlayer) }
            Task { await self.viewModel.reloadBookmarksForPlayback(video: video) }

            // Start playback immediately — sidecar cues cache in when the discovery task finishes.
            let resumeSeconds: Double? = {
                guard seconds == 0, !ignoreResume else { return nil }
                guard let s = PlaybackPositionStore.loadSeconds(filePath: videoPath) else { return nil }
                guard s >= 1.0 else { return nil }
                if let duration = video.duration, duration > 0, s >= duration - 5.0 { return nil }
                return s
            }()
            if let resumeSeconds {
                resumeBannerOpacity = 1
                didAutoResume = true
                resumedFromSeconds = resumeSeconds
                newPlayer.seek(to: CMTime(seconds: resumeSeconds, preferredTimescale: 600)) { [weak self] _ in
                    self?.playAtConfiguredRate(newPlayer)
                }
                scheduleResumeBannerFadeIfNeeded()
            } else if seconds > 0 {
                cancelResumeBannerFadeTask()
                resumeBannerOpacity = 1
                didAutoResume = false
                resumedFromSeconds = nil
                // Precise seek (zero tolerance) so a filmstrip click lands on the clicked frame
                // instead of snapping to the nearest keyframe.
                newPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                               toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    self?.playAtConfiguredRate(newPlayer)
                }
            } else {
                cancelResumeBannerFadeTask()
                resumeBannerOpacity = 1
                didAutoResume = false
                resumedFromSeconds = nil
                playAtConfiguredRate(newPlayer)
            }
            Task { await viewModel.recordPlay(for: video) }

            // Cache sidecar cues when ready; overlay stays off until the user picks Sidecar.
            if let sidecar = await sidecarTask.value, !Task.isCancelled {
                guard player === newPlayer else { return }
                hasSidecarSRT = true
                _ = subtitleTrack.applyLoadedCues(sidecar.cues, sourceURL: sidecar.url)
                subtitleTrack.isEnabled = (captionSelection == .sidecar)
                Task { await viewModel.applySidecarSubtitlePresence(videoPath: videoPath, sidecarPresent: true) }
            } else if !Task.isCancelled {
                hasSidecarSRT = false
                Task { await viewModel.applySidecarSubtitlePresence(videoPath: videoPath, sidecarPresent: false) }
            }

            // Status monitoring: catch load failures that slip past the isPlayable check
            // (e.g. files that report playable but have an undecodable codec inside).
            guard let item = newPlayer.currentItem else { return }
            for await status in item.publisher(for: \AVPlayerItem.status).values {
                guard !Task.isCancelled else { return }
                if status == .failed {
                    playerError = item.error?.localizedDescription ?? "The file could not be opened for playback."
                    if !FileManager.default.fileExists(atPath: videoPath) {
                        viewModel.noteLibraryFileMissing(path: videoPath)
                    }
                    surfaceErrorKeepingPanel()
                    return
                } else if status == .readyToPlay {
                    // Item load can expose the legible group after the initial attempt.
                    await refreshInBandCaptionOptions(on: newPlayer)
                    return
                }
            }
        }
    }

    /// A playback attempt failed (unreachable file / unplayable codec / load error). Keep the panel
    /// mounted (`isPlayingInline` stays true) so the error overlay — with "Open in External Player" /
    /// "Dismiss" — is actually visible, instead of flipping `isPlayingInline` off, which unmounts the
    /// panel instantly and just reads as a flash. The error overlay lives in the in-window panel, so
    /// drop out of full-screen (if the "open at full screen" preference put us there) so it can show.
    private func surfaceErrorKeepingPanel() {
        if viewModel.isPlayerFullScreen { viewModel.isPlayerFullScreen = false }
        // Tear down any prior (now-stale) player so an earlier video doesn't keep playing behind the
        // error overlay when a *switch* to an unreachable file fails. No-op on a cold start (player nil).
        detachTimelineObservers()
        subtitleTrack.detach()
        player?.pause()
        player = nil
        currentTimeSeconds = 0
        durationSeconds = 0
        isPlaying = false
    }

    /// Tear down the player, persisting the current position so the next play can resume.
    func stop() {
        statusTask?.cancel()
        statusTask = nil
        persistPosition()
        cancelResumeBannerFadeTask()
        resumeBannerOpacity = 1
        detachTimelineObservers()
        subtitleTrack.detach()
        player?.pause()
        player = nil
        currentTimeSeconds = 0
        durationSeconds = 0
        isPlaying = false
        currentVideo = nil
        resetCaptionSession()
        clearReturnPoint()
        Task { await viewModel.reloadBookmarksForPlayback(video: nil) }
    }

    // MARK: - Intents

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            playAtConfiguredRate(player)
        }
    }

    func restartFromBeginning() {
        guard let player else { return }
        cancelResumeBannerFadeTask()
        didAutoResume = false
        resumedFromSeconds = nil
        resumeBannerOpacity = 1
        if let video = currentVideo {
            PlaybackPositionStore.clear(filePath: video.filePath)
            viewModel.notifyResumePositionsChanged()
        }
        player.pause()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
            guard let self, let player else { return }
            self.playAtConfiguredRate(player)
        }
    }

    /// Resume-banner "Start at beginning": clear the saved position and seek to 0.
    func startAtBeginning() {
        guard let player, let video = currentVideo else { return }
        cancelResumeBannerFadeTask()
        resumeBannerOpacity = 1
        didAutoResume = false
        resumedFromSeconds = nil
        PlaybackPositionStore.clear(filePath: video.filePath)
        viewModel.notifyResumePositionsChanged()
        player.seek(to: .zero) { [weak self, weak player] _ in
            guard let self, let player else { return }
            self.playAtConfiguredRate(player)
        }
    }

    /// Skip backward/forward by `skipSeconds` (timeline buttons / menu / ⌥←⌥→).
    func skipBy(_ delta: Double) {
        let resume = isPlaying
        seek(toSeconds: currentTimeSeconds + delta, resumePlayback: resume)
    }

    /// Smaller seek for ←/→ while playing.
    func nudgeBy(_ delta: Double) {
        let resume = isPlaying
        seek(toSeconds: currentTimeSeconds + delta, resumePlayback: resume)
    }

    func setPlaybackRate(_ rate: Float) {
        let allowed = Self.playbackRateChoices
        let chosen = allowed.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1.0
        playbackRate = chosen
        guard let player, isPlaying || player.timeControlStatus == .playing else { return }
        player.rate = chosen
    }

    func setVolume(_ value: Float) {
        let clamped = Self.clampedVolume(value)
        volume = clamped
        if clamped > 0.001 {
            lastAudibleVolume = clamped
            isMuted = false
        } else {
            isMuted = true
        }
        persistVolume()
        applyVolumeToPlayer(player)
    }

    func toggleMute() {
        if isMuted {
            isMuted = false
            if volume < 0.001 {
                volume = lastAudibleVolume
            }
        } else {
            isMuted = true
        }
        persistVolume()
        applyVolumeToPlayer(player)
    }

    /// SF Symbol for the current mute/level state.
    var volumeSymbolName: String {
        if isMuted || volume < 0.001 { return "speaker.slash.fill" }
        if volume < 0.33 { return "speaker.wave.1.fill" }
        if volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// Hide the Captions control when this play has neither a sidecar nor in-band options.
    var showsCaptionsControl: Bool {
        hasSidecarSRT || !inBandCaptionOptions.isEmpty
    }

    /// Fill/accent the captions icon when anything other than Off is selected.
    var captionsAreActive: Bool {
        captionSelection != .off
    }

    var captionsAccessibilityValue: String {
        switch captionSelection {
        case .off:
            return "Off"
        case .sidecar:
            return "Sidecar"
        case .inBand(let id):
            return inBandCaptionOptions.first(where: { $0.id == id })?.title ?? "On"
        }
    }

    func selectCaptionOff() {
        captionSelection = .off
        subtitleTrack.isEnabled = false
        Task { await applyLegibleMediaSelection(on: player) }
    }

    func selectSidecarCaptions() {
        guard hasSidecarSRT else { return }
        captionSelection = .sidecar
        subtitleTrack.isEnabled = true
        Task { await applyLegibleMediaSelection(on: player) }
    }

    func selectInBandCaption(id: String) {
        guard inBandCaptionOptions.contains(where: { $0.id == id }) else { return }
        captionSelection = .inBand(id: id)
        subtitleTrack.isEnabled = false
        Task { await applyLegibleMediaSelection(on: player) }
    }

    private static func clampedVolume(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private func persistVolume() {
        let defaults = UserDefaults.standard
        defaults.set(volume, forKey: Self.volumeDefaultsKey)
        defaults.set(isMuted, forKey: Self.mutedDefaultsKey)
    }

    private func applyVolumeToPlayer(_ player: AVPlayer?) {
        guard let player else { return }
        player.volume = volume
        player.isMuted = isMuted || volume < 0.001
    }

    private func resetCaptionSession() {
        captionSelection = .off
        hasSidecarSRT = false
        inBandCaptionOptions = []
        subtitleTrack.isEnabled = false
    }

    /// Reloads named in-band tracks and applies the current menu selection (nil unless in-band).
    private func refreshInBandCaptionOptions(on player: AVPlayer) async {
        guard player === self.player, let item = player.currentItem else { return }
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
            inBandCaptionOptions = []
            return
        }
        inBandCaptionOptions = group.options.enumerated().compactMap { index, option in
            guard option.isPlayable else { return nil }
            return InBandCaptionOption(
                id: CaptionMenuCopy.id(for: option, index: index),
                title: CaptionMenuCopy.title(for: option),
                option: option
            )
        }
        await applyLegibleMediaSelection(on: player, group: group)
    }

    /// Off and Sidecar select **nil** in the legible group (auto-select stays off). In-band
    /// selects that option. Sidecar overlay is a custom `SubtitleTrack`, not this selection.
    private func applyLegibleMediaSelection(on player: AVPlayer?, group: AVMediaSelectionGroup? = nil) async {
        guard let player, player === self.player, let item = player.currentItem else { return }
        let resolvedGroup: AVMediaSelectionGroup
        if let group {
            resolvedGroup = group
        } else if let loaded = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
            resolvedGroup = loaded
        } else {
            return
        }
        switch captionSelection {
        case .off, .sidecar:
            item.select(nil, in: resolvedGroup)
        case .inBand(let id):
            if let option = inBandCaptionOptions.first(where: { $0.id == id })?.option {
                item.select(option, in: resolvedGroup)
            } else {
                item.select(nil, in: resolvedGroup)
            }
        }
    }

    static func formatPlaybackRate(_ rate: Float) -> String {
        if abs(rate - 1) < 0.001 { return "1×" }
        if abs(rate - rate.rounded()) < 0.001 { return "\(Int(rate.rounded()))×" }
        return String(format: "%g×", rate)
    }

    /// "Make Thumbnail from Current Frame" (pro feature): capture the exact frame on screen right now
    /// and set it as this video's library thumbnail + detail-preview still, replacing whatever was
    /// there. Unlike "Regenerate Thumbnail" (random position), this gives the user precise control by
    /// scrubbing to the exact moment they want first.
    func makeThumbnailFromCurrentFrame() {
        guard let player, let video = currentVideo else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        Task {
            guard let url = try? await viewModel.thumbnailService.captureCurrentFrameAsThumbnail(
                for: video, atSeconds: seconds
            ) else { return }
            await viewModel.setRegeneratedThumbnailPath(videoPath: video.filePath, url: url)
        }
    }

    /// Bookmark the current playback position (named + still). Requires a DB-backed video.
    /// Title defaults to the timecode; rename inline in the Inspector.
    func addBookmarkAtCurrentTime() {
        guard let player, let video = currentVideo else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        Task {
            await viewModel.addBookmark(for: video, atSeconds: seconds)
        }
    }

    /// Seek the live player (precise frame). When `resumePlayback` is true (default), play after seek
    /// — used for bookmark jumps. Scrubbing passes `false` so drag doesn’t force play.
    func seek(toSeconds seconds: Double, resumePlayback: Bool = true) {
        guard let player else { return }
        guard seconds.isFinite, seconds >= 0 else { return }
        let clamped: Double = {
            if durationSeconds > 0 { return min(max(0, seconds), durationSeconds) }
            return max(0, seconds)
        }()
        currentTimeSeconds = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] _ in
            guard let self, let player else { return }
            if resumePlayback {
                self.playAtConfiguredRate(player)
            }
        }
    }

    /// Remember the current playhead before jumping away to a bookmark (session-only).
    func rememberReturnPointBeforeJump(to destinationSeconds: Double) {
        let here = currentTimeSeconds
        guard here.isFinite, here >= 0 else { return }
        guard abs(here - destinationSeconds) >= Self.returnPointMinDeltaSeconds else { return }
        returnPointSeconds = here
        // Catch-up dismiss only when the leave point remains ahead (jumped backward).
        returnPointClearsOnCatchUp = here > destinationSeconds
        // Diamond clicks can also hit the scrub DragGesture; don't let that wipe the new return point.
        suppressReturnClearFromScrub = true
        DispatchQueue.main.async { [weak self] in
            self?.suppressReturnClearFromScrub = false
        }
    }

    func clearReturnPoint() {
        returnPointSeconds = nil
        returnPointClearsOnCatchUp = false
    }

    /// Scrubber seek (click/drag) dismisses the return point — unless a bookmark jump just set it.
    func clearReturnPointFromScrub() {
        guard !suppressReturnClearFromScrub else { return }
        clearReturnPoint()
    }

    /// When playback crosses the leave point from earlier times, the live playhead takes over.
    private func clearReturnPointIfPlayheadReached(from previous: Double, to current: Double) {
        guard returnPointClearsOnCatchUp, let returnSeconds = returnPointSeconds else { return }
        // Ignore seek discontinuities / stale observer callbacks around bookmark jumps.
        let delta = current - previous
        guard delta > 0, delta < 1.25 else { return }
        let slack = 0.05
        guard previous < returnSeconds - slack, current >= returnSeconds - slack else { return }
        clearReturnPoint()
    }

    /// Seek back to the session return point (chip), then dismiss the chip.
    func returnToSavedPoint() {
        guard let seconds = returnPointSeconds else { return }
        clearReturnPoint()
        seek(toSeconds: seconds)
    }

    /// Play (or resume) at the user’s chosen rate — `play()` alone would reset to 1×.
    private func playAtConfiguredRate(_ player: AVPlayer) {
        player.playImmediately(atRate: max(playbackRate, 0.05))
        isPlaying = true
    }

    func dismissError() {
        playerError = nil
    }

    func openInExternalPlayer(_ video: Video) {
        playerError = nil
        NSWorkspace.shared.open(video.url)
        Task { await viewModel.recordPlay(for: video) }
    }

    // MARK: - Resume banner fade settings

    func onFadeSettingChanged(enabled: Bool) {
        if !enabled {
            cancelResumeBannerFadeTask()
            resumeBannerOpacity = 1
        } else if didAutoResume {
            scheduleResumeBannerFadeIfNeeded()
        }
    }

    func onFadeDelayChanged() {
        if didAutoResume, viewModel.fadeResumeBannerAutomatically {
            scheduleResumeBannerFadeIfNeeded()
        }
    }

    // MARK: - Persistence

    func persistPosition() {
        guard let player, let video = currentVideo else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return }
        PlaybackPositionStore.saveSeconds(seconds, filePath: video.filePath)
        viewModel.notifyResumePositionsChanged()
    }

    // MARK: - Timeline observers

    private func attachTimelineObservers(to newPlayer: AVPlayer, fallbackDuration: Double?) {
        detachTimelineObservers()
        durationSeconds = fallbackDuration ?? 0
        currentTimeSeconds = max(0, newPlayer.currentTime().seconds)
        isPlaying = newPlayer.timeControlStatus == .playing

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite, seconds >= 0 {
                let previous = self.currentTimeSeconds
                self.currentTimeSeconds = seconds
                // After a jump-back bookmark, dismiss ghost + Return chip once playhead catches the leave point.
                self.clearReturnPointIfPlayheadReached(from: previous, to: seconds)
            }
            if let item = newPlayer.currentItem {
                let d = item.duration.seconds
                if d.isFinite, d > 0 {
                    self.durationSeconds = d
                }
            }
            self.isPlaying = newPlayer.timeControlStatus == .playing
        }

        timeControlObservation = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }

        if let item = newPlayer.currentItem {
            attachEndObserver(for: item)
        }
    }

    private func attachEndObserver(for item: AVPlayerItem) {
        detachEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleItemDidPlayToEnd()
            }
        }
    }

    private func handleItemDidPlayToEnd() {
        isPlaying = false
        if let video = currentVideo {
            PlaybackPositionStore.clear(filePath: video.filePath)
            viewModel.notifyResumePositionsChanged()
        }
        viewModel.advancePlayAllIfNeeded()
    }

    private func detachEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func detachTimelineObservers() {
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        detachEndObserver()
    }

    // MARK: - Internals

    private func cancelResumeBannerFadeTask() {
        resumeBannerFadeTask?.cancel()
        resumeBannerFadeTask = nil
    }

    private func scheduleResumeBannerFadeIfNeeded() {
        cancelResumeBannerFadeTask()
        guard viewModel.fadeResumeBannerAutomatically else { return }
        let delay = max(1, viewModel.resumeBannerFadeDelaySeconds)
        resumeBannerFadeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { resumeBannerOpacity = 0 }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            didAutoResume = false
            resumedFromSeconds = nil
            resumeBannerOpacity = 1
        }
    }
}
