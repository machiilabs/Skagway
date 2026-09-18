# Skagway Roadmap

This document captures the high-level vision and major phases for Skagway. Detailed feature and improvement ideas are captured here (under the relevant Phase) or in `AI-IMPROVEMENTS.md`. (Older separate files `IMPROVEMENTS.md` and `DEVELOPMENT_SUMMARY.md` have been retired into this roadmap.)

**Public GTM / Skagway launch plan:** see [`docs/SKAGWAY-GTM-PLAN.md`](docs/SKAGWAY-GTM-PLAN.md) (**free forever**, branding, site, competitive tracks A–C). Planning only until executed. Product display name locked: **Skagway**.

## Vision

A fast, native macOS app that lets people **find, organize, and enjoy** their personal video libraries — without forcing them to move files into a proprietary container.

Key qualities:
- Excellent performance even with thousands of videos
- Deep macOS integration and keyboard-driven workflow
- Respect for the user's existing folder structure
- High-quality inline playback + useful organization tools (ratings, tags, collections, custom metadata)

## Current State (as of v0.80.0)

**v1.0 candidate surface is shipped.** Feature audit (2026-09-03): no half-finished items in this set. Remaining 1.0 work is the readiness pass (tests expansion, 10k perf, review, security), not new features. Tracker: [`docs/v1.0-readiness-checklist.md`](docs/v1.0-readiness-checklist.md).

**Browsing & organization**
- **Curated Wall**: grid + Inspector + collapsible filters drawer (smart libraries, collections, rating/duration, tags, quality chips); wall and drawer sizes persist
- **Quick Filter**: rating (exact / Or Higher / No Stars), duration, tags, quality; filter pills; save/apply as collections
- **Collections**: two-level AND/OR grouping
- **Albums**: saved playlist order (`sortIndex`), drag-and-drop reorder in grid and list (album-only)
- **Duplicates**: `ContentFingerprint` (size + first/last bytes) with “Not a Duplicate”
- **Tags** and **custom metadata** (per-library; sort and list columns)
- **Search** across title, file name, original file name, tags, and custom fields
- Smart libraries: **Missing** (manual filesystem refresh) and **Corrupt** (metadata + recheck on select); **Repair Links** reconnects a moved folder tree from Missing / File menu
- Drag-and-drop import; empty-library invite; **exclude folders** from Scan; Last Added
- Library titles; Bulk Rename; library home + **per-library** thumbnail/filmstrip cache

**Playback**
- One floating player (Compact / Windowed / Full) via `InlinePlaybackController`; sidecar SRT; resume on cards; Play from Beginning
- **Play All** (⌘⇧P) plays the **current filtered view** from the first video; auto-advance and **Loop** only while that session is active
- Bookmarks (⌥⌘B); import play counts + resume; four-value subtitle presence

**Queues & files**
- Crash-safe **re-encode** and **move** queues (abort, persist, pills)
- Thumbnail tools including Set Poster from Image

**Keyboard & chrome**
- Home/End, grid arrows, shortcut rationalization, Help URL, activity strip
- Sparkle in-app (feed publish is GTM, not a 1.0 feature gap)

**Architecture**
- ViewModel + Repository, GRDB sequential migrations (no `eraseDatabaseOnSchemaChange`)
- Large-library filter/count work off-main; `filteredVideos` single recompute path
- `os_signpost` is **not** currently in source (perf audit must add timing or use another method)

## Path to v1.0

**v1.0.0 on `main`** is shipped (2026-09-03). The readiness pass is complete:

1. **Regression tests** — **done** 2026-09-03. `SkagwayTests`: **107 passing** (rating Quick Filter, collection AND/OR, Play All advance, corrupt heuristic, fingerprints, migrations). XCUITest is a later tier.
2. **Performance audit** — 10k+ videos (cold start, filter, scroll, playback). Do **not** assume existing `os_signpost` (none in tree).
3. **Feature audit vs this roadmap** — **done** 2026-09-03. Current State matches v0.80.0; nothing 1.0-critical is half-finished. See checklist §3.
4. **Code review** — **done** 2026-09-03. No outstanding feature branches; Bugbot on `main` (focus list) found no bugs. Use `skagway-code-review` on future branches.
5. **Security audit** — **done** 2026-09-03. See `docs/v1.0-security-audit.md`. No medium+ issues; no default telemetry.

Distribution stays Developer ID DMG. **No Mac App Store** — do not scope MAS/sandbox as future work.

## Major Themes / Phases (High Level)

### Phase 0 — Foundations (complete)
- Core browsing, metadata, playback, scanning
- Performance baseline
- Build / release discipline

### Phase 1 — Polish & Reliability (substantially complete)
- Curated Wall redesign, unified playback engine, Duplicates rework, and Collections grouping (above) closed out the major known UX friction and reliability gaps from this phase
- Remaining polish surfaces primarily through the v1.0 readiness pass above, not a fixed backlog

### Phase 2 — Power User & Organization Features
- **Done (landed before 1.0, not a 1.0 blocker):** search beyond filename; exclude folders from Scan; Bulk Rename and other multi-select batch actions
- **Reconnect (shipped in 1.3 tip):** Evidence Destinations, Ready / Needs attention / Unmatched, Undo (evolved from Repair Links / Location Relink)
- **Still Phase 2 (not required for 1.0):** auto-import / watch folders; auto-tagging ideas (see `AI-IMPROVEMENTS.md` — filename heuristics first)
- **Notes:** do **not** add a built-in notes field. Users who want one create a custom **Text** field (multiline). That type already sorts, filters, searches, and exports.
- **In-player filmstrip (1.x signature playback — planned):** see design + implementation plan below

### In-player filmstrip — design & implementation plan

**Goal.** Make “see the clip as frames” continuous from browse → play: Storyboard wall and Inspector filmstrip already teach frame thinking; the floating player should show a **horizontal frame strip above the scrubber** so the playhead sits under the sample you’re in. Differentiator vs Photos / QuickTime / most organizers that only expose a thin timeline.

**Non-negotiable chrome rule.** The strip is part of the **same transport chrome overlay** as today’s scrubber (`PlaybackTimelineBar` + play/pause cluster). It must:

- Share the existing `controlsVisible` flag (Compact / Windowed via `FloatingPlayerPanel`; Fullscreen via `FullscreenTransportChromeView`)
- **Fade in and fade out together** with the scrubber (same opacity / hit-testing / animation — do not invent a second idle timer or a always-on strip)
- Count as part of the transport stay-up zone (hovering the strip keeps chrome visible, same as hovering the scrubber band today)

Picture area stays clean when chrome idles out; the strip never becomes a permanent letterbox under the video.

**Layout**

```
┌─────────────────────────────────────────┐
│              video picture              │
├─────────────────────────────────────────┤  ← transport chrome (fades as one unit)
│  [f1][f2][f3] … [fN]   ◀ playhead mark  │  ← in-player filmstrip
│  ──────●──────────────── scrubber ────  │  ← existing precise scrubber
│  ▶  0:12 / 3:40   bookmark ticks …      │
└─────────────────────────────────────────┘
```

- Strip sits **directly above** the scrubber inside the bottom chrome stack (not a separate panel, not Inspector reuse)
- Full-width of the player content area; fixed strip height (short); do not steal Compact vertical budget without a thin mode
- Bookmark diamonds stay on the scrubber track (not duplicated on every strip cell)

**Density & samples**

- Fixed **N frames across** the bar (target ~8–12; tune in implementation) — scales better than a full-resolution strip for long files
- Prefer reusing / extending existing bake paths (`ThumbnailService` filmstrip or a dedicated 1×N player-strip cache) over live AVImageGenerator on every hover
- Playhead indicator snaps to the **nearest sample** for orientation; do not claim frame-exact coverage unless denser samples exist
- Optional later: denser strip for short clips; thinner/hidden strip in Compact

