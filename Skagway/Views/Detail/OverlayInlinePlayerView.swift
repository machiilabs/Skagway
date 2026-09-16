import AVKit
import AppKit
import SwiftUI

/// Renders the shared `InlinePlaybackController` player — the player view, sidecar-subtitle overlay,
/// resume banner, error overlay, and a compact header. A pure renderer: lifecycle (start/stop) is
/// driven from `ContentView` via `isPlayingInline`. Hosted by `FloatingPlayerPanel` (the in-window
/// resizable surface); the same player carries into the borderless full-screen window.
struct OverlayInlinePlayerView: View {
    let video: Video
    @Bindable var viewModel: LibraryViewModel
    /// Whether the title bar is currently shown — driven by `FloatingPlayerPanel`'s idle
    /// chrome tracking, so this fades in/out together with the panel's other controls.
    let controlsVisible: Bool

    private var playback: InlinePlaybackController { viewModel.playback }

    var body: some View {
        ZStack(alignment: .top) {
            // Deep background so the framed player feels grounded inside the panel.
            Color.appBackground

            if let player = playback.player {
                // The actual player is framed to feel like a deliberate piece of media
                // rather than raw video bleeding to the edges of the panel.
                ZStack(alignment: .bottom) {
                    FloatingPlayerView(player: player, showsFullscreenButton: false,
                                       onRestartFromBeginning: { playback.restartFromBeginning() })

                    PlaybackTimelineBar(
                        viewModel: viewModel,
                        controlsVisible: controlsVisible
                    )
                        // Do not clipShape the bar — the scrub hover preview draws above the
                        // track into the video. Corner rounding comes from `.appMediaFrame`.
                        .frame(maxWidth: .infinity, alignment: .bottom)
                }
                .appMediaFrame(cornerRadius: AppRadius.lg)
                .padding(.horizontal, 10)
                .padding(.top, 34)   // leave room for the (25%-larger) header, always — it
                                     // occupies this space whether visible or faded out
                .padding(.bottom, 4) // keep panel chrome close under the timeline transport row

                SubtitleOverlayContainer(track: playback.subtitleTrack)

                if playback.didAutoResume, let resumeSecs = playback.resumedFromSeconds {
                    resumeOverlay(resumedFromSeconds: resumeSecs) {
                        playback.startAtBeginning()
                    }
                    .opacity(playback.resumeBannerOpacity)
                    .padding(.horizontal, 10)
                    .padding(.top, 40)   // clear the header strip
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            // Minimal header bar — signals that this is a placed, first-class player panel
            // rather than video that just happens to be here. Only shown with idle chrome (see
            // `FloatingPlayerPanel`), fading with the rest of the panel's controls.
            overlayHeader
                .opacity(controlsVisible ? 1 : 0)

            if let playerError = playback.playerError {
                errorOverlay(playerError)
            }
        }
        // Start/stop is driven by ContentView (from `isPlayingInline`), not this view's lifecycle, so
        // the panel can unmount/remount (e.g. entering/leaving full-screen) without tearing down the
        // player. This view is a pure renderer of the shared controller's state.
        .onChange(of: viewModel.fadeResumeBannerAutomatically) { _, enabled in
            playback.onFadeSettingChanged(enabled: enabled)
        }
        .onChange(of: viewModel.resumeBannerFadeDelaySeconds) { _, _ in playback.onFadeDelayChanged() }
    }

    // Header for the floating player. Leading room for the traffic-light cluster drawn by
    // `FloatingPlayerPanel` (above the drag layer). Escape and the bottom Stop button still
    // end playback.
    private var overlayHeader: some View {
        HStack(spacing: 0) {
            // Match traffic-light leading inset + cluster + gap (lights drawn in FloatingPlayerPanel).
            Color.clear
                .frame(width: PlayerTrafficLights.leadingChromeWidth)
            Text((playback.currentVideo ?? video).displayTitle)
                // 14pt / 30pt bar — 25% larger than the original 11pt / 24pt, matching the
                // size-control buttons in FloatingPlayerPanel.
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 10)
        }
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Rectangle()
                .fill(Color.appSurface.opacity(0.92))
                .overlay(Rectangle().fill(Color.appDivider.opacity(0.6)).frame(height: 0.5), alignment: .bottom)
        )
    }

    // MARK: - Overlays

    private func resumeOverlay(resumedFromSeconds: Double, startAtBeginning: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text("Resumed at \(formatTimestamp(resumedFromSeconds))")
                .font(.caption)
                .foregroundStyle(Color.appTextPrimary)
            Button("Start at beginning", action: startAtBeginning)
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .controlSize(.small)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(Material.appFloatingMaterial, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(Color.appAccent.opacity(0.35), lineWidth: 1)
        )
    }

    private func errorOverlay(_ message: String) -> some View {
        let missingOnDisk = !FileManager.default.fileExists(
            atPath: (playback.currentVideo ?? video).filePath
        )
        return ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: AppSpacing.lg) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.yellow)
                Text("Playback Failed")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                if missingOnDisk {
                    Text("Library folder missing — repair links if you moved the folder tree.")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                HStack(spacing: AppSpacing.md) {
                    if missingOnDisk {
                        Button("Repair Links…") {
                            let path = (playback.currentVideo ?? video).filePath
                            viewModel.noteLibraryFileMissing(path: path)
                            viewModel.beginLocationRelink(
                                preferredOldRoot: viewModel.libraryFolderMissingBannerPreferredRoot
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appAccent)
                        .controlSize(.small)

                        Button("Open in External Player") {
                            playback.openInExternalPlayer(video)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.appAccent)
                        .controlSize(.small)
                    } else {
                        Button("Open in External Player") {
                            playback.openInExternalPlayer(video)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appAccent)
                        .controlSize(.small)
                    }
                    Button("Dismiss") {
                        playback.dismissError()
                        viewModel.isPlayingInline = false
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.appAccent)
                    .controlSize(.small)
                }
            }
            .padding(AppSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(Material.appFloatingMaterial)
                    .background(Color.appSurface.opacity(0.7))
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
