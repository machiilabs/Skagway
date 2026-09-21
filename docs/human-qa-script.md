# Skagway — Human QA script

Walk this **in order** on a Mac with `/Applications/Skagway.app`. Each numbered step is **do → expect**. Tick it only when the expect matches.

This is the full product surface from first launch through 1.3.0, inventoried from the app (menus, windows, sheets, pickers). Do **not** invent extras. **Favorites** and a standalone **Notes** field are not in the current UI — skip them.

**Build:** whatever is installed (1.3.0 freeze is 1169+). Record version from **Skagway → About Skagway**.

**Stop the freeze** if any §16 (1.3.0 / 1166–1169) step fails. Elsewhere, note the step number and continue unless the app crashes.

**Before every release:** run **Before every release** below (backup + recreate the ~12k library, log timings). That gate is mandatory; the rest of this script is the functional walk.

No telemetry, no automated GUI driving.

---

## Before every release (~12k backup + recreate)

Human-only. Do this on the **release build** before you announce. Record numbers in [`docs/release-perf-log.md`](release-perf-log.md). Counts, seconds, and feel only — no paths, titles, or wall screenshots.

**Expect:** toolbar **~12,000** (baseline was **12,174**). Same media folders as last release. Agents must not skip this or drive the GUI.

1. Open the large library you use for 12k testing.  
   **See:** header count in the 12k range (All Videos, no search). Write that number down as **backup count**.

2. **File → Save Copy…**  
   **See:** save panel titled **Save Copy**; message about one `.machii` (WAL/SHM do not need copying). Save somewhere safe. Skagway **stays** on the original library. The copy keeps the **original cache pointer**.

3. Confirm the copy exists on disk. Do **not** open it for the rebuild.  
   **See:** a `.machii` next to your chosen name. Keep it until the new library matches count and you have logged timings.

4. **File → New Library…**  
   **See:** save panel **New Library**; “thumbnail cache defaults to a Skagway-cache folder beside the file.” Create it. Empty library: drop zone **Drag videos here** / **Add Files…**.

5. **File → Add Folder…** (⇧⌘O) — add the **same** source folders as the backup library (Settings → Data Sources on the old library if you need to recall which).  
   **See:** folder picker; scan starts; **activity strip** shows import. Start the stopwatch when you confirm the first folder.

6. Wait until the header count **stops changing** and scan is idle.  
   **See:** count within a few of **backup count** (disk may have gained/lost files). Log **R1** = seconds to stable count. App stays clickable (no multi-minute beachball). Crash or a huge shortfall vs backup = **fail**.

7. When the first screen of Grid posters is usable (placeholders OK), log **R2**.  
   **See:** wall is browsable; backfill may still run.

8. Quit, then open the **new** library (dock or **File → Open Recent**). Log **R3**.  
   **See:** usable Grid within the cold-start bar (~8 s pass, >15 s fail).

9. On that rebuilt library, run A–M from the [0.80.0 bar](release-perf-log.md) (and **N**: Storyboard scroll + Compact ⌘I hide/show).  
   **See:** same pass/fail rules as the log. Compare seconds to the previous release row. Sort (L) was the watch item (~2–2.5 s in 0.80.0).

10. **File → Open Library…** the **Save Copy** once.  
    **See:** backup opens; count still matches what you saved. Then switch back to the rebuilt library (or the copy) for daily work.

11. Append a dated **X.Y.Z (build NNN)** section to [`docs/release-perf-log.md`](release-perf-log.md) and commit it with the release.  
    **See:** rebuild clocks + A–N filled; verdict PASS/FAIL; “vs last release” called out if anything got worse.

If this pass fails, **do not announce** the release.

---

## 0. Menus (reference — click through once)

Confirm these exist and are enabled/disabled as noted. Then use them in the numbered steps.

| Menu | Items (exact labels) |
| --- | --- |
| **Skagway** | About Skagway · Check for Updates… · Settings… (⌘,) · Hide / Quit (system) |
| **File** | Add Folder… (⇧⌘O) · Scan for New Videos · Scan for Subtitles · Reconnect… · Play in External Player (⌘↩) · Show in Finder (⌘⌥F) · Open With ▸ · Open / Create / Home library · Open Recent ▸ · Save Copy… · Export Metadata… (⌘⌥E) · Bulk Rename… · Import Metadata… (⌘⌥I) · Change Library Location… · Change Thumbnail Cache Location… · Close Library… · Delete This Library… |
| **Edit** | Cut / Copy / Paste · Select All (⌘A) · Clear Collection (⌘⇧A) · Toggle in Selection · Delete… (⌘⌫) · Remove from Library (⌘⌥R) · Undo Reconnect (⌘Z, only after a reconnect) |
| **View** | Grid (⌘1) · List (⌘2) · Storyboard (⌘3) · Inspector (⌘I) · Scroll to Selection (⌘J) · Surprise Me! (⌘⇧S) · Play All (⌘⇧P) · Loop Play All · Quick Filter (⌘⌥Q) · Advanced Filter (⌘⌥A) · Clear Filters (⌘⌥C) · Toggle Thumbnail / Filmstrip (⌘⌥T) · Re-encode Queue… · Move Queue… · Compact (⌃⌘C) · Windowed (⌃⌘W) · Toggle Full Screen (⌃⌘F) · Restart from Beginning · Skip Back/Forward 15 Seconds (⌥← / ⌥→) · Playback Speed ▸ · Make Thumbnail from Current Frame (⌘⌥M) · Bookmark Current Position (⌘⌥B) |
| **Help** | Skagway Help · Contact Support… |

Window: main library (min 900×600). Second window: **Settings** (⌘,). Sheets listed in the steps that open them.

---

## 1. First launch / library home

Use a **clean** first-run only if you can (new user, or **File → Change Library Location…** which quits and shows this chooser again). On an already-set-up Mac, read the screen if you reopen the chooser; do not wipe a real library unless you intend to.

1. Launch Skagway with no completed home setup.  
   **See:** “Choose where Skagway stores its data”, privacy bullets (nothing leaves your Mac; you control catalog/cache; encrypted volume; defaults). Buttons: **Use standard location on this Mac**, **Choose Folder…**.

2. Click **Use standard location on this Mac**.  
   **See:** library opens (or Landing if ask-each-launch). No account, no cloud prompt.

3. (Optional path) **Choose Folder…** → pick a folder.  
   **See:** “Where should this library’s cache live?” with **Co-locate with library**, **System default**, **Choose Folder…**, **Back**.

4. Pick a cache option.  
   **See:** “How should Skagway find this library?” with **Remember this location**, **Ask every time I open Skagway**, **Back**.

5. Choose **Remember** or **Ask every time**.  
   **See:** library UI or Landing (“Open a library to continue…” if ask-each-launch). Errors show a system alert, not a crash.

---

## 2. Landing (no library open)

1. **File → Close Library…** (or launch in ask-each-launch mode).  
   **See:** Landing: app icon, “Skagway”, subtitle (“No library is open” / ask-each-launch / volume offline), “Use File → Open Library…, New Library…, or Open Recent.”

2. **File → New Library…** — create a throwaway library you can delete later.  
   **See:** save panel; then the empty library UI (header + Inspector, empty browser).

3. **File → Open Library…** / **Open Recent** / **Open Home Library** or **Create Home Library** (whichever File shows).  
   **See:** that library opens; recent names match files you used.

4. **File → Open Recent → Clear Menu**.  
   **See:** recents empty; menu disabled until you open another library.

---

## 3. Empty library / add media / scan

1. With an empty library, look at the browser (left of Inspector).  
   **See:** “Drag videos here” / dashed drop zone, **Add Files…**, hint “File → Add Folder… (⇧⌘O)”.

2. Drag a folder of videos onto the zone (or click **Add Files…** and pick files).  
   **See:** drop target highlights (“Drop to add to your library”); import starts; bottom **activity strip** shows scan/import progress.

3. **File → Add Folder…** (⇧⌘O) — add another folder.  
   **See:** folder picker; scan; videos appear in Grid.

4. **File → Scan for New Videos** (or header **↓** circle).  
   **See:** scan runs (button disabled while scanning); new files appear; **Last Added** may show in Quick Filter if count > 0.

5. **File → Scan for Subtitles**.  
   **See:** scan completes; Inspector **Subtitles** picker can show Sidecar when a `.srt` sits beside a file.

6. **Skagway → Settings… → Data Sources**.  
   **See:** folders you added listed; **Add Folder…**; hover a row to exclude/remove as the sheet describes. **Exclude a subfolder** is a separate list.

---

## 4. Header chrome (library open)

Left to right on the thin bar:

1. **Scan** (↓ circle) — same as Scan for New Videos; disabled while scanning.

2. **Sparkles** — Surprise Me (⌘⇧S).  
   **See:** a random video is selected and scrolled to; auto-play only if Settings → Video → “Surprise Me! auto-plays…” is on.

3. **Shuffle** (⌘⇧R).  
   **See:** order randomizes; Sort label reads **Random**; click again reshuffles. Pick a real sort to leave shuffle.

4. **Play** triangle — Play All (⌘⇧P). **Repeat** — Loop Play All.  
   **See:** Play All starts from the first filtered video; loop toggle matches View menu and Settings.

5. Segmented **Grid / List / Storyboard** (⌘1 / ⌘2 / ⌘3).  
   **See:** view switches; selection stays; wall scrolls to the selected card when switching.

6. In Storyboard only: **Normal | Compact**.  
   **See:** Normal fewer/wider cards (max 3 columns); Compact tighter (up to 4 when Inspector is hidden).

7. **Sort:** Title, Date Added, Duration, File Size, Rating, Resolution, Plays (+ custom non-text fields if defined; **Album Order** when viewing an album). Arrow flips ascending/descending (hidden in Random / Album Order).

8. **Search videos** (⌘F). Type a title fragment.  
   **See:** header count “N videos” drops; clear **×** empties the query. ⌘A in the field selects the query text, not the library.

9. Count text, optional re-encode / move **pills** (open those queues).

10. **Inspector** sidebar icon (⌘I) and **Filter** sliders (⌘⇧F).  
    **See:** Inspector show/hide; filter drawer slides down from under the header.

---

## 5. Grid (⌘1)

1. Browse a populated Grid.  
   **See:** poster cards; hover preview (muted scrub) if Settings → Video → “Hover preview on Grid and List” is on and the floating player is **not** open.

2. Click a card.  
   **See:** selection highlight; Inspector fills (not empty). Click another card: Inspector follows.

3. ⌘-click / Shift-click several cards.  
   **See:** multi-select; header pill “N videos collected” when 2+; Inspector can stay on the focused clip or switch to batch (“N Videos Selected”).

4. Double-click a card (or Inspector **Play**, or Space with a selection).  
   **See:** inline player starts (see §10).

5. Right-click a card (must be hovered/focused/selected — menu is not built for idle cards).  
   **See:** Play in External Player · Show in Finder · Edit Title… · Rename File… · Bulk Rename… · Open With ▸ (Submarine if installed, then Launch Services apps) · Fix for Built-in Player… · Move Files… · Modify Filmstrip… · Set Poster from Image… · Regenerate Thumbnail · Not a Duplicate (only if in Duplicates) · Export Metadata… · New Album from Selection… · Add to Album ▸ · Remove from “album” (when viewing an album) · Remove from Library · Delete Video…

6. **Edit Title…** or press **Return** on a focused card.  
   **See:** inline title edit; Return commits; Escape cancels. File name on disk unchanged.

7. **Rename File…**  
   **See:** file rename UI; disk name changes; library path updates. Disabled during an active Move.

8. Drag a still image onto a card (poster drop).  
   **See:** accent outline; poster updates.

9. Scroll far.  
   **See:** sort-index **HUD chip** beside the **wall** scrollbar thumb (not over the Inspector). Updates while scrolling; fades when idle.

10. Arrow keys · Home/End · Page Up/Down.  
    **See:** ←/→ one card; ↑/↓ one row; Home/End first/last; Page keys scroll a viewport without changing selection.

11. **View → Scroll to Selection** (⌘J).  
    **See:** selected/focused card scrolls into view.

---

## 6. List (⌘2)

1. Switch to List.  
   **See:** table: Title plus optional Duration, Resolution, File size, Rating, Date added, Plays, Created, Last played (toggles in Settings → Library → List view columns). Custom fields can appear as extra columns.

2. Click column headers.  
   **See:** sort matches header Sort menu; caret clears while shuffled.

3. Double-click a row.  
   **See:** inline play of that row.

4. Right-click selection.  
   **See:** same family of actions as Grid (Edit Title / Rename File only when one row).

5. Hover a list thumbnail (if hover preview is on).  
   **See:** enlarged muted preview; it must **not** run while the floating player is open.

6. ⌘A with the table focused.  
   **See:** all **filtered** rows selected.

7. Scroll.  
   **See:** HUD chip on the list scroller, same rules as Grid.

---

## 7. Storyboard (⌘3)

1. Switch to Storyboard.  
   **See:** 2×3 collage cards; title/poster readable; Normal | Compact control visible.

2. Click a collage **cell**.  
   **See:** play starts (or seeks) at that cell’s time — not a random even-split if times are cached.

3. **Compact** + Inspector **shown**.  
   **See:** 3 columns on a typical window.

4. Hide Inspector (⌘I).  
   **See:** 4 columns, no multi-second stall, cards do not flash/remount.

5. Show Inspector (⌘I).  
   **See:** 3 columns again; Inspector **paints**; divider width matches last shown width. (§16)

6. **Normal** on a wide window.  
   **See:** at most 3 columns (does not go to 4).

7. Scroll.  
   **See:** HUD on the wall scroller.

---

## 8. Filters, smart libraries, collections, pills

1. **⌘⇧F** or header sliders.  
   **See:** drawer slides from under the header; tabs **Quick** | **Advanced** (⌘⌥Q / ⌘⌥A).

2. **Quick → SMART LIBRARIES**  
   Click each row that is visible (Settings can hide some):  
   All Videos · Recently Added · Recently Played · Top Rated · Duplicates · Corrupt · Missing · Recently Converted · Last Added (if count > 0) · Last Metadata Import (if count > 0).  
   **See:** wall updates live; counts match; **Missing** can show the repair banner.

3. **COLLECTIONS**  
   **New Collection** → sheet `CollectionEditorView` → save a smart collection.  
   **New Album** → name alert → empty album appears.  
   **See:** row counts; selected collection synopsis under the name. Context menu: Edit as Advanced Filter… / Edit Collection… (smart) or Rename Album…; Delete Collection / Delete Album.

4. **Rating / Duration / Quality**  
   Set stars, duration chips or min/max minutes, quality buckets (SD…8K+).  
   **See:** matching count in the drawer header; wall filters live. Clear accessories reset that card.

5. **TAGS**  
   Search tags, click chips (ANY/ALL mode if shown), create a tag, rename/delete via alerts.  
   **See:** library filters; Inspector tags stay in sync.

6. Close the drawer (⌘⇧F).  
   **See:** **filter pills** under the header when filters are active; **Clear all** (⌘⌥C) resets Quick filters. Collection pill can remain while collecting.

7. **Advanced** tab — add a rule (Title contains…, Rating, Tag, Quality, Membership, custom field if any).  
   **See:** exclusive with Quick (Quick sidebar picks do not linger). **Save as Collection…** alert: “Creates a smart collection from the current Advanced Filter.” **Clear** removes Advanced conditions.

---

## 9. Multi-select / collection pill

1. Select 2+ videos (⌘-click).  
   **See:** pill **“N videos collected”** (never “1 videos”; 1-video wording exists in code but the pill only shows for 2+).

2. Click the pill.  
   **See:** Inspector batch bar “N Videos Selected” + **Clear**.

3. Press **A** (no modifiers) on a focused card.  
   **See:** Toggle in Selection — card joins/leaves the set.

4. **⌘⇧A** or Inspector **Clear** or pill **×**.  
   **See:** set empty; pill gone.

---

## 10. Inspector (⌘I)

1. With nothing useful selected (or after clear).  
   **See:** empty state “Select a video in the grid”.

2. Select one video.  
   **See:** hero (still or filmstrip via **View → Toggle Thumbnail / Filmstrip** ⌘⌥T); drag handle resizes hero. Title; on-disk name if different; path (click → Finder). **Play**. Facts: resolution/fps · duration · size · codec · date added · “N play(s)” · **Subtitles** menu (None / Burned-in / Sidecar / Burned-in + Sidecar).

3. Click **stars** in Rating.  
   **See:** rating persists; Top Rated / sort by Rating update.

4. **Tags** — type in New Tag, Return; click assigned chip to remove; open **Add tags** blind.  
   **See:** tags apply to the current target (clip vs batch). Blind open/closed follows Settings → Video → Tag blind default (always closed / always open / last used).

5. **Bookmarks** (single selection) — add from player ⌘⌥B; rename in Inspector; delete.  
   **See:** list updates; player can jump to them.

6. **Settings → Custom Metadata** — add a field (name + type). Return to Inspector.  
   **See:** field editor; mixed multi-select shows blank and does not wipe others on focus/blur; edit persists to the selection that was loaded.

7. Hide Inspector (⌘I) after a **long scroll**.  
   **See:** wall expands immediately; Compact Storyboard 3→4; no crash.

8. Show Inspector (⌘I).  
   **See:** content paints immediately (hero/metadata, not a blank column); last divider width restored; wall does not remount. (§16)

9. Drag the split divider.  
   **See:** widths persist across view-mode switches (browsing layout).

---

## 11. Player

1. Play a video (Space, double-click, Inspector Play).  
   **See:** floating player (opens at Settings → Video → Player opens at: Compact / Full screen / Last used size). Browser layout does **not** jump.

2. Hover the player.  
   **See:** transport: play/pause, skip 15s, **Playback Speed**, volume, **Captions** (only if sidecar `.srt` or in-band tracks exist).

3. **Captions** menu.  
   **See:** Off · Sidecar (.srt) if present · named in-band rows. **Never** “Media group N”. English SDH (or language name), not AV junk titles.

4. **Show filmstrip in player** on (Settings → Video).  
   **See:** 1×N strip above the scrubber (thinner in Compact). Drag/click is **continuous / linear** with the playhead.

5. Scrub the bar.  
   **See:** preview thumbnail; playhead tracks. ←/→ nudge 5s while playing; ⌥← / ⌥→ skip 15s.

6. **Space** pause/play. **⌥-Space** or View → Restart from Beginning.  
   **See:** pause; restart from 0 (ignores resume).

7. Stop mid-video, play the same file again.  
   **See:** “Resumed at mm:ss” + **Start at beginning**. Optional fade per Settings → Video → Fade resume banner.

8. **⌃⌘C / ⌃⌘W / ⌃⌘F** (View → Compact / Windowed / Toggle Full Screen).  
   **See:** Compact needs Inspector visible; Windowed from compact; full screen is a separate borderless window. Traffic-light-style controls on the player match those modes.

9. **⌘⌥M** Make Thumbnail from Current Frame.  
   **See:** poster updates to that frame.

10. **⌘⌥B** Bookmark Current Position.  
    **See:** bookmark appears in Inspector; ghost on the scrubber.

11. **Escape** while playing.  
    **See:** player closes (including fullscreen). Escape first cancels title/file/tag rename if those are active.

12. Missing/unreadable file.  
    **See:** **Playback Failed** overlay; Reconnect… if that path is missing.

13. **File → Play in External Player** (⌘↩) / **Open With**.  
    **See:** default app or chosen app opens; play count increments.

14. Play All through 2+ videos; toggle Loop.  
    **See:** advances to next filtered video; loop restarts or stops at end.

---

## 12. Tags, ratings, play history

There is **no Favorites / heart** control. Keywords in the product are **Tags**.

1. Rate 1–5 in Inspector; filter Rating in Quick Filter; sort by Rating.  
   **See:** consistent stars.

2. Assign/remove tags from Inspector and from the Tags card.  
   **See:** same names; search finds tag text if that’s how search is wired for the clip title — primarily filter by tag chip.

3. Play a video to the end (or external play).  
   **See:** Inspector “N plays”; List **Plays** / **Last played**; Quick Filter **Recently Played** includes it (within Settings days).

---

## 13. File operations, queues, metadata

1. Context menu **Move Files…** → pick a folder.  
   **See:** Move Queue sheet (View → Move Queue…); activity strip; paths update; rename/delete disabled on moving files.

2. **Fix for Built-in Player…** (needs Settings → Tools FFmpeg path).  
   **See:** Re-encode Queue sheet; “Recently Converted” can populate. Without ffmpeg, item is disabled (“Requires ffmpeg — configure the path in Settings → Tools”).

3. **Modify Filmstrip…**  
   **See:** `FilmstripConfigView` sheet (rows/columns); collage regenerates; Inspector filmstrip refreshes.

4. **Set Poster from Image…** / **Regenerate Thumbnail**.  
   **See:** poster changes; hero updates.

5. **Export Metadata…** (File or context).  
   **See:** export sheet (filtered vs selection scope); file written.

6. **Import Metadata…** (⌘⌥I) — pick CSV/JSONL.  
   **See:** unknown-columns sheet if needed; summary sheet; **Last Metadata Import** smart library if matches > 0.

7. **Bulk Rename…**  
   **See:** pattern sheet; preview; apply/cancel; disk names change or restore on cancel.

8. **Delete…** (⌘⌫) with Confirm deletions on.  
   **See:** “Delete Video” / “Delete N Videos”; “moved to Trash.” Cancel leaves files. With confirm off, delete is immediate.

9. **Remove from Library** (⌘⌥R).  
   **See:** gone from catalog; file remains on disk.

---

## 14. Missing files, Reconnect, undo

1. Rename or unmount a folder that the library still points at (or use a known-missing clip).  
   **See:** banner above the wall: title/body/CTA from the situation — **“Reconnect…”**. Wording uses **video / videos** (never “1 videos”). Icons: folder.badge.questionmark / doc.badge.ellipsis / folder.badge.gearshape. Body can be “Checking…” then the real copy.

2. Click **Reconnect…** or **File → Reconnect…**.  
   **See:** **Reconnect** sheet: “Add destination…”; Ready / Needs attention / Still missing; nothing rewritten until confirm.

3. Add the folder where files now live → Continue → Apply (Ready only, then with Needs attention if you choose).  
   **See:** paths update; Done step; videos play.

4. **Edit → Undo Reconnect** (⌘Z) immediately.  
   **See:** enabled only with a pending undo; paths revert. Disabled while apply is running.

5. Duplicate evidence paths.  
   **See:** each file listed once in the preview (nested dest wins).

---

## 15. Settings (⌘,)

Window titled **Settings**, hidden title bar, sidebar + cards. Search field filters the catalog and jumps to a category (empty → system search unavailable view).

With **no** library open, Video / Data Sources / Tools / Custom Metadata / most Library cards show **“Open a Library”**.

1. **Library** — Exclude corrupt files from filters · Confirm deletions · Change Library Location… · Change Thumbnail Cache Location… (path is selectable) · Automatically check for updates (Sparkle; **no analytics**) · Smart Libraries toggles + days / min stars · List view column checkboxes.

2. **Video** — Default Filmstrip Size (rows 1–6, columns 1–8, frame count, Regenerate filmstrips) · Surprise Me auto-play · Loop Play All · Hover preview · Tag blind default · Filter drawer height (Fit to content / Last used) · Player opens at · Show filmstrip in player · Fade resume banner + seconds.

3. **Data Sources** — Folders list, Add Folder…, exclude subfolder.

4. **Extensions** — toggles per ext, Add, Reset to Defaults.

5. **Tools** — FFmpeg status + path (file picker).

6. **Custom Metadata** — Fields list, Manage / New field sheet (name + type).

7. Close Settings; reopen.  
   **See:** toggles persist.

---

## 16. 1.3.0 freeze + 1166–1169 (mandatory)

Do this **after a long Storyboard/Grid scroll** so pin + clip are dirty.

1. **⌘I hide** — wall expands now; Compact 3→4; no crash (inverted-range clamp).

2. **⌘I show** — Inspector **paints** (hero + metadata). Divider = last width. Compact back to 3. No 2–3s stall. Wall does not remount.

3. Scroll Grid, List, Storyboard.  
   **See:** rolodex HUD on the **wall** scroller, live while scrolling.

### Must not return

| Build | Failure | Pass |
| --- | --- | --- |
| **1166** | Show Inspector = blank pane; divider not last width | Content paints; divider restored |
| **1167** | Show stalls 2–3s / park-host blank | Show as cheap as hide; host stays arranged, clipped when hidden |
| **1168 / 1169** | HUD missing (0×0 host or Inspector scroller) | Chip on wall NSScrollView |

Also fail the freeze: Compact stuck at 3 after hide; “Media group N” in Captions; ⌘I crash.

Other 1.3.0 surfaces already in this script: Storyboard seek/play/density/poster, in-player filmstrip + linear scrub, Captions menu, collection pill “N videos collected”, Reconnect preview/dedupe/banner wording.

---

## 17. Help, About, updates

1. **Skagway → About Skagway**.  
   **See:** name, marketing version, “build NNN”, “Free forever.”, © year Mach II Labs, machiilabs.com. No subscription language.

2. **Skagway → Check for Updates…**.  
   **See:** Sparkle dialog (up to date, or an update). Disabled only if Sparkle cannot check. Does not upload library/media.

3. **Help → Skagway Help**.  
   **See:** browser opens `https://machiilabs.com/skagway/manual`.

4. **Help → Contact Support…**.  
   **See:** mail to `support@machiilabs.com` (subject Skagway support request).

---

## 18. Library file ops / empty / error

1. **File → Save Copy…**.  
   **See:** save panel; copy written; original library stays open; cache pointer on the copy is the original’s (Save Copy does not retarget cache).

2. **File → Change Thumbnail Cache Location…**.  
   **See:** folder picker; this library’s cache path updates; other libraries untouched.

3. **File → Change Library Location…**.  
   **See:** app quits; next launch is the §1 chooser. Media files are not deleted.

4. **File → Delete This Library…**.  
   **See:** warning “permanently delete the library file… cannot be undone.” Cancel safe. Delete removes the catalog file only.

5. Empty filter result (search garbage).  
   **See:** “0 videos”; wall empty; no crash.

6. Corrupt / Missing smart libraries.  
   **See:** those clips only; exclude-corrupt setting hides them from other filters but they remain in Corrupt and name search.

---

## Keyboard cheat sheet (already exercised above)

| Key | Action |
| --- | --- |
| Space / ⌥-Space | Play-pause / play from beginning |
| ← → (playing) | Nudge 5s |
| ⌥← ⌥→ | Skip 15s |
| Arrows (browser) | Move selection |
| Home / End | First / last |
| Page Up / Down | Scroll viewport |
| Return | Edit title (if not in a text field) |
| Escape | Cancel edit → defocus text → stop playback |
| A | Toggle focused clip in collected set |
| ⌘F | Focus search |
| ⌘1 ⌘2 ⌘3 | Grid / List / Storyboard |
| ⌘I | Inspector |
| ⌘⇧F | Filter drawer |
| ⌘⌥Q / ⌘⌥A / ⌘⌥C | Quick / Advanced / Clear filters |
| ⌘, | Settings |

Text fields (search, rename, New Tag, custom metadata, filter create-tag) keep Space / arrows / ⌘A.

---

## Inventory notes (for the tester, not extra steps)

**In the app, covered above:** first-launch chooser (3 steps), Landing, empty-library drop zone, File library lifecycle, header, three browse modes, HUD, filter drawer + pills, Inspector (hero, facts, rating, tags, bookmarks, custom fields, batch), player (filmstrip, scrub, captions, resume, compact/windowed/fullscreen, bookmarks, external), Reconnect + undo, Settings (6 categories), Sparkle, Help/About, context menus, queues, export/import/rename, delete/remove.

**Not in the UI (do not look for them):** Favorites; a dedicated Notes editor (stale comments only); “keywords” as a separate noun (use Tags).

**Opened but not exhaustively token-tested:** every Bulk Rename token, every export column, every Advanced Filter operator, every Open With app, Sparkle’s full install flow, Collection editor every nested group. If those sheets open and cancel cleanly, mark the parent step pass and note “deep tokens not walked.”