**Interaction**

| Control | Role |
|--------|------|
| Frame strip | Coarse navigation + spatial orientation; click (and optional drag) seeks to that sample’s time and keeps playing |
| Scrubber | Precise seek (unchanged); hover frame preview stays |
| Strip vs hover preview | Complementary — strip = always-visible map when chrome is up; hover = continuous scrubber peek |

- Do **not** replace the scrubber with the strip
- Do **not** auto-open Inspector Filmstrip when the player strip is visible
- Keyboard / VO: strip cells need labels + adjustability consistent with the a11y P0 timeline work

**Mode defaults (v1)**

| Mode | Default |
|------|---------|
| Windowed | On |
| Full screen | On |
| Compact | On but **thin** (or Settings toggle off) — Compact already shares Inspector footprint; protect picture height |

Setting: **Show filmstrip in player** (default on). No second idle preference.

**Implementation plan (ordered)**

1. **Chrome contract first** — Extend the bottom transport stack so strip + scrubber + transport icons are one view tree driven by a single `controlsVisible`. Verify fade, hit-testing, and idle stay-up in Compact, Windowed, and Fullscreen before polishing art.
2. **Sample source** — Add or reuse a 1×N bake keyed by file path (+ duration epoch); coalesce generation with existing thumbnail/filmstrip gates; memory + disk cache.
3. **Strip UI** — Horizontal cells, playhead marker synced to `playback` time (nearest sample), click → `seek(toSeconds:resumePlayback: true)`.
4. **Idle / layout QA** — Confirm strip height is included in the transport stay-up hit band; no double-fade; no always-visible strip when chrome is hidden; Compact still usable.
5. **Settings + manual** — Pref default on; document alongside scrubber (not as a separate “mode”).
6. **Out of v1 scope** — Waveform, per-frame exact scrub from strip alone, Storyboard wall reuse as the player strip, replacing Inspector Filmstrip.

**Success criteria.** In daily use, “where am I in this clip?” is answerable at a glance whenever transport chrome is visible, with zero extra chrome timers and no regression to scrubber precision or idle fade behavior.

### Phase 3 — AI Augmentation (exploratory)
- See `AI-IMPROVEMENTS.md`
- Potential areas: semantic search, smart tagging, content-aware suggestions, duplicate detection

### Phase 4 — Distribution & Longevity
- **Locked path:** direct download via **Developer ID + notarized DMG** (`scripts/package_dmg.sh` → `dist/Skagway.dmg`). Stay unsandboxed so arbitrary folders + optional ffmpeg work. **Not going on the Mac App Store** — do not plan a sandbox/MAS variant.
- Host DMG on downloads.machiilabs.com; Sparkle in-app is implemented — publish `Skagway.appcast.xml` alongside `Skagway.dmg` when downloads go live (`docs/SPARKLE.md`).
- **User manual (source of truth):** [machii-labs `/skagway/manual`](https://machiilabs.com/skagway/manual) — `machii-labs/src/app/skagway/manual/`. Repo stub `docs/USER_GUIDE.md` only points there. Completeness is a docs-readiness item, not a Skagway feature.

## Guiding Principles

1. **Performance is a feature.** Large libraries must feel responsive.
2. **Native first.** Leverage SwiftUI + AppKit where it makes the experience better, not just "web-like".
3. **Respect the filesystem.** The app indexes and enhances; it does not own the user's files.
4. **Keyboard and efficiency matter.** Many users will have hundreds or thousands of clips.
5. **Incremental, high-quality releases.** Prefer shipping small, solid improvements over big risky ones.

## How to Use This Document

- When starting a large body of work, check here first.
- Update this file when major themes shift or new phases are defined.
- Keep detailed task lists here (under the appropriate Phase) or in GitHub issues.

---

*Last significant update: 2026-09-18 — documented in-player filmstrip (same fade chrome as scrubber); Reconnect noted as shipped in 1.3 tip.*