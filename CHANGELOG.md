# Changelog

**Skagway changelogs are maintained live by agents.**

## How maintenance works (for agents)

**Two phases:**

1. **Live updates (development / every commit)**
   - After changes + `bash scripts/build_and_install.sh`, append high-level summaries to the `## Unreleased` section.
   - Do this before or as part of the commit.

2. **Consolidation (on release)**
   - After running the build script for a release, convert the `## Unreleased` content into a new release header:
     ```
     ## X.Y.Z (build NNN) - YYYY-MM-DD
     ```
   - Clear the Unreleased section.
   - The release commit message should align with the consolidated text.

Most recent releases sit directly after the Unreleased section.

See `AGENTS.md` and `.cursor/rules/build-deploy.mdc` for the full agent and release workflow.

### Agent quick checklist
- After `bash scripts/build_and_install.sh` → append high-level bullets to `## Unreleased`.
- Before committing → ensure the Unreleased section accurately reflects the changes in this commit.
- On release (after the final build) → promote Unreleased content into a versioned header and clear it.

---

## Unreleased

- **Quick → Advanced compile** — Switching to the Advanced tab compiles active Quick filters into one rule tree (e.g. collection + ANY tags + rating 4+ becomes Parent Folder equals Demo AND (Tag equals trees OR Tag equals outdoor) AND Rating is at least 4).
- **Filter tab shortcuts** — **⌘⌥Q** (Quick) and **⌘⌥A** (Advanced) switch filter drawer tabs; opens the drawer if it is closed.
- **Unified Filter drawer** — Single **Filter** entry point (slider icon, ⌘⇧F): Quick and Advanced are tabs inside one drawer (last tab persists). Slider uses accent fill when a filter is active and the drawer is closed. ⌘⇧V removed; opening or switching tabs no longer clears the other mode’s in-memory state — only the active tab’s stack applies to matching. Collection pill → Advanced preview keeps the Quick selection so toggling Quick/Advanced tabs does not drop the filter.
- **Collection rule synopsis** — Selecting a smart collection in Quick Filter shows a compact summary of its conditions in the header pill (prefixed with the collection name; multiple rules show the first condition plus “…”, e.g. “Popular: Rating is at least 4 …”) and as a muted caption under the selected row in the drawer. Clicking the pill opens the collection in Advanced Filter; closing the drawer without edits keeps the collection pill (the ✕ still clears it). Fixed reopening the pill after a preview close showing a stale empty Title rule.
- **Custom field empty filters** — Advanced Filter and Smart Collections support **is empty** / **is not empty** on custom metadata fields (unset, blank, or whitespace-only values).
- **Sparkle publish checklist** — Release workflow, `docs/SPARKLE.md`, and `package_dmg.sh` now require uploading both `Skagway.dmg` + `Skagway.appcast.xml` to R2 and passing `scripts/verify_sparkle_publish.sh` before announcing a release (prevents “improperly signed” updates when CDN serves a stale DMG).
- **Build / install cleanup** — `build_and_install.sh` and `package_dmg.sh` now run `cleanup_stray_skagway_apps.sh` after install/package: removes DerivedData and Sparkle appcast cache copies, ejects leftover install DMG volumes, rebuilds Launch Services, and re-registers `/Applications/Skagway.app` so Launchpad does not accumulate duplicate Skagway icons.

## 1.1.0 (build 1045) - 2026-09-12

- **Review mode** — Collect a set of videos while watching clips: Grid and List share focus vs collected-set semantics (plain click = focus; collect circle with plain/⌘/⇧/⌥; A to add focused row to set). Inspector and context menus respect the collected set. `ReviewSession` + unit tests (`ReviewSessionTests`, `ListReviewTableSelectionTests`).
- **Review mode in List view** — List mirrors Grid Review behavior: Table highlight follows review focus while the collected set is built separately. Context menus respect the collected set when right-clicking a collected row. Per-row hover tracking fixes collect circles flickering between rows.
- **List hover preview** — Hovering a List thumbnail opens an enlarged click-through floating panel (including in Review) with the same muted cycling scrub as Grid cards when hover preview is enabled. List double-click plays inline like Grid.
- **List Review polish** — ⌘/⇧/⌥ clicks work on the first press while the hover preview is open. Preview panel is vertically centered on its row. Thumbnail handler applies modifier selection directly.
- **Review collect circles** — Grid and List collect circles honor ⌘/⇧/⌥ (⇧-click range-collects from the last circle click; ⇧-range unions into the set). Collect-badge hit areas are constrained so live hover previews keep working after collecting.
- **List hover preview reliability** — Fixed live preview dying after hovering several List rows: the floater no longer restarts playback on every Table re-render. Preview is driven from show/hide via `ListHoverPreviewDriver`; hide stops players and releases panel content.

## 1.0.0 (build 1014) - 2026-09-03

- **First 1.0.0** — Readiness pass complete: 107 unit tests, 12,174-video perf PASS (watch: sort ~2–2.5 s), feature audit (nothing 1.0-critical half-finished), Bugbot review, local FS/ffmpeg/no-telemetry security PASS.
- **Docs** — `ROADMAP.md` Current State is as of 0.80/1.0. No built-in notes (custom Text). Manual is machii-labs `/skagway/manual` (0.80 copy + recaptured screenshots). Mac App Store dropped. Sparkle feed publish remains GTM.
- **Testable cores** — `RatingQuickFilter`, `VideoIntegrity`, `PlayAllAdvance` extracted for unit coverage of rating filter, Play All skip/loop, corrupt heuristic, collection AND/OR, fingerprints, and migrations.

## 0.80.0 (build 1011) - 2026-09-03

- **Quick Filter rating: “Or Higher” and “No Stars”** — The Rating card is one row: **No Stars**, then 1–5, then **Or Higher** on the right. Off (default) matches only the star you click. On, the Or Higher pill fills a clearly visible light grey and that rating plus every higher one match (4 → 4 and 5). The star row still fills 1 through the clicked star; Or Higher does not light stars above it. **No Stars** and **5 stars** disable Or Higher. Or Higher is session-only (not persisted). The filter pill reads `Rating 4`, `Rating 4+`, or `No stars`.

## 0.79.0 (build 999) - 2026-08-26

- **Play All + album playlists** — **Play All** (⌘⇧P) plays the current view (album, smart collection, tags, search, etc.) from the first video. Auto-advance and **Loop Play All** only run during that session; stopping playback or playing a single video ends it. Loop is off by default (toolbar, View menu, Settings). Albums still keep a saved order with drag-and-drop; that reorder is album-only. Missing files are skipped.
- **Album order + drag-and-drop** — Albums keep a saved playlist order. Viewing an album shows that order (Sort menu: Album Order) and an accent grip on each thumbnail. Click-and-drag a card (or list row) onto another to reorder — no special modifier key. Dropping on a later card inserts after it. Multi-select moves as a block. Added videos append at the end.

## 0.78.0 (build 988) - 2026-08-15

- **Data Sources: Exclude Folder** — Hover a scanned folder and choose Exclude… to skip a subfolder (and its contents) during Scan, Scan for New Videos, Add Folder, and dropped files. Excludes nest under the deepest matching include; removing an include deletes excludes that no longer sit under any source. The source folder itself cannot be excluded. Videos already in the library are left alone.
- **Import Metadata writes Plays and Resume Position** — Those columns are now importable: play count is set (not incremented), and resume seconds are restored on the matched video’s current path. Empty cells still leave the current value alone. Last Played stays export-only.

## 0.77.0 (build 983) - 2026-08-09

- **Per-library thumbnail cache** — Each library stores its cache location in the DB (`library_cache`), so opening LibB never depends on Enc’s cache from LibA. Startup: Use standard location (App Support + system Caches), or Choose Folder… then pick co-locate / system default / custom folder, then remember vs ask-each-launch. Settings/File → Change Thumbnail Cache Location… retargets the open library only (Settings shows the current path above the button). Save Copy keeps the original cache pointer. Legacy app-wide cache prefs are seed-only and only adopted when they clearly belong to that library.
- **Player traffic lights** — Play chrome shows a macOS-style red/yellow/green cluster (top-leading). Windowed: stop / Compact / Full. Compact (Option B ladder): stop / Windowed / Full. Fullscreen: stop / Compact / Windowed. Bottom size controls stay. Idle-hide matches existing chrome.
- **Set Poster from Image** — Context menu (grid + list) chooses an image as the library poster for one or many selected videos (same image for all). Dragging an image onto a Wall card sets that video’s poster; dragging videos/folders onto the grid still imports into the library. Filmstrips are unchanged; Regenerate Thumbnail still replaces a custom poster with a frame from the file.

## 0.76.0 (build 972) - 2026-07-31

- **Last Added smart library** — Shows videos imported by the most recent media-add scan (Import New, Add Folder, Add Files, drop). Appears when non-empty, auto-selects after a scan that added videos; empty scans leave the previous set.
- **Subtitles field is now four values** — Inspector dropdown: None / Burned-in / Sidecar / Burned-in + Sidecar. Scan and playback detect sidecar `.srt` files without wiping a user-set Burned-in mark (removing a sidecar from “both” reverts to Burned-in). Export/import and Bulk Rename `{Subtitles}` use the display labels (legacy Yes/No still import).
- **Fix: empty-library invite flash on launch** — A populated library no longer briefly shows the empty-browser drop-zone invite while the first video list observation is still in flight; the invite only appears after load completes and the catalog is actually empty.
- **Bulk Rename case transforms** — Distinct title case (`title` / `T`: The Quick Brown Fox) vs name case (`name` / `N`: The quick brown fox). `{Stem}` honors case args (`{Stem title}`, `{Stem name}`, etc.).
- **Empty browser invite** — An empty library shows a dotted drop zone in the browser (highlights while dragging), File → Add Folder… (⇧⌘O), and an Add Files… button that accepts files or folders. Copy explains that added folders (or parent folders of files) become Data Sources in Settings. Dropping folders onto the browser now scans them.
- **No second landing chooser** — After first-launch home setup, Standard and Remember modes open the home library automatically (creating it if missing). Ask-each-launch and Close Library show a minimal empty window; create/open/recent stay on the File menu. Choosing a new empty home folder creates a new empty library (no longer copies the previous home).
- **Fix: Missing smart library vs Exclude Corrupt** — Viewing Missing no longer applies Exclude Corrupt first. Absent files often look “corrupt” (no thumbnail / probe data), which hid them from the grid while the Missing badge still counted them.
- **Bulk Rename: cancel, results, and temp recovery** — Apply no longer dismisses silently: Cancel stops mid-batch and restores staged temps; a results screen shows renamed / failed / restored counts with Retry Failed; launch sweeps leftover `.skagway-bulk-…` names back to originals. Progress stays in the rename dialog (no activity-strip progress).
- **Move Queue auto-clears successful jobs** — After a batch finishes, completed moves are removed automatically so the header pill / menu only remain for failures (or active work). Re-encode still keeps completed rows while backups need management.
- **Re-encode Queue stays reachable after jobs finish** — While kept `_backup` files remain, the header re-encode pill (and **View → Re-encode Queue…**) open the queue for Delete Backup / Restore. **View → Move Queue…** likewise opens move history when present.

## 0.75.0 (build 953) - 2026-07-24

