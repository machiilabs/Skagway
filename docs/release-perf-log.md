# Release performance log (~12k library)

**Mandatory before every release.** A human on a Mac backs up the large library, builds a **new** catalog from the same folders, and records timings here. Agents do not drive the GUI and must not skip or invent this pass.

**Privacy:** counts, seconds, and feel only. Do **not** paste filenames, folder paths, titles, or wall screenshots.

First-pass baseline (already-indexed, not a from-scratch rebuild): [`v1.0-perf-audit.md`](v1.0-perf-audit.md) — Skagway 0.80.0, **12,174** videos, 2026-09-03.

Full click-path: [`human-qa-script.md`](human-qa-script.md) § **Before every release**.

---

## Why from scratch

Opening last release’s `.machii` only measures a warm catalog. Recreating from **File → New Library…** + **Add Folder…** / scan is the only way to catch import, first-index, and cold-cache regressions.

**File → Save Copy…** writes one `.machii`. It does **not** switch libraries. The copy **keeps the original cache pointer** (`library_cache`). The new library gets its own cache (default: sibling `Skagway-cache`).

---

## Pass bar

Reuse the 0.80.0 bar on the **finished** rebuilt library (All Videos, after the first screen of cards is usable). Rebuild/import has its own clocks — compare those to the previous **rebuild** row, not to A–M.

| Scenario | Pass | Fail |
| --- | --- | --- |
| Cold start to usable grid (open rebuilt lib) | Window + first screen of cards within **~8 s**; not beachballed | Spin / unresponsive **>15 s** |
| Filter / search apply | Count updates within **~2 s**; window stays clickable | Multi-second freeze; beachball |
| Scroll / Home / End | Continuous motion; brief thumbnail pop-in OK | Stutter that stalls scroll, or **>2 s** freeze |
| Sort (same membership) | Reorder without full-grid flash rebuild | Whole grid tears down / long hitch |
| Select 1, then ~20 | Inspector updates; grid does not re-layout | Grid hitch or inspector lag **>1 s** |
| Play / Esc | Player opens/closes without reshaping the wall | Wall relayout, scroll jump, or long hitch |
| Rebuild (this gate) | Import finishes; toolbar count matches the backup (± a few if disk changed); app stays usable | Hang, crash, lost rows vs backup, or rebuild **much** slower than last release without a known cause |

Thumbnail backfill while scrolling is expected and is not a fail by itself.

---

## How to record

1. Run the script in [`human-qa-script.md`](human-qa-script.md) (**Before every release**).
2. Copy the **blank row template** below into **Log**.
3. Fill version, build (About Skagway), date, toolbar count, rebuild clocks, A–M, verdict.
4. Compare to the previous row. Call out any scenario that got worse.
5. Commit this file with the release (or immediately before announce).

Stopwatch is enough. No app telemetry. No Instruments unless you are chasing a fail.

---

## Blank row template

```
### X.Y.Z (build NNN) — YYYY-MM-DD

| Fact | Value |
| --- | --- |
| App | Skagway X.Y.Z (NNN) |
| Backup | File → Save Copy… done (copy not opened for the rebuild) |
| Toolbar count after rebuild (All Videos) | |
| Backup toolbar count (same folders) | |
| Rebuild: Add Folder + scan until count stable | s |
| Rebuild: first screen of posters usable | s |
| Cold open of rebuilt library (dock or Open Recent) | s |
| Verdict | PASS / FAIL (watch: …) |

| ID | Scenario | Result | Seconds | vs last release |
| --- | --- | --- | --- | --- |
| R1 | Add Folder / scan to stable count | | | |
| R2 | First screen of cards usable after import | | | |
| R3 | Cold open rebuilt library | | | |
| A | Cold start, Grid, All Videos | | | |
| B | Scroll Grid ~2–3 screens, then fling | | | |
| C | Home, then End | | | |
| D | Quick Filter: one rating star | | | |
| E | Clear filters | | | |
| F | Search: one common letter, wait for count | | | |
| G | Clear search (×) | | | |
| H | Click one card; click another | | | |
| I | Shift-select ~20 | | | |
| J | Space to play, Esc to stop | | | |
| K | List (⌘2); Home/End | | | |
| L | Change Sort (Date Added / Title) | | | |
| M | Surprise Me (⌘⇧S) | | | |
| N | Storyboard (⌘3) scroll + Compact ⌘I hide/show | | | 1.3.0+ |
```

---

## Log (newest first)

### 0.80.0 — 2026-09-03 (baseline — already-indexed; not a from-scratch rebuild)

Copied from [`v1.0-perf-audit.md`](v1.0-perf-audit.md). Use this only as the A–M bar until a rebuild row exists.

| Fact | Value |
| --- | --- |
| App | Skagway 0.80.0 |
| Backup | not this pass |
| Toolbar count | **12,174** |
| Rebuild clocks | **not measured** (warm catalog) |
| Cold launch | Dock → usable grid **3 s**; Open Recent **4 s** |
| Verdict | **PASS** (watch: sort) |

| ID | Seconds | Notes |
| --- | --- | --- |
| A | 3 s dock; 4 s Open Recent | Usable grid |
| B | — | Smooth |
| C | &lt; 0.5 s each | |
| D | &lt; 0.25 s | |
| E | &lt; 0.5 s | |
| F | ~1 s | Query one letter only |
| G | &lt; 0.5 s | |
| H | 0.25–&lt;1 s | |
| I | &lt; 0.5 s | |
| J | &lt; 0.5 s | |
| K | ⌘2 &lt;1 s; Home/End &lt;0.25 s | |
| L | Date Added ~2.5 s; Title ~2 s | Slowest; no tear-down |
| M | ~1 s | |
| R1–R3 | — | Scan / from-scratch not part of this pass |