- **Search covers more library fields** — Library search now matches title, file name, original file name, tags, and custom metadata values (AND across terms; case-insensitive contains).
- **Fix: Custom Metadata fields are per-library** — Field definitions now live in each library database (`custom_metadata_field`) instead of global UserDefaults, so libraries no longer share the same schema. Existing definitions are seeded once from the legacy prefs key when a library’s table is empty (preserving field UUIDs and values). Removing a field also deletes its stored values.
- **Original File Name** — Stored at import and never changed by rename/move/convert. Available in Export Metadata and Bulk Rename (`{Original File Name}`); existing libraries backfill from the current file name.
- **Bulk Rename** — Pattern-based on-disk rename for the filtered set or selection (`File → Bulk Rename…`, context menu). Searchable field list covers built-ins and custom metadata; free text + `{Token}` patterns with caret insert and token selection; optional date/duration format args (`{Date Created MMM-yyyy}`, `{Duration mmm}` / `{Duration sss}`), case transforms (`{Title lower|UPPER|Name}` / `L|U|N`), and specials `{Inc}`, `{Conflict}`, `{Stem}`, `{Date …}`, `{UUID8}`; live preview with collision / empty / length skips and a **No extension** warning (still renameable); two-phase apply with progress; preserves library metadata.

## 0.74.0 (build 938) - 2026-07-24

- **Fix: Open Recent in Remember mode** — Bookmark-only library homes now keep Open Recent via opaque bookmarks (still no plain path list). Opening Home or any other library records it; ask-each-launch no longer skips Recents.
- **Library titles** — Each video has a library Title (seeded from the file name on import) separate from the on-disk file name. List, grid, inspector, player chrome, sort, search, and smart-library rules use the title; **Edit Title…** / Enter edits the title without renaming the file; **Rename File…** still renames on disk. Disk rename/move/convert keeps the title in sync when it still matched the old file name. Metadata export/import includes Title as an importable column.
- **Library home setup** — First-launch screen: nothing leaves your Mac (no data sent to Mach II Labs; no analytics); Skagway is not a vault (does not modify or protect source media); user chooses where the catalog + thumbnail cache live — Choose Folder when media is on an encrypted volume, Standard when it is not. After Choose Folder: **Remember this location** (bookmark-only in prefs — no plain paths) or **Ask every time** (no location on the boot disk; open library each launch). Cache folder is named **Skagway-cache**. **Change Library & Cache Location…** re-runs the chooser. **Library Lock** cancelled — encrypted-volume placement is the privacy model.
- **Home library** — File / landing “Open Home Library” opens the startup location you chose and shows that path in the tooltip. If you chose a folder at setup, there is no Application Support “default” library — launch never falls back to it.
- **Save Copy** — Panel explains that a single `.machii` is a complete library; `-wal` / `-shm` are temporary and do not need to be copied. Finder Tags field hidden on Save Copy / New Library panels (not Skagway tags).
- **Fix: Open Recent → Clear Menu** — Clears the list immediately in the File menu (and landing), and no longer re-adds the default library to recents on every launch.

## 0.73.0 (build 915) - 2026-07-23

- **Settings** — Replaced the Form-based Settings window with the fully custom chrome proven in Fun Component (Settings… / ⌘,). Removed the Fun Component menu item and the old Form category views. Search field includes a clear control when non-empty; Custom Metadata Manage / New field are searchable; search results no longer multi-highlight by shared category.
- **Filmstrip defaults & regenerate** — Default layout is 2×5 (was hardcoded 2×4 in generation). Inspector generates missing filmstrips using Settings rows/columns. Modify Filmstrip supports multi-select with progress/Stop, seeds steppers from the cached grid for a single video (Settings default for multi), uses the Settings-style integer stepper, cancels in-flight builds, and shows specific errors (e.g. “File does not exist”). **Regenerate filmstrips** advances a cache epoch so old composites are ignored immediately (background cleanup deletes orphans), then rebuilds the selected video at the new grid.
- **Help → Skagway Help** — Opens the online manual at `https://machiilabs.com/skagway/manual` (replaces the unused system Help placeholder).

## 0.72.0 (build 892) - 2026-07-22

- **Export Metadata field groups** — Fields list is sectioned into Match keys (Path / Content Fingerprint), Importable (Rating, Tags, custom fields), and Export only (size, duration, codec, …), so round-trip vs informational columns are obvious before export.

## 0.71.0 (build 889) - 2026-07-22

- **Bottom activity strip** — Long-running work (scan, fingerprint, metadata import/export, re-encode, move, bulk delete) and transient errors move to a bottom strip under the wall/inspector split. Header keeps the video count; conversion/move queues collapse to icon-only when the strip already shows that job.
- **Install while running after DMG/Sparkle** — `build_and_install.sh` no longer bails when `com.apple.macl` blocks in-place rsync; it rename-asides and replaces even if Skagway is open (old binary stays mapped until relaunch).
- **Cross-volume move progress + Abort** — Moves use Darwin `copyfile` with live % (queue + activity strip). Per-job Abort and **Abort All** stop the in-flight copy (latch + `COPYFILE_QUIT`), drop the `.moving` partial, and clear queued jobs; source files stay untouched.

## 0.70.0 (build 883) - 2026-07-21

- **Sparkle update verification** — Minor bump to exercise Check for Updates against 0.69.0 installs (notarized DMG + appcast).

## 0.69.0 (build 882) - 2026-07-21

- **Check for Updates (Sparkle)** — Skagway → Check for Updates…; Settings → Library → Automatically check for updates (default off). Feed URL `https://downloads.machiilabs.com/Skagway.appcast.xml`; packaging emits the appcast for publish (see `docs/SPARKLE.md`).
- **Help → Contact Support…** — Opens a mail message to support@machiilabs.com with subject “Skagway support request”.
- **Playback transport idle hide** — Mouse-wheel / trackpad scrolling over the video keeps the transport visible (floating and fullscreen); hide resumes after scrolling stops.

## 0.68.0 (build 877) - 2026-07-21

- **Custom Settings window** — Replaces the system `Settings` scene with a normal `Window` (hidden title bar) so chrome is fully controllable: left-aligned sheet titles, in-content sidebar search, ⌘, to open/focus. Same sidebar categories and form panes as before.
- **Settings chrome** — Sidebar charcoal RGB 21, 24, 26; detail sheet RGB 35, 39, 40.
- **Settings list sheets** — Data Sources / Extensions / Custom Metadata use the same grouped Form list treatment; hover Remove on rows; sidebar “File Ext” renamed to “Extensions”.

## 0.67.0 (build 850) - 2026-07-20

- **Tahoe-style Settings** — Sidebar + detail shell with category search. Descriptions sit under control titles inside the same list row (System Settings style), not as section footers. Library “Exclude corrupt…” and “Confirm deletions” share one grouped list. Shared integer field+chevron stepper; Tools/File Ext Form rows. Data Sources and Custom Metadata list UIs deferred.
- **Settings cleanup** — Removed unused Video settings “Maximum large preview thumbnail” and “Auto adjust video pane” (VideoMaster leftovers; prefs were never read by current UI).
- **Context menu** — “Re-encode to MP4…” renamed to “Fix for Built-in Player…” (matches Tools settings copy).
- **Settings search** — Search finds individual settings (and sheets) by title/keywords; choosing a result opens that sheet.
- **Settings** — Library tab section renamed from “Sidebar Filters” to “Smart Libraries”.
- **Export fields list** — Checked metadata columns stay at the top of the export dialog (relative order preserved within checked and unchecked groups).
- **Bookmark diamond name on hover** — Hovering a scrubber bookmark diamond shows its name in a capsule above the track (same AppKit hover path as scrub preview; no system tooltip).
- **Fix: Collection create/edit not saving** — Libraries whose `collection_rule` table lacked an `id` primary key (from an early migration) failed rule inserts; the editor swallowed the error and dismissed anyway. Migration adds the column; save is transactional and surfaces failures.

## 0.66.0 (build 828) - 2026-07-20

- **Floating player edge resize** — Drag any edge or corner to resize in Windowed mode (no handle); resize cursors on hover. Opposite side stays anchored. Compact keeps inspector-locked sizing (no edge hits). Size/close chrome still wins over the bottom-trailing corner.

## 0.65.0 (build 825) - 2026-07-20

- **Transport volume** — Mute toggle + compact volume slider on the custom transport row (below the scrubber), in the leading control cluster so floating size/close chrome doesn’t cover it. Leading controls keep layout priority so Compact no longer crushes speed/volume; very narrow widths fall back to mute-only. Level and mute persist across launches; applied to each new player. Hover previews stay independently muted.
- **Session return chip** — Jumping to a bookmark while playing stashes the playhead you left; a transport chip (`↩` + time) seeks back and dismisses. Session-only — also cleared when the player closes (not a bookmark, not resume).
- **Library choice survives rebuilds** — Active library and Recents are remembered by file path (not only security-scoped bookmarks). Bookmark resolve failures after re-signing no longer wipe the active library or prune Recents.
- **Custom playback timeline** — Skagway-owned transport bar is the sole scrubber (AVPlayerView floating controls removed): play/pause, click/drag seek, times, and bookmark ticks. Full-width scrubber; hover shows a pointer-aligned preview of the frame at that time (not bookmark stills). Extra height below the track so corner size/close chrome doesn’t sit on the line. Resume stays a separate automatic store.
- **Scrubber hover preview fix** — Preview was clipped away (and SwiftUI hover was blocked by the seek drag gesture); now uses AppKit mouse tracking and draws above the track into the video.
- **Faster scrub hover previews** — Dedicated warm decoder (not queued behind grid thumbnails), keyframe seeks, instant cache hits, and neighbor prefetch so the preview updates snappier while scrubbing.
- **Double-click scrubber to bookmark** — Anywhere a single click would move the playhead, double-click bookmarks at the pointer and leaves playback/playhead unchanged.
- **Skip, nudge, and playback speed** — ±15s skip, ←/→ nudge, and speed menu live *below* the full-width scrubber (never compress the track). Also under View; ⌥←/⌥→ skip.
- **Fullscreen scrub hover preview** — Hover along the scrubber in fullscreen shows the frame preview (same as compact/windowed); uses a window-scoped mouse monitor only in the borderless fullscreen player so floating-panel idle chrome stays intact.
- **Floating player idle chrome** — Compact/windowed match fullscreen: transport/title/size chrome hide after inactivity even while the cursor rests on the video; stay up over the transport or title strip; any move over the panel shows them again.
- **Fullscreen Esc stops playback** — Escape always stops play (including fullscreen), so “Last used size” can remember fullscreen. ⌃⌘F and the exit control still return to the floating player.
- **Fullscreen custom timeline** — Full-screen transport: idle hide with movement-threshold activity (ignores tracking jitter); hide no longer rebuilds tracking areas (that was immediately re-showing chrome). Windowed/compact panel hover auto-hide restored by removing the scrubber’s app-wide mouse monitor that thrashed SwiftUI `.onHover`.
- **Video bookmarks** — Named points of interest (timestamp + title + frame still) stored per video in the library DB. Bookmark while playing (⌥⌘B / View menu); rename inline in the Inspector (title focuses after add); jump via still/play. Resume playback stays a separate automatic “continue watching” position.

## 0.64.0 (build 777) - 2026-07-17

- **Boolean custom metadata** — New field type (Settings + Inspector toggle); filters (equals/not equals), sort, list display (Yes/No), export, and Import Metadata validation/normalization (`true`/`false`/`yes`/`no`/`1`/`0` → stored `true`/`false`).
- **Import Metadata: unknown columns dialog** — When a CSV/JSONL has columns that aren’t built-ins or existing custom fields, pause before writing and let you choose which to add as custom metadata (with inferred types). Selected fields are created, the file is re-parsed, then import continues. Dialog is a table with alternating rows, checkbox column, and Select all.
- **Install script handles TCC-locked app bundles** — After a DMG/browser install, macOS may stamp `com.apple.macl` so in-place `rsync` fails with “Operation not permitted.” `build_and_install.sh` tries in-place update first (including while Skagway is running, as before); only if that fails does it fall back to rename-aside + ditto, which requires quitting the app.

## 0.63.0 (build 772) - 2026-07-17

- **Page Up / Page Down in grid and list** — Scroll the browser by about one viewport via the existing scroll-command path (selection unchanged). Same local key monitor as Home/End so SwiftUI ScrollView and Table don’t swallow the keys.
- **Adaptive Curated Wall grid columns** — Column count scales from 5 down as the browser pane narrows so cards stay at least as wide as they are tall. Pane width comes from ContentView’s existing GeometryReader (ScrollView background measure was unreliable and collapsed to 1 column); the grid is not remounted.
- **Create tag from Inspector** — Tags section has a New Tag field that creates the tag and assigns it to the current selection (the natural place to invent tags while inspecting). Return/Enter submits the field; the + New Tag button still works. (Enter no longer steals focus for inline rename while a text field is active.)
- **Install no longer resets Removable Volume permission** — `build_and_install.sh` updates `/Applications/Skagway.app` in place (rsync) instead of deleting it first, so macOS keeps the existing TCC grant across rebuilds.
- **Demo library downloader** — `scripts/download_demo_library.py` pulls ~100 Pixabay stock clips (Landscape / Architecture / Arts & Crafts / Automotive) into `~/Movies/Skagway-Demo-Library/` for marketing screenshots.
- **Public DMG packaging pipeline** — `scripts/package_dmg.sh` archives with Developer ID + hardened runtime, builds a drag-to-Applications DMG, notarizes (`SkagwayNotary`), and staples to `dist/Skagway.dmg`.
- **Styled DMG installer** — moonlit mountain + bear background locked to exact Finder window pixels (640×480) with baked-in “Drag Skagway to Applications” cue via `create-dmg` (avoids oversized art showing only sky).
- **About / version polish for distribution** — About shows marketing version, build, “Free forever,” Mach II Labs; Info.plist versions now track `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`.

## 0.62.0 (build 764) - 2026-07-14

- **Grid card chrome (Track B MVP)** — vignette, bottom title scrim, unified duration/CC badges, accent resume bar, and subtler selection/hover lift on Wall cards (SwiftUI overlays only; no new assets).
- **Hover preview preference** — Settings toggle “Hover preview on Grid cards” (default on); title scrim fades out/in over 0.5s when live preview starts/stops.
- **Escape stops playback on first press after play-from-search** — starting inline playback clears search/text-field focus so Escape no longer only unfocuses the search box.
- **Fixed sort direction not restoring on launch** — saved descending sorts were forced back to ascending by the column-change heuristic in `tableSortOrder.didSet` during preference load.
- **GTM plan:** backlog items for **Check for updates** (Sparkle/appcast) and **bug reporting / support communication** (`docs/SKAGWAY-GTM-PLAN.md` Part G).
- **Privacy (locked):** no app telemetry by default — user-initiated bug reports only; support-process metrics are not app telemetry.

## 0.61.0 (build 759) - 2026-07-12

- **Live hover preview on Grid cards** — muted cycling scrub through the existing file on hover (no new preview assets/DB fields); one preview at a time; disabled while the floating player is open.
- **Stable Apple Development signing** — stops ad-hoc rebuilds from re-prompting Removable Volumes / breaking Spotlight after the Skagway rename.
- **GTM plan:** Skagway monetization locked to **free forever** — removed later paywall / founding grandfather / Paddle / LicenseManager for Skagway; direct notarized DMG + machiilabs.com remain the launch path (`docs/SKAGWAY-GTM-PLAN.md`).

## 0.60.0 (build 755) - 2026-07-12

- **Full internal rename to Skagway (0% former product name in steady-state runtime)** — source folder `Skagway/`, XcodeGen target/scheme `Skagway`, bundle ID `com.machiilabs.skagway`, UserDefaults keys `Skagway.*`, Save Copy defaults to `Skagway-<timestamp>.machii`. One-shot `LegacyRenameMigrator` copies prefs/library/thumbnails from the old identity on first launch (non-destructive). Open/save panels are `.machii` only.
- **Library format** — default library remains `~/Library/Application Support/Skagway/Skagway.machii`.

## 0.50.0 (build 751) - 2026-07-12

- **Customer-facing rename to Skagway** — Dock/Finder app name (`Skagway.app`), display name, About, landing title, window titles, and settings copy. Bundle ID and source module still used the pre-rename identity in this build (completed in a later Unreleased change).
- **New app icon** — replaced the skeuomorphic film-reel mark with a modern video-first play-in-viewport icon in a northern-cool palette (midnight slate, ice play glyph, subtle aurora).
- **Fixed ~6s “first frame frozen” stall when starting playback in large libraries.** Playback no longer waits for sidecar subtitle discovery before calling `play()` (large folders made directory scans delay motion). `recordPlay` no longer triggers a full GRDB library reload + O(n) filter cascade on every play.

## 0.40.0 (build 747) - 2026-07-10

- **Added Albums** — manual membership collections listed with Smart Collections in Quick Filter (`rectangle.stack` vs `folder`). Context menu: **New Album from Selection…**, **Add to Album**, and **Remove from “Name”** when an album is active. Drawer: New Album / Rename / Delete. Membership is stored explicitly (not path-OR rules).

## 0.39.0 (build 745) - 2026-07-09

- **Fixed truncated Quick Filter / Inspector tag chips not being clickable while their full-name tip was showing** — replaced the hover `.popover` (which stole the click) with a click-through overlay tip (popover-style bubble + tail) that still shows the full name when truncated.

## 0.38.0 (build 740) - 2026-07-09

- **Fixed intermittent 6–8s freezes before the play panel appears.** Sidecar subtitle discovery and SRT parsing no longer run on the main thread during SPACE/`start()` (they run in parallel with `isPlayable`). Play-time `hasSubtitles` updates no longer reassign `filteredVideos` or reload the library via GRDB observation. Grid “Open With” Launch Services results cache synchronously per extension so eager context menus don’t re-query on every new type.
- **Fixed multi-second stalls when selecting or playing in large libraries (~12k).** Selection/Inspector no longer scan the full library for tags or the selected video (path index + O(selection) tag intersection). Play-time subtitle flag updates no longer cascade into a full filter/counts/custom-metadata refresh. Grid is first in the header; **⌘1** Grid / **⌘2** List.
- **Swapped List/Grid order and shortcuts** — Grid is first in the header segmented control and View menu; **⌘1** is Grid, **⌘2** is List (was the reverse).

## 0.37.0 (build 736) - 2026-07-09

- **Renamed metadata Apply → Import, and folder “Import New” → Scan for New Videos.** File → **Import Metadata…** (⌘⌥I) pairs with Export Metadata… (⌘⌥E); smart library is **Last Metadata Import**. File / toolbar **Scan for New Videos** has no shortcut (Add Folder remains ⌘⇧O). Header status uses “Scanning…” so it doesn’t collide with metadata Import.
- **Added Import Metadata (CSV / JSON Lines).** File → Import Metadata… (⌘⌥I) opens a file, auto-detects format, matches rows by Path then Content Fingerprint (no Database ID), updates differing rating / tags (merge) / custom fields, skips unknown and read-only columns. Summary sheet reports matched / updated / unmatched; **Review unmatched…** re-reads the file on demand (Pass 2). Successful imports select the **Last Metadata Import** smart library.
- **Fixed Import Metadata failing on exported JSONL** with Cocoa’s opaque “data isn’t in the correct format” — JSON parse errors now report the line number; the open panel reads the file while security-scoped access is active (bytes kept for Pass 2); JSONL export emits `null` for non-finite doubles (`NaN` / `Infinity`) so files stay valid JSON.
- **Added Last Metadata Import smart library** — shows paths from the last successful Import Metadata run (persisted); appears in Smart Libraries when non-empty.
- **Fixed Export Metadata default filenames ending in `.jsonl.jsonl`** — `NSSavePanel` already appends the format extension from the allowed content type; the suggested name no longer includes a duplicate suffix.
- **Added Open Default Library** — File menu and landing screen when the default App Support library exists. Switches back to `~/Library/Application Support/Skagway/Skagway.Skagway` (path shown in the button help). Disabled while that library is already active.

## 0.36.0 (build 728) - 2026-07-09

- **Added Export Metadata (CSV + JSON Lines).** File → Export Metadata… (⌘⇧E) exports the current filtered set; Grid/List context menu Export Metadata… exports the selection. Shared sheet: format selector (CSV / JSON Lines), single field list with checkboxes and drag-reorder (optional fields start unchecked at the bottom), read-only scope summary. RFC 4180 CSV with UTF-8 BOM; JSONL uses human custom-field names (e.g. `Featuring`) when unique, falling back to `custom:<uuid>` on collisions. Format and column prefs persist.

## 0.35.0 (build 723) - 2026-07-09

- **Added a proper repo README** — overview, features, requirements, build/install, layout, versioning, and doc index (replaces the previous stub).
- **Renamed Wall → Grid in the UI.** Segmented control, View menu, tooltips, inspector empty state, and Settings copy now say Grid (standard List/Grid terminology). Internal type names unchanged.
- **Dark-only appearance.** Removed the Application Settings Appearance picker (System / Light / Dark). Skagway always locks to dark mode.

## 0.34.0 (build 720) - 2026-07-09

- **Added Quality chips to Quick Filter** (after Duration): SD / 480p / 720p / 1080p / 1440p / 4K / 8K+ multi-select, OR within the set. Same buckets as Advanced Filter Quality; Width/Height stay Advanced-only.
- **Renamed the basic drawer to Quick Filter.** Header button / drawer title / tooltips now say **Quick Filter** (⌘⇧F), pairing with **Advanced Filter** (⌘⇧V).
- **Moved Advanced Filter back into the shared filters drawer** as an exclusive content mode (Quick Filter cards *or* Advanced editor — never both). Quick Filter (⌘⇧F) / Advanced Filter (⌘⇧V) still open their own mode and clear the other; Save as Collection… and Clear live in the Advanced drawer header. Removed the Advanced Filter modal sheet.
- **Split Quick Filter and Advanced Filter into exclusive modes.** Separate header buttons and shortcuts. Opening either clears the other so they never AND together. Renamed "Advanced Rules" → **Advanced Filter** throughout (drawer title, pills, Collections "Edit as Advanced Filter…").
- **Added filter ⇄ Collection bridges (Phase 4).** Advanced Filter gains **Save as Collection…** — persists the live boolean tree as a named smart collection (live filter stays active). Collections context menu gains **Edit as Advanced Filter…** — loads that collection's rules into the Advanced Filter drawer (clears Quick Filter / deselects the collection in the sidebar so Advanced owns matching).
- **Simplified filtering to Quick Filter + Advanced Filter.** Removed the intermediate "More Filters" card (built-in quick rows and custom-field quick filters). The Quick Filter drawer is now Smart Libraries, Collections, Rating, Duration, Quality, and Tags.
- **Added Quality to Advanced Filter and Collections** as a first-class attribute (alongside Width/Height). Value editor is the familiar SD / 480p / 720p / 1080p / 1440p / 4K / 8K+ chip multi-select (OR within the set); operators are "is" / "is none of".

## 0.33.0 (build 708) - 2026-07-07

- **Filters Drawer now covers the major built-in fields, not just rating/duration/tags/custom.** The old "Custom Fields" card is now a unified "More Filters" card with one "Add filter" menu offering every built-in field — Quality (resolution buckets SD…8K+), File Size (MB range), Date Added, Date Created (quick presets + custom range), Plays (Unplayed/Played), Codec, Extension, Folder — plus your custom fields. Each pick adds a removable, type-appropriate row; all rows AND together with each other and with the pinned filters, and each shows a removable pill. (Phase 1 of the layered-filtering design — quick-filter completeness, no rule-engine change yet.)
- **Unified the filter engine behind one model, and upgraded the Collections editor.** Live filtering and saved Collections now share a single rule engine (one matcher over a common condition/group model). Collections gain three things from this: they can now include **custom metadata fields** as rule attributes, a new **"is between" range operator** (one rule instead of two for min–max), and a **type-aware rule editor** — a star picker for Rating, a date picker for date fields, a menu of your existing tags for Tag rules, and a second value box for ranges, instead of everything being a plain text box. Existing collections are preserved unchanged. (Phase 2 of the layered-filtering design; groundwork for the upcoming live advanced/OR filtering.)

## 0.32.0 (build 698) - 2026-07-06

- **Added Shuffle — a random-order view for List and Wall.** A new icon button next to Surprise Me (⌘⇧R) assigns every video a fresh random position; unlike Surprise Me (which jumps to and plays one random video), Shuffle reorders the whole library view. The order is generated once per click and held stable across normal use (selection, tag edits, filtering) rather than reshuffling on every re-render, and cleanly exits back to a real sort as soon as you pick one from the sort menu or click a column header.
- **Fixed Shuffle not exiting when the picked sort matched whatever was active before shuffling** (e.g. sorted by Name, shuffled, then clicked "Name" again did nothing) — the sort machinery skipped its own re-sort as an optimization since the target looked unchanged, leaving the view stuck on the stale shuffled order. Now forces a re-sort whenever exiting random order, regardless of whether the target sort looks unchanged.
- **Added a mouse-clickable "Stop playback" button to the floating player's Compact/Windowed controls**, for exiting play mode without reaching for Escape. The player's title bar had a close button once, but it was unreachable — the drag-to-move surface covering the whole header claimed every tap before it reached the button underneath — so it was removed rather than fixed at the time. The new button lives in the size-controls row instead, outside the drag area.
- **Fixed List view's column headers still showing a sort caret while shuffled** — Shuffle deliberately leaves the underlying sort state untouched (so it can tell whether a later click actually picked a different sort), but that left `Table` showing an indicator on whatever column was sorted before the shuffle. The Table's sort-order binding now reports no indicator while shuffled, without touching the real value a click needs to compare against.
- **Cleaned up the menu bar's default macOS boilerplate** — SwiftUI apps get the entire standard menu bar for free, and only pieces this app explicitly touches get customized. Edit had Undo/Redo and a Find/Spelling/Substitutions/Transformations/Speech submenu with nothing behind any of them; there was also an entire Format menu (Font/Text controls) irrelevant to a video library, and a dead "Print…" item. Removed all of it.
- **Rebuilt the Edit menu's Cut/Copy/Paste/Select All/Deselect All/Delete/Remove from Library as one fully explicit group** instead of composing default system items with custom ones — the earlier composed approach produced a real, structural duplicate ("Select All" appearing twice) since the system default group's exact contents aren't something the app controls or fully knows ahead of time. Cut/Copy/Paste now forward to the standard responder-chain actions directly (same effective behavior as the system default, so they still work correctly in any focused text field).
- **Fixed ⌘A/Select All hijacking a focused field's text selection instead of selecting it.** Went through a few wrong turns on this: a `hasText`-only deferral in a local key-monitor, then a `.disabled(isFocusedInTextField)` gate on the menu item — the latter could never work, since SwiftUI only re-evaluates menu commands when *observed* state changes, and keyboard focus isn't observable, so the gate was permanently stale. Fixed properly: Select All now sends the standard `selectAll:` action through the responder chain first (exactly what the system's own Select All does) — a focused field selects its own text, List's table selects all rows — and only falls back to selecting all videos when nothing claims it. The local monitor's separate ⌘A interception (the root conflict) is removed entirely.
- **Fixed List view's selected-row highlight staying gray (unfocused style) after pressing Escape to leave an Inspector field.** Escape correctly cleared the field's focus but didn't hand focus to anything else, so the Table stopped being first responder and its selection stayed in AppKit's "not focused" gray instead of returning to blue. Escape now explicitly restores focus to the Table when in List view.
- **Added filtering by custom metadata fields.** A new "Custom Fields" card in the Filters Drawer (only shown if you have custom fields defined) lets you filter on any number of them at once, AND'd together with each other and with Tags/Rating/Duration/etc. An "Add Filter" menu picks the field; each active field gets its own removable row with the control suited to its type — contains-text for text fields, a min/max range for number fields, a from/to date range for date fields — plus its own pill above the grid/list. Not persisted across relaunch, matching every other filter here.
- **Fixed a just-added custom field filter row disappearing the moment you clicked into its text field** — a known SwiftUI/AppKit quirk where a freshly-focused, empty `TextField` can fire its binding's `set("")` once with no typing, which the filter's "empty text removes the row" logic then deleted. Rows are now only removed by their own "✕" (or Clear all); a blank/whitespace-only value simply doesn't count as an active filter.
- **A newly-added custom field filter row now grabs keyboard focus immediately** — text and number fields focus their input directly; date fields (which have no empty state to focus into) focus the "From" side's "Set…" button instead.

## 0.31.0 (build 677) - 2026-07-06

- **Fixed a Collections migration bug found in code review**: backfilling old flat-rule collections into the new AND/OR rule-group structure hardcoded the new group's match mode to "all" instead of copying the collection's original mode, which would have silently turned any pre-existing "match ANY" collection into "match ALL" on upgrade. No impact to any collection that already went through this migration without an "any" mode; protects future upgrades (new installs, or restoring an old database backup) from hitting it.
- **Fixed Wall grid's "Remove from Library" and "Delete Video…" acting only on the right-clicked video instead of the full multi-selection** — every other context-menu action already respected the selection; these two silently left the rest of a multi-selected batch untouched despite the confirmation dialog implying otherwise. Now matches List view's behavior.
- **Fixed the Inspector silently blanking a custom-metadata field across an entire multi-selection.** When selected videos had differing values for a custom field, the field showed blank ("multiple values"); merely clicking into it and clicking away — no typing required — persisted that blank over every selected video's real value. Now a mixed field is only overwritten if you actually type something into it.
- **Fixed Rename having no guard against a file mid-move** (found in code review) — every other file-touching action already disabled itself while a background cross-volume move was copying a file, but Rename didn't, risking a race between the rename and the in-flight copy. Now blocked at the Wall grid button, the Enter-key shortcut, and inside `renameVideo()` itself; also fixed the same missing guard on List view's Rename button.
- **Fixed a recurrence of the eager-context-menu performance bug in the Wall grid's "Open With" menu** (found in code review) — asking the system which apps can open a video file ran on every card, on every grid redraw, instead of only when you actually opened "Open With". Now cached per file type, so the lookup happens once instead of repeatedly.
- **Fixed "touchy" click targets across ~18 buttons app-wide** — an icon+text button (e.g. the List/Wall toggle) only responded to clicks on the actual icon/text glyphs, leaving the visible gap between them (and the padding around single-icon/text buttons) as dead click zones. Affects the List/Wall toggle, header status pills, several Inspector buttons and tag chips, active filter pills, both queue windows' "Move to Top", Collections editor controls, the filters drawer's library/collection rows and add-item buttons, and the floating player's size-control icons.
- **Fixed the floating player's 4 size-control icons showing the text-edit (I-beam) cursor on hover** instead of the normal arrow every other button in the app shows.
- **Fixed a regression: the Inspector's hero-resize handle couldn't be dragged while a video played in Compact mode.** The floating player's own hover-tracking region (meant to reveal/hide its controls) was applied to its fully-padded frame, extending 12pt beyond the visible video on every side — enough to reach past the Inspector's handle just below, silently swallowing drags meant for it even though nothing was drawn there. Also removed hit-testing on the player's full-pane invisible positioning layer, which isn't needed for anything drawn.

## 0.30.0 (build 665) - 2026-07-06

- **Added ⌘⇧A "Deselect All"**, working in both List and Wall grid — pairs with the existing ⌘A "Select All."
- **Fixed List view's native ⌘A/arrow-key handling failing to work until a row was clicked first.** The List `Table` needs actual keyboard focus (first responder) for its built-in ⌘A to fire; several paths never gave it that focus: switching view mode via the ⌘1/⌘2 menu shortcuts (only the toolbar toggle did), loading directly into List with nothing selected (cold launch), and — the core bug underneath both — a "pick the table with the most rows" helper that required *more than zero* rows, so it silently found nothing if it ran before the Table had finished populating. Fixed all three; the Table now reliably claims focus so ⌘A works immediately.

## 0.29.0 (build 659) - 2026-07-05

- **Failures that used to only print to console now surface briefly in the header status bar** (tag create/rename/delete/add/remove, file rename conflicts, post-conversion library-record update failures, and a paused-library-updates notice if the background video observation errors out). Each message auto-clears after ~4 seconds unless replaced by a newer one — same transient-status channel already used for scan progress.
- **Import scans now report partial failures instead of swallowing them.** If some files in a folder/drag-drop/"Import New" scan fail to process (unreadable file, extraction error, etc.) while the rest succeed, the header status now shows e.g. "Imported 338/340 — 2 failed (see console)" instead of silently finishing as if everything succeeded. Per-file details still go to console.
- **Re-encode and Move queue status pills now turn red (with a warning icon) when a job has failed**, instead of rendering in the same neutral gray as a normal success summary — "2 re-encodes failed" previously looked identical to "2 re-encoded" at a glance.
- Fixed a stale doc comment on `CustomMetadataSettingsView` claiming per-video custom metadata values weren't implemented yet — they have been for a while, edited from the Inspector.
- **New "Clear" button in the Re-encode Queue manager** for completed jobs whose backup has already been deleted (individually or via "Delete All Backups") — removes just those rows, which had no further actions available. A completed job that still has its backup intact is left alone, since Restore/Delete Backup remain meaningful for it.
- **Re-encode/Move header pills no longer show a lingering "N re-encoded"/"N moved" text once everything's finished.** That passive summary only appears while something's active, queued, or failed; otherwise the pill collapses to an icon-only button that still opens the queue manager on click — the pill itself only disappears once the queue is actually cleared.
- **⌘A (Select All) now works in the Wall grid** — it previously only worked in List view (the Table handles it natively); the grid had no handler at all, a gap from the Curated Wall redesign. Selects every video in the current filtered order; ⌘A inside a text field that has content still selects the field's text. An *empty* focused text field (e.g. the search box quietly holding focus) no longer swallows ⌘A as an invisible no-op — it falls through to Select All, fixing "⌘A randomly does nothing until I click a card."
- **Fix: Wall-grid select-all still hung (75s+ at 12k) even after the Inspector fix — root-caused by CPU sampling to the cards' "Open With" context menu.** SwiftUI evaluates context-menu content *eagerly, per instantiated card, on every grid update* — and that menu builder computed the selection's URLs via a per-id linear scan of the library (selection × library comparisons × ~40 cards, each copying a full `Video` struct). The URL computation now happens only inside the button action, as a single pass with set lookups. The List view's identical scan (lazy there, but still a multi-second stall on right-clicking a huge selection) got the same single-pass fix.
- **Fix: selecting many videos froze the app — a 1500-video Select All hung for over a minute.** The Inspector's Tags section re-derived "which tags are common to the whole selection" *per tag chip, twice*, and that derivation itself scanned the entire library once *per selected video* — multiplying out to billions of file-path string comparisons in a single render. The common-tags computation is now a single pass over the library with constant-time set lookups, computed once per Inspector render instead of per chip. The same per-selected-video library scan was fixed in bulk rating (apply + persist), bulk tag add/remove, bulk custom-metadata editing, and bulk delete/remove-from-library, so large-selection actions no longer degrade quadratically.

## 0.28.0 (build 646) - 2026-07-04

- **Collections support two-level AND/OR grouping.** A collection's rules now cluster into groups: rules within a group combine with the group's own ALL/ANY toggle, and groups combine with each other via the collection's outer ALL/ANY toggle — e.g. "(Tag is Vacation AND Rating is at least 4) OR (Tag is Favorite)". The editor lets you add/remove groups alongside rules, each group rendered as its own bordered card with its own mode toggle. Existing collections are migrated automatically into a single default group per collection, preserving their current behavior exactly.

## 0.27.0 (build 644) - 2026-07-04

- **Duplicates smart library reworked to be accurate and correctable.**
  - **Detection now uses a content fingerprint** instead of the old file-size + rounded-duration heuristic (which flagged two genuinely different clips that happened to share both). Each video gets a cheap SHA-256 of its byte size + first/last 64 KB (whole file if under 128 KB) — no full-file read — so a match is a near-certain byte-identical duplicate. Computed at import for new videos and backfilled in the background for existing ones on launch; stored on the video, so it's stable across rename/move and recomputed after a re-encode.
  - **New "Not a Duplicate" action** (right-click, grid + list, shown only for videos currently in Duplicates). Marks the selected video(s) as confirmed-distinct from their current look-alikes: they leave Duplicates and stay out across recomputes and relaunches — but if a genuinely new matching file is added later, they reappear for review automatically. It's per-pair, so in a group where two files are real duplicates and a third is a coincidence, clearing the odd one out leaves the real pair still flagged. Persisted in a new `video_not_duplicate` table (FK-cascades away when a video is deleted).
  - **Fix: the fingerprint backfill never ran, so existing videos were never detected as duplicates.** It was kicked off from `startObserving()` while the video list was still empty (the DB observation is async), so it no-op'd and every pre-existing video kept a null fingerprint — meaning a freshly-imported file (fingerprinted at import) could never match its already-in-library twin. Now the backfill fires from the observation's first non-empty delivery (once per session) and reads unfingerprinted files off-main after a short launch-settle delay. It writes in chunks (300 at a time, ~6 reads in parallel) so progress persists if you quit mid-pass and the Duplicates set fills in progressively rather than only after the whole library has been read.
  - **The fingerprint backfill now shows live progress in the header status** ("Fingerprinting for duplicates 3,300/11,994") while it runs, so the background pass is visible instead of silent.

## 0.26.0 (build 639) - 2026-07-04

- **New: "Windowed" player size, alongside Compact and Full screen.** A third icon button in the floating player's controls recalls whatever free-floating size/position the resize handle last produced (`playerFloatingSize`/`playerFloatingPosition`, already persisted) — distinct from Compact's fixed inspector-footprint size and from true Full screen. All three now have consistent ⌃-based shortcuts: Compact (⌃⌘C), Windowed (⌃⌘W), Full screen (⌃⌘F, unchanged — still a toggle, the other two are direct "switch to this mode" actions). All three menu commands work correctly from true full-screen too (they exit it first, then apply their mode), and are disabled when nothing is playing.
- **Player window controls (title bar, resize handle, Compact/Windowed/Full screen buttons) now only show on hover, fading out ~1s after the mouse leaves the panel.** Also made 25% larger (icon buttons 11pt → 14pt, title bar 24pt → 30pt, resize handle 11pt → 14pt) to compensate for being less persistently on-screen. All three are hit-test-gated (`allowsHitTesting`) so a faded-out control can't still catch clicks, and all three are forced visible for the duration of an active resize/move drag — `.onHover` can otherwise report "not hovering" mid-drag if the cursor briefly leaves the panel's pre-resize bounds, which without this safety net could fade the controls out while still mid-drag.
- **Removed the player panel's dead close ("X") button.** It never worked: `FloatingPlayerPanel.titleBarDragArea` covers the entire header edge-to-edge with a transparent, hit-testable drag surface, drawn on top of the header — it intercepted every tap before it could reach the X underneath. Rather than carve out a hit-testing exception, removed it outright: Escape already stops playback the same way the button tried to.

## 0.25.0 (build 634) - 2026-07-03

- **New: user-adjustable, persisted height for the Inspector's thumbnail/filmstrip (hero) area.** Same drag-handle pattern as the filters drawer. Minimum 72pt (1in); no maximum — the Inspector body already scrolls, so an oversized hero just pushes the rest of the panel down instead of overflowing. Persists across launches (`inspectorHeroHeight`, default 220pt); previously the hero height was recomputed live every time from 40% of the Inspector's available height (clamped 140–260pt) and wasn't adjustable at all.
- **Compact playback matches whatever hero height you've set — live.** `FloatingPlayerPanel`'s "Compact" size used to independently recompute the same 40%-of-height formula the hero used; now it reads the hero's height directly, and an already-open compact player tracks the resize handle in realtime rather than only snapping to the new size once the drag ends. The live drag value lives in a new, deliberately non-persisted `inspectorHeroLiveHeight` on `LibraryViewModel` (shared so both views can read it) — it never touches `UserDefaults` mid-drag; only the final value commits, on drag end.
- **Fix: excess space around the Inspector hero's resize handle.** It was just another child of the section VStack (22pt spacing), so it got a full 22pt gap on *both* sides instead of hugging the hero it resizes. Grouped the hero and its handle into their own tightly-spaced sub-stack (2pt); also trimmed the handle's own hit-target padding (12pt → 8pt).
- **Increased contrast on both resize handles (filters drawer + Inspector hero)** — they were `Color.appDivider.opacity(0.5)` (`appDivider` is itself `Color.white.opacity(0.08)`, so effectively ~4% opacity, nearly invisible) — changed to `Color.appTextSecondary.opacity(0.55)`. Also gave the filters drawer handle an explicit background matching the Inspector hero handle's dark navy backdrop; it previously showed the plain wall/window background through instead, a visibly lighter charcoal.

## 0.24.0 (build 629) - 2026-07-03

- **New: user-adjustable, persisted height for the filters drawer**, with a resize handle at its bottom edge (shown once the drawer is fully open). Height persists across launches (default 320pt, same as before); minimum 110pt (~1.5in) — 1in was tried first but cuts off a card's header plus its first row, making the drawer useless at the floor. Two ceilings apply: the drawer can't be dragged taller than its own content (the point where its internal scrollbar disappears — growing past that would just add empty space) and can't exceed what fits in the window (so the handle always stays reachable). The content ceiling is measured live, tracking filter count/column-packing changes.
- **New setting: "Filter drawer height" (Settings → Filters), `[Fit to content, Last used]`.** Fit to content always opens the drawer at its natural (no-scrollbar) height and hides the resize handle, since there's nothing to drag; Last used (default) reopens it at whatever height you last dragged it to.
- **Fix: dragging the resize handle flickered.** Two causes, both fixed: (1) the drag handler wrote directly to the `@Observable`, `UserDefaults`-backed height property on every `onChanged` delta — decoupled into a local, non-persisted live-drag value that only commits once, on `onEnded`. (2) The actual culprit: the handle sits *below* the drawer it resizes, so it moves as the drawer grows — `DragGesture`'s default *local* coordinate space measured `translation` against that moving frame, causing an oscillating feedback loop. Switched to `coordinateSpace: .global`, matching the floating player's own resize handle.
- **Fix: "Clear all" in the active-filter pills row could scroll out of reach.** It was the last item inside the same horizontally-scrolling `ScrollView` as the pills themselves, so with enough active filters (or a narrow window) it could end up off-screen, making "clear filters without opening the drawer" effectively impossible to find. Moved outside the scroll area, pinned to the trailing edge — always visible regardless of how many pills are showing.
- **Restored auto-recheck of corrupt videos on reselect.** `refreshMetadataIfCorrupt(for:)` re-extracts metadata for a currently-corrupt video and heals its DB record/thumbnail if the file is now readable (e.g. externally repaired after import) — it existed on `main` but had no caller left after the Curated Wall redesign. Wired back into the Inspector's selection-change handler, same as `main`'s `VideoDetailView.loadData()`; no-ops instantly unless the selected video is actually flagged corrupt.
- **Fix: Surprise Me now scrolls the picked video into view in Wall grid, not just List.** `surpriseMePickRandom()` was setting a `pendingSurpriseScrollVideoId` meant to be consumed by `finishSurpriseScrollIfNeeded(for:)` — a function that was never actually called anywhere (it was written for the old, now-deleted `VideoDetailView`'s filmstrip-load callback). So the scroll never fired in *either* view; List only appeared to work because its `Table` natively scrolls to a new selection. The Wall grid's own `scrollToVideoId` handler already existed and worked — it just never received a value. Fixed by having Surprise Me set `scrollToVideoId` directly, the same mechanism Home/End and rename-completion already use. Removed the dead `pendingSurpriseScrollVideoId` state and `finishSurpriseScrollIfNeeded`.
- **"Clear filter" moved to the card header, right-aligned next to the title** for Collections (was a separate row at the bottom, next to "New Collection") and added in the same spot for Tags (new — clears `selectedTagIds` via the existing `clearTagFilters()`). Both filter cards now follow the same layout: title left, clear action right, on one line. `makeFilterCard` gained an optional trailing `accessory` builder to support this (defaults to nothing for the other cards).
- **New: resume-progress bar on Wall grid cards.** A thin (3pt) yellow bar along the bottom of the thumbnail shows how far into the video you got, proportional to the saved resume position — Netflix/Hulu "continue watching" style. Hidden for never-played or fully-finished videos (no saved position in either case). `PlaybackPositionStore` now caches its UserDefaults-backed dictionary in memory (was re-decoding the whole thing on every read) so this stays cheap across a large grid; a new `resumePositionsRevision` counter on `LibraryViewModel`, bumped on save/clear, makes the (non-`@Observable`) store's changes reactive for the grid.
- **Wall grid card shows a subtitles indicator.** Same blue "captions.bubble.fill" badge already used in List view, placed after the date in the card's metadata row (scaled down to the card's smaller type).
- **Restored manual rescan for the "Missing" smart library.** The missing-file count is a point-in-time filesystem check, not something kept live — it only refreshes when you switch into the Missing filter, so it goes stale between visits (a drive reconnects, a file moves back, etc.) with no way to force a recheck. The Missing row in the filters drawer now has a small refresh button (with a spinner while scanning) that reruns the check on demand without needing to leave and reselect the filter. Matches a `main`-branch affordance dropped in the Curated Wall redesign.
- **Tag filter chips show a video count**, matching `main`'s behavior lost in the Curated Wall redesign — each chip now displays how many videos have that tag under the currently active library/collection/rating filters (excluding the tag filter itself), same scoping as the existing Library and Collections counts.
- **Tag management (rename/delete) moved from the Inspector to the Tags filter card.** Right-clicking a tag chip in the filters drawer now offers "Rename Tag…" (dialog) and "Delete Tag" (confirm), matching what previously only existed on the Inspector's "Add tags" list — which no longer has a context menu at all. The Inspector's "New tag" creation field is also gone (creation now lives solely in the filters drawer, from the previous entry); the Inspector's "Add tags" list still lets you tap an existing tag to assign it, greyed out if already applied.
- **New: standalone tag creation from the Tags filter card.** A "Tag name" field + **New Tag** button beneath the search field creates a tag that isn't assigned to any video yet — closing the gap where the only way to make a tag was via the Inspector, which immediately assigned it to the selected video. The field clears after each add so several tags can be created back-to-back without re-focusing.
- **Inspector "Add tags" list no longer reshuffles as you tag a video.** Previously, assigning a tag removed it from the list, shifting everything below it up. Now every tag stays in its stable alphabetical position — already-applied ones just grey out and become inert (tap does nothing; unassign still happens via the assigned-tags list above). Right-click rename/delete still works on any tag.
- **Removed the 6-collection cap in the filters drawer's Collections card.** Beyond 6, collections were simply unreachable — no scroll, no indication more existed. Since collections are listed alphabetically (not ranked), there's no meaningful "top N" to prefer, so the card now always shows every collection, scrolling internally past its usual height (~168pt) instead of growing unbounded — no expand/collapse step needed.
- **List view context menu reordered to match the Wall grid's.** Was Play → Show in Finder → Open With → Rename → Re-encode → Move Files (no divider between Open With and Re-encode); now Play → Show in Finder → Rename → Open With → *divider* → Re-encode → Move Files, same as the grid. The rest (Modify Filmstrip / Regenerate Thumbnail, Remove from Library / Delete Video…, and their dividers) already matched.

## 0.23.0 (build 605) - 2026-07-03

- **New: Move queue + safety for cross-volume "Move Files…".** Same-volume moves are still an instant atomic rename, unchanged. A move onto a different volume is a real copy + delete and previously gave zero feedback (the `isMoving`/`moveProgress` state existed but nothing rendered it) — worse, it operated on the real source file with no crash safety. Now: the copy lands at a `<name>.moving` temp at the destination first, is size-verified, promoted to the final name, and only then is the source deleted — a crash mid-copy leaves at worst an orphaned temp file, swept automatically on next launch; the original is never at risk. Progress surfaces in a new header status pill (next to the re-encode pill) that opens a Move Queue manager (abort / move-to-top / retry / dismiss, one move at a time). While a move is active, that video's Delete / Move / Re-encode / Remove-from-Library / Open With are disabled in both the Wall grid and List context menus, and the Wall card shows a dimmed spinner badge over the thumbnail so it's visibly "frozen" without needing to right-click.
- **Move Queue manager polish:** newly queued moves now appear at the top of the list (not the bottom); the currently-moving file pops to the very top the moment it starts, ahead of everything still queued behind it; a **Clear** button in the header (shown only when there's something to clear) removes all completed rows at once, same as a browser download manager's "clear completed."
- **Fix: moving multiple selected videos could silently drop one from the selection.** `selectedVideoIds` is pruned to valid ids whenever `videos` changes — including via GRDB's *independent* observation stream, which reacts to a rename on its own async path and can race the move code's own selection update arbitrarily. A first attempt (capture-then-apply) narrowed the window but didn't close it, since the stream could still land its prune before or after in a way that left the new path never inserted. Actually fixed by updating `videos` locally and synchronously ourselves right after the DB write (mirroring the existing pattern in `videoConvertedToMP4`) — the rename-then-reselect now happens in one uninterrupted block with no `await` in between, so nothing can interleave a stale prune; GRDB's later redundant delivery of the same data becomes a no-op. Applies to both the same-volume and cross-volume move paths. Pre-existing in `main`'s move code too, not introduced by the new queue.
- **Restored drag-and-drop file import.** Dropped during the Curated Wall redesign along with the old nav bar; dropping video files (or folders) onto the main window now imports them again, same as `main`. Drop target covers the whole Wall + Inspector split (broader than the old grid-only target), so a drop landing on the Inspector panel still imports.
- **Fix: "Delete Video…" from the Wall grid's context menu did nothing.** The confirmation dialog was only mounted in the (dead) legacy `LibraryGridView` and in `LibraryListView` — triggering delete from the Wall grid set the confirmation flag with nothing listening, so it silently no-oped until you switched to List view. Added the same `.confirmationDialog` to `CuratedWallGrid`. Also renamed the Wall grid's menu item from "Delete" to "Delete Video…" to match List view.

## 0.22.0 (build 597) - 2026-07-02

- **Reworked "Re-encode to MP4" for safety and control.** The original file now stays fully intact under its real name until the encode provably succeeds: ffmpeg writes a temporary `<name>_convert.mp4`, and only on success is the original renamed to `<name>_backup.<ext>` and the temp promoted to the final `<name>.mp4`. A crash or abort mid-encode can no longer cost you the source. Backups are now **kept** (not silently trashed) so you can restore or delete them later.
- **New: Re-encode Queue manager.** A status pill in the header (live spinner + percentage while encoding) opens a queue dialog listing every job. Per-item actions: **Abort** (queued or in-progress — terminates ffmpeg and discards the partial), **Move to Top** (reorder pending jobs), **Restore** (undo a conversion: trash the `.mp4`, rename the backup back to the original), **Delete Backup** / **Delete All Backups**, **Retry** (for failed jobs), and **Dismiss**. Conversions run one at a time.
- **New: queue survives relaunch.** Pending jobs are persisted and resume automatically on next launch; a job interrupted mid-encode is re-queued and its stray temp file swept. Completed entries age out of the list after 30 days (backup files are left untouched).
- Previously the re-encode status was computed but shown nowhere — it now surfaces in the header pill.

## 0.21.0 (build 594) - 2026-07-02

- **New: "Play from Beginning" (⌥-Space)**: starts the selected video from 0, ignoring any saved resume position. When a video is already playing, ⌥-Space restarts it from the beginning — this replaces the old ⌥⌘B "Restart from Beginning" shortcut (the menu item remains, without a shortcut). Plain Space is unchanged (resume / play-pause).
- **Fix: unreachable-file playback no longer flashes and vanishes**: if the video's drive isn't mounted (or the file otherwise can't be opened), the player panel now stays open and shows the existing "Playback Failed" error card (Open in External Player / Dismiss) instead of instantly tearing down the panel before the message can render.
- **New: "Regenerate Thumbnail"** context-menu action (grid + list, single or multi-selection): picks a fresh random position between 10%–90% of the video's duration and regenerates both the thumbnail and the detail-preview still, for videos whose auto-picked frame (10% in, capped at 30s) looks bad — a black frame, title card, or blurry transition. Also fixes a latent race where a slow detail-preview fetch for a previous card state could land late and overwrite a newer one.
- **New: "Make Thumbnail from Current Frame"** — a camera icon in the floating player panel (and a matching menu item) captures the exact frame on screen right now and sets it as the thumbnail + detail preview, replacing whatever was cached. The precise-control counterpart to "Regenerate Thumbnail": scrub to the exact moment you want, then capture it. Uses a zero seek tolerance so it lands on the exact frame rather than a nearby keyframe. No mouse affordance in true full-screen yet (menu item still reaches it via the app-wide command). Shortcut: ⌥⌘M.
- **New: "Modify Filmstrip…"** added to the Wall grid's context menu (already present in List); the Inspector now actually refreshes after using it — it was already being signaled but nothing was listening.
- **Fix: compact player no longer snaps back when dragged.** Moving the title bar exited compact mode without clearing the compact flag, so the panel's position kept resetting to the fixed top-right slot the moment the drag ended. It now exits compact on the first drag frame (freezing the current size first, so there's no resize jump) and stays wherever it's dropped.
- **New: Tag blind default-state setting** (Settings → Tags): the Inspector's "Add tags" blind can be set to always closed (previous behavior), always open, or left as-is (last used) on each new selection.
- **Assigned tags pop more** in the Inspector: stronger accent fill, full-opacity border, semibold text — same accent color, no new palette.
- **New: "Go to First" / "Go to Last"** (Home / End keys, list and grid): selects and scrolls to the first/last video in the current filtered order. List scrolling uses the same header-aware positioning as other jump commands so the first row lands fully clear of the column header instead of partially hidden under it.

## 0.20.0 (build 578) - 2026-07-02

- **⌘F now focuses the search field**, matching the system-wide Find convention. Existing search text is auto-selected via AppKit's standard first-responder behavior.
- **Fullscreen toggle moved to ⌃⌘F** (Control-Command-F, the macOS-standard fullscreen shortcut), freeing up plain ⌘F for search focus.
- **Keyboard shortcut modifiers rationalized app-wide**: every shortcut now follows one consistent rule — ⌃ is reserved solely for the OS-mandated fullscreen binding, ⌥ marks an alternate/secondary action (Clear Filters, Toggle Thumbnail/Filmstrip, Show in Finder, Restart from Beginning, Remove from Library), and ⇧ marks an action that reveals or adds UI (Surprise Me, Toggle Filters, Add Folder). Restart from Beginning moved ⌥⌘R → ⌥⌘B; Remove from Library moved ⇧⌘R → ⌥⌘R to resolve the one letter collision this created.

## 0.19.0 (build 557) - 2026-07-02

- **Arrow key navigation in grid view**: ← / → move to the previous / next video; ↑ / ↓ jump one row up or down (same column position). Navigating scrolls the selection into view. Keys are ignored when a text field (search, inspector custom fields) is focused.
- **Fix: inspector custom-field edit lost on selection change**: editing a text/number custom field and then clicking another video no longer drops the edit. Values are now flushed to the correct video before the inspector reloads for the new selection.
- **Fix: spacebar focus hijack and fullscreen-to-windowed state bug**: spacebar no longer types into the search field on launch; fullscreen-to-windowed transition now correctly restores player state.

## 0.18.0 (build 551) - 2026-07-01

- **Filmstrip click now seeks to the clicked frame**: clicking a frame in the inspector filmstrip starts playback at that frame's exact timestamp. The mapping is row-aware (rows × columns grid) rather than treating the x position as a 0–100 % scrubber. `ThumbnailService` exposes `filmstripGrid(in:)` to recover the grid from the composite's point size, so per-video grid choices are honoured without persisting them separately.
- **Removed S / M / L player size presets**: the floating player is now resizable by drag, making the three fixed-fraction preset buttons redundant. The bottom-right controls are simplified to just **Compact** (inspector footprint, top-right) and **Full screen**.

## 0.17.0 (build 548) - 2026-07-01

- **Custom metadata fields in sort and List View columns**: all non-text custom field types (String, Number, Date, Date & Time) now appear in the toolbar Sort menu (after a separator below the built-in options) and as right-click-toggleable columns in List View. Sort uses pre-built typed value maps for concrete comparisons — no per-row string parsing, zero performance regression. Missing values sort last. Selection, direction, and persistence match built-in sort behavior.
- **Floating player is now movable**: drag the title bar to reposition the panel anywhere in the content area. Compact always snaps to the top-right inspector footprint (unchanged). S/M/L presets center the panel on the application window when clicked. The resize handle (bottom-left) still keeps the top-right corner pinned while resizing. Position persists across launches; clamping handles window-size changes.
- **Sort fixes**: clicking a List View column header now re-sorts immediately (was moving the caret but not applying); selecting a custom-field sort from the toolbar dropdown now moves the column header caret to that column. Arrow direction follows the universal convention (↑ = ascending).

## 0.16.0 (build 520) - 2026-07-01

- Curated Wall cleanup:
  - Grid now shows the native scroll indicator for all macOS "Show scroll bars" settings, including the legacy space-reserving scroller ("Always" / mouse attached). Fixed by dropping the `GeometryReader` around the grid (which suppressed the legacy scroller) in favor of flexible columns — same 5-column layout, visually identical.
  - Restored **Import New** and **Surprise Me** as left-cluster icon buttons in the header (they were dropped with the old nav bar). Import New shows live scan progress in the header status ("Importing 12/340"). Surprise Me's auto-play was re-wired (its `pendingAutoPlay` consumer had been deleted with the legacy detail view).
  - "Player opens at → Last used size" now remembers **full-screen** (persisted `playerLastWasFullScreen`): entering full-screen sets it; only an explicit windowed choice (compact / S-M-L / drag) clears it, so stopping from full-screen still reopens full-screen.
  - **Inspector tag management redesigned** into two lists: assigned tags (top, tap to unassign) and — behind a collapsible "Add tags" blind — the unassigned tags (tap to assign; right-click to Rename… or Delete Tag with confirmation). New Tag lives in the blind and auto-assigns. Deleting removes the tag from the library and every video. Assigned tags run in a packed flow; the blind is transient (collapses per selection). Closes the "no way to delete a tag" gap.
  - **Inspector detail polish** toward the mockups: title + clickable file-path line (folder icon → reveal in Finder, replacing the separate Finder button); Play/Finder... labels on action buttons; a compact **facts table** (resolution+fps · duration · size / codec · date · plays / subtitles) rendered as a bordered grid with cell separators; removed the redundant path footer below Notes.
  - **Exact colors**: inspector background `#0A1523`, facts table cell `#101E2D` with `#19242F` border/separators; Wall grid background `#030D17`, selected card background `#0C141E`.

- Playback redesign (in progress): unifying the three playback modes into one resizable player surface backed by a single shared `InlinePlaybackController` (resume load/save, sidecar subtitles, error handling, recordPlay, play-pause/restart).
  - Introduced the shared engine and a single `FloatingPlayerPanel` host: one player anchored top-right, shown whenever playback is active, with subtitles, resume banner, and error handling in one place.
  - The panel is **resizable** via a lower-left handle (top-right anchored, jitter-free), clamped between a compact minimum and the available area, with **▭ S M L ⤢** controls: compact (snap to the inspector still/filmstrip footprint), small/medium/large presets, and full-screen. Size is persisted.
  - **True full-screen carry-across**: going full-screen moves the *same* player into a borderless edge-to-edge window (no restart; position + subtitles preserved). Esc stops playback and closes; the bottom-right button exits back to the windowed player still playing.
  - The inspector hero is now still/filmstrip only; the player floats above it. Filmstrip click and hero tap start playback carrying the clicked seek time. Removed the obsolete inspector "overlay" action button.
  - **Settings → Playback**: "Player opens at" preference — Compact / Full screen / Last used size.
  - **Compact is a sticky mode**: while active, the player's size *is* the live inspector still/filmstrip footprint, so it follows the wall/inspector splitter in lockstep (and stays current whether or not the player is visible). Picking S/M/L or drag-resizing exits compact mode; the mode persists across launches.
  - Restart-from-beginning is the ⌘⌥R menu command (Shift+Space proved unreliable on Space in this path).
  - Removed the obsolete three-mode machinery and dead code: `InlinePlaybackMode` + `setInlinePlaybackMode`, the `playInlineStartsFullscreen`/`playInlineInOverlay` settings, `overlayPlayerWidth`, the play-pause/restart counters, the ⌥⌘1/2/3 menu commands, the dead `VideoDetailView`/`VideoPlayerView` and the legacy detail-pane layout (~660 lines).
  - Resume banner now sits below the player's header strip (was overlapping the header/filename).
  - Fixed the flaky spacebar play/pause (a first-responder bug, not the environment): the player now takes keyboard focus when it appears (so Space controls playback during a session without first clicking the transport controls), and the search field's launch-time auto-focus is cleared so Space starts playback on a fresh launch instead of typing into the search box.
  - Fixed the "Player opens at → Full screen" preference (it was opening at the last size): it now waits for the asynchronously-created player before presenting the full-screen window instead of bailing when the player was momentarily nil.

- Playback: removed the legacy "browser reshape" behavior (detail-pane playback used to freeze + resize the browsing column, swap to a separate `playbackLayout`, and re-anchor scroll / restore list columns on exit). In the Wall + Inspector layout the player lives inside the fixed inspector hero, so the wall never moves — this scaffolding was dormant and a source of layout pulses. Removed `inlinePlaybackReshapesBrowser`, the separate `playbackLayout` (now a single shared layout), the detail-pane exit re-anchor/column-restore, and the content freeze during playback. The fullscreen-exit grid repaint (occlusion) is preserved.

- Curated Wall filters drawer: arranged the filter cards (Smart Libraries · Collections · Rating + Duration · Tags) so they **reflow responsively and pack column-major**, preserving reading order as the wall narrows — 4-across when wide, collapsing to 3 columns (`[Smart+Collections] [Rating+Duration] [Tags]`), then 2, then a single stacked column. Each column sizes to its widest card and cards fill their column width (no shrinkwrapping), so the drawer stays readable at any pane width instead of squishing. The last column always stretches to fill the remaining width so its cards reach the drawer's right edge.
- Tag chips: hovering a tag chip reveals the complete tag name in a small popover that escapes the card/drawer bounds, so truncated names are readable. The popover only appears when the name is actually truncated (it never just duplicates a name that already fits). Applies to both the filters drawer and the Curated Wall inspector's Tags section.
- Curated Wall: removed the redundant in-wall header strip (its "Search wall" field and video count duplicated the search + count already in the thin capability bar above). The wall surface now begins directly with the gallery grid.

## 0.15.0 (build 410) - 2026-06-28

- UI (floating overlay player): Made the overlay player panel much more "intentional" as a first-class cinematic object.
  - Replaced raw `windowBackgroundColor` + anonymous splitter with a themed `Color.appSurface` container using `UnevenRoundedRectangle` (xl radius on the leading edge only).
  - Added a subtle `appAccent` outer stroke so the panel reads as a deliberately placed surface rather than leftover window space.
  - Redesigned the width splitter as a visible blue-tinted grip (three stacked capsules) that clearly communicates "this panel is adjustable".
  - Framed the `FloatingPlayerView` with `.appMediaFrame()` + breathing room so the video feels contained instead of bleeding to the edges.
  - Added a compact header bar (filename + close button) using design tokens; this makes the floating player read as a summoned panel, not just "video in a box".
  - The treatment deliberately avoids heavy shadows/materials on the resizable container itself (to preserve smooth live dragging) while still delivering strong visual presence through surface, rounding, accent, and framing.
  - Header close button stops inline overlay playback cleanly.
  - Build 409.

- UI (remaining chrome & editors sweep): Completed the visual pass on the last major stock-looking areas.
  - Detail pane Thumbnail/Filmstrip switcher: replaced stock `.segmented` Picker with `AppSegmentedControl` for full consistency.
  - Overlay player resume banner and error overlay: updated to use `Material.appFloatingMaterial`, `appSurface`, `appAccent` strokes, `appText*` colors.
  - `FilmstripConfigView`: wrapped in glass card, app colors for labels, accent-tinted Generate button, improved steppers.
  - `TagEditorView` & `TagToggleChip`: switched from `accentColor`/`secondary` to `appAccent`/`appTextSecondary`/`appSurface`.
  - `CollectionEditorView`: updated ALL/ANY pill and labels to use `appAccent`/`appTextSecondary`.
  - Settings tabs (Application, Library, Data Sources, List Columns, Custom Metadata, File Ext, etc.): swept `.secondary`/`.tertiary` → `appTextSecondary`/`appTextTertiary`; added `appAccent` tint to key pickers.
  - Various remaining `.bordered` buttons in detail/overlay now consistently tinted where they weren't.
  - Split view surfaces and surrounding chrome already using design tokens; deep NSSplitView divider drawing left as system thin (common limitation).
  - Build 407.

- UI (status bar): Styled the bottom status bar to match the Cinematic Blue design system.
  - Subtle `Color.appSurface.opacity(0.55)` background with a thin `appDivider` top separator.
  - All labels use `Color.appTextSecondary`.
  - Progress indicators tinted with `Color.appAccent`.
  - Consistent `.caption` typography and tight vertical padding.
  - Replaces the previous stock `.bar` material and raw `.secondary` styles.
  - Build 405.

- UI (LandingView): Full Cinematic Blue redesign of the first-impression screen shown when no library is open.
  - Deep `appBackground` full-window treatment.
  - Large, well-weighted title in `appTextPrimary`; subtitle in `appTextSecondary`.
  - Main actions grouped in a prominent glass/surface card (`Material.appSubtleGlass` + `appSurface`) with subtle `appAccent` border and generous `AppRadius.xl`.
  - Primary "Create in default" uses borderedProminent tinted with `appAccent`.
  - Other create/open actions styled consistently with `appAccent` tint.
  - "Open recent" section has a clean divider and hoverable recent items using `appHover` + rounded surfaces.
  - Tighter, more intentional spacing using `AppSpacing` scale.
  - Overall more premium and opinionated dark-first landing experience.
  - Build 404.

- UI (search): Replaced the stock `.searchable` field with a custom styled search pill inside the library nav bar for full Cinematic Blue treatment.
  - Magnifying glass icon + "Search videos" placeholder.
  - Clear (x) button appears when text is present.
  - Focus ring uses `appAccent` (stronger when focused).
  - Uses `appSurface`, `appTextPrimary/Tertiary`, `AppRadius`, `AppSpacing`.
  - Integrated after the sort control; the bar's glass container frames it nicely.
  - Stock searchable behavior removed (no duplicate field); search logic in LibraryViewModel is unchanged.
  - Build 403.

- UI (empty states & placeholders): Styled the "No Videos" empty state and the "Select a video" detail-pane placeholder with the Cinematic Blue design system.
  - Both now use a subtle glass/surface card treatment (Material + appSurface + thin accent border) for a designed, contained look instead of raw floating text.
  - Consistent semantic colors: `appTextPrimary/Secondary/Tertiary`.
  - Proper `AppSpacing` and `AppRadius`.
  - "Add Folder" button tinted with `appAccent`.
  - "Select a video" now includes a short helpful subtitle and stronger visual weight.
  - Build 402.

- UI (top chrome — Priority 1): Finished styling the library nav bar and main toolbar for visual consistency with the Cinematic Blue design system.
  - Replaced the last remaining stock `.segmented` picker (Playback Mode: Detail/Overlay/Full Screen) with `AppSegmentedControl`.
  - Gave the inline library nav bar (directly above grid/list) a matching glass container (Material + appSurface + subtle accent border), same language as the custom segmented controls and bottom filter strip.
  - Restyled the remaining stock buttons in the library nav bar:
    - Columns button
    - Sort menu trigger
    - Scroll navigation cluster (top / page up / page down / bottom)
  - Introduced reusable `.appNavBarButton()` modifier (plain style + surface fill + rounded clip + thin accent ring) to keep the treatment consistent and easy to maintain.
  - Tinted the main window toolbar action buttons (Add Folder, Import New, Surprise Me) with `Color.appAccent`.
  - Removed `.controlSize(.small)` and raw `.bordered` styles from the chrome.
  - Build 401.

- UI (grid): Made selected video cells pop more distinctly.
  - Stronger outer selection: `appAccent.opacity(0.30)` fill + full `appAccent` 2pt border (was subtle 0.22 wash + 0.85 opacity).
  - Thumbnail now gets its own prominent blue accent ring (2pt `appAccent`) when the cell is selected, in addition to the outer card treatment. This makes the actual video content stand out.
  - Filename becomes semibold when its cell is selected.
  - All changes are still lightweight (simple fills/strokes, no per-cell heavy effects).
  - Build 399.

- UI (top nav bar): Replaced the stock segmented pickers with a custom `AppSegmentedControl` for View Mode (List/Grid) and Grid Size (S/M/L).
  - Proper sliding pill selection indicator using `.matchedGeometryEffect` + spring animation.
  - Outer container uses `Material.appSubtleGlass` + `appSurface` with a thin `appAccent` border.
  - Selected segment: `appAccent` tinted fill + stroke; bold semibold primary text.
  - Unselected: secondary text color.
  - Fully integrated with existing side-effects (preferences save + scroll-to-selected on view switch).
  - Removes one of the strongest remaining "generic macOS" visual elements in the main browsing UI.
  - Build 396.

- Bugfix (top nav bar): The custom `AppSegmentedControl` for List/Grid and S/M/L was expanding to a huge height (~4 inches) because it had no explicit height and the selection pill used an unconstrained `RoundedRectangle` inside a `ZStack`. When the vertical split's top pane proposed a large height (from saved layout or measurement), the shapes filled it.
  - Fix: Added `.frame(height: 28)` to keep the control compact like stock segmented controls.
  - Refactored selection indicator to use `.background` on the segment content (the background sizes exactly to the label + padding, no more ZStack + free shape).
  - Reduced internal vertical padding slightly for fit.
  - Build 397.

- Polish: Made the "little bounce" you like when the grid reorders or changes density (via grid size or window width) explicit.
  - Added `.animation(.spring(response: 0.38, dampingFraction: 0.80), value: viewModel.gridSize)` to the `LazyVGrid`.
  - This captures the pleasant springy repositioning of cells (previously purely implicit) so it stays consistent as we continue the visual work.
  - The effect happens on S/M/L changes (now driven by the custom segmented control) and when the number of columns recalculates.
  - Reorders from sorting also continue to get lively movement because we only force-recreate the grid on structural set changes, not pure order changes.
  - Build 398.

- UI (bottom filter strip): Applied full Cinematic Blue treatment to `BottomFilterColumnsView` (the 4-column LIBRARY / COLLECTIONS / RATING / TAGS area under the grid/list).
  - Whole strip: `.appFilterStrip()` (subtle glass + appSurface + top divider line) for cohesive bottom chrome.
  - Column separators: thin `Color.appDivider` lines instead of stock Dividers.
  - Section headers: bold left blue accent bar (matching detail pane) + `Color.appAccent` text.
  - All rows, counts, badges: semantic `appTextPrimary/Secondary/Tertiary`, `appSurface` capsules, `AppSpacing`/`AppRadius`.
  - Selection states: `Color.appAccent.opacity(0.22)` rounded rects (consistent with grid/list).
  - Rating stars: cleaned up (no more colorScheme ternary).
  - Tag rename field and New Tag sheet: surfaced with app tokens.
  - "New Collection"/"New Tag" actions and empty states use `appTextSecondary/Tertiary`.
  - Lists tinted with `appAccent`.
  - Build 395.

- Bugfix (list view): "Go to top" now lands the first row *flush* under the column headers with no remaining gap. After the prior fix you could still wheel the mouse ~3-4 px further to tuck the row a little higher.
  - Root cause of residual gap: the previous overlap calculation converted whole `headerView`/`clip` *frames* into `NSScrollView` coordinates. Small differences in borders, separators, intercell spacing, and SwiftUI Table wrappers produced a 3-4 pt error in the computed intrusion.
  - Precise fix in `ScrollCommandHandler`:
    - `scrollListToAbsoluteTop`: after `scrollRowToVisible(0)`, convert only the *bottom edge point* of `table.headerView` (`NSPoint(x:0, y: bounds.maxY)`) directly into the `NSClipView` using `convert(_:to:)`.
    - Solve for the clip origin that places `rowRect.minY` exactly at that local "under-header" Y in the clip: `targetY = rowRect.minY - headerBottomLocalY_inClip`.
    - `reflectScrolledClipView`, then immediately call a new `correctListFirstRowUnderHeader(...)` helper that re-measures the same mapping and applies a micro-nudge if `|currentY - desiredY| > 0.25`.
    - The existing re-application timers (async + 80 ms) keep calling the full routine so any later layout/selection-visible adjustments are also corrected.
  - Grid mode and non-`.top` commands unchanged.
  - Build 394.

- Bugfix (list view): "Go to top" (⌘↑ or the top button) now positions the first row fully visible directly beneath the column headers (no longer half-hidden).
  - Initial attempt (y=0 for list .top) was insufficient. Even with document y=0 as the top of row 0, the `NSScrollView` clip view frame can intrude a few points under the `NSTableHeaderView` that the scroll view places for a SwiftUI `Table`. Targeting y=0 therefore parked the top sliver of row 0 behind the header.
  - Real fix in `ScrollCommandHandler`:
    - For `.top` + list mode: find the dominant `NSTableView`, call `scrollRowToVisible(0)`, derive `targetY` from `rect(ofRow: 0).minY`.
    - Measure the actual overlap: convert `table.headerView` and the content clip frames into the scroll view's coordinate space; `overlap = max(0, headerRect.maxY - clipRect.minY)`.
    - Compensate: `targetY -= overlap`. This places document row-top slightly "above" the clip top so it lands exactly at the visual bottom edge of the header.
    - Schedule two follow-up reapplications (immediate async + 80 ms) because SwiftUI/AppKit may run additional layout/selection-visibility scrolls that would otherwise re-obscure the first row.
  - Non-top commands and grid mode unchanged.
  - Build 393.

- Bugfix: Sorting the list view by the "Plays" column now correctly sorts by numeric play count.
  - Root cause: `VideoSort` enum (used by both the toolbar Sort menu and the fast custom sorter in `recomputeFilteredVideos`) had no `playCount` case.
  - `VideoSort.from(keyPath:)` fell back to `.dateAdded` whenever `\Video.playCount` (or `sortablePlayCount`) was passed from the Table's `sortOrder`.
  - `sortByTableOrder` therefore sorted by date added (or previous sort) instead of plays.
  - Fix: Added `.playCount` to `VideoSort`, implemented `comparators()` / `from(keyPath:)`, and the corresponding case in `sortByTableOrder`.
  - Added `var sortablePlayCount: Int` on `Video` for consistency.
  - Updated the Plays `TableColumn` (value keypath) to use `\.sortablePlayCount`.
  - "Plays" is now available as a sort in the list column header click and in the toolbar Sort menu.
  - Build 390.

- UI (list view): Applied Cinematic Blue treatment to `LibraryListView` rows for parity with grid.
  - Name column: thumbnails now use `.appMediaFrame` (small radius) + dark surface.
  - Larger popover thumbnails also framed.
  - Rename TextField inside list uses `appSurface` + `appAccent` stroke.
  - Filename text uses `appTextPrimary`.
  - Subtitles indicator pill uses `appAccent` background.
  - All data columns updated to semantic `Color.appTextSecondary` / `appTextTertiary`.
  - Resolution column now shows a small styled pill (dark surface + blue accent) for visual consistency.
  - Table tinted with `Color.appAccent` for blue-leaning selection/hover.
  - Consistent use of `AppSpacing`, `AppRadius`, and caption fonts.
  - Build 389.

- UI (grid cells): Applied Cinematic Blue treatment to `VideoGridCell`.
  - Now uses `.appVideoGridCell(...)` (backed by `.appCell`) for selection (blue-tinted fill + accent border) and hover states.
  - Thumbnail area backed by dark `appSurface` + `.appMediaFrame` (neutral subtle border).
  - Duration badge uses `appBadgeBackground`.
  - All text uses semantic `appTextPrimary/Secondary/Tertiary`.
  - Resolution pill styled as dark surface + blue accent.
  - File size and labels use design tokens.
  - Rename field inside grid uses `appSurface` + `appAccent` stroke.
  - Placeholder uses `appSurface` + tertiary icon.
  - Consistent `AppSpacing` / `AppRadius` and `Font.appCaption*` throughout.
  - Added size-aware rounding support in the grid cell style (`appCellWithRadius`).
  - Build 388.

- UI (detail pane): Removed prominent blue border from the filmstrip/thumbnail/player container. It now uses a dark blue surface background (Color.appSurface) matching the style and treatment of the Details, Custom, Rating, and Tags cards, with only a subtle neutral divider stroke. Inner frames also use neutral strokes.
- UI (detail pane, aggressive): Much stronger cinematic treatment on filmstrip/thumbnail + details data.
  - New `.appHeroPreview()` for the main preview area (dark blue surface matching the data cards, subtle divider stroke only).
  - `.appMediaFrame()` on preview imagery updated to neutral (no blue accent).
  - `.appDetailCard()` (stronger than previous subtle section) used on Details + Rating/Tags blocks with thicker blue strokes and more lift.
  - Section headers now have a bold left blue accent bar + uppercase labels on metadata rows for scannability.
  - Title area given a subtle surface treatment. Resize handle now has a visible blue grip.
  - Metadata rows have more weight (medium weight values, tighter hierarchy).
  - Stronger visual separator between the two data columns.
  - Picker bar integrated into the hero container with blue tint.
  - Left blue accent bars added to all section headers (Details, Custom, Rating, Tags).
  - Metadata rows made more scannable (uppercase labels, medium weight values).
  - Build 385.

## 0.14.1 (378) - 2026-06-27

- skagway-playback-test pass: reviewed full checklist against implementation; fixed list view not receiving explicit centered scroll re-anchor after leaving detail-pane playback (now sets scrollToVideoId for both grid and list on exit).

## 0.14.0 (376) - 2026-06-27

- Foundation and agent workflow release:
  - Added `AGENTS.md`, `ROADMAP.md`, `SKILLS.md` as the core foundation documents.
  - Reconciled build/deploy rules; created `.cursor/rules/release-workflow.mdc` for Skagway.
  - Created `skagway-playback-test` skill.
  - Retired `IMPROVEMENTS.md` and `DEVELOPMENT_SUMMARY.md` (key ideas folded into `ROADMAP.md`).
  - Cleared `docs/USER_GUIDE.md` (full guide deferred until closer to production release).
  - Introduced live `CHANGELOG.md` process: agents maintain high-level changes in `## Unreleased` on every commit; content is consolidated into versioned release entries on release.
  - Strengthened rules and agent instructions for commit discipline (always `git add -A` for tracked + untracked files) and requiring releases to commit all completed work.

## 0.13.0 (375) - 2026-06-16

- floating overlay playback + playback-mode control

## 0.12.1 - 2026-06-15

- fix grid scroll position after inline playback

## 0.12.0 - 2026-06-15

- library performance overhaul and stability fixes

## 0.11.0 - 2026-06-14

- navigation controls, consolidated view bar, move + convert fixes

## 0.10.0 - 2026-06-07

- in-app re-encoding, Recently Converted filter, and playback UX

## 0.9.0 - 2026-05-08

- library polish, subtitles, and playback UX

## 0.8.1 (281) - 2026-04-02

- Release Skagway 0.8.1 (build 281)

## 0.8.0 - 2026-03-27

- Release Skagway 0.8.0

## Earlier releases

Follow the same pattern. See git tags (`v0.7.x` and prior) and their associated commit messages for the exact summaries and (where recorded) build numbers at the time.

---

*This file is the source of truth for "what shipped in which build" and for the running history of changes between releases.*