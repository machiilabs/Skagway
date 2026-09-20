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
- **In-player filmstrip** + bookmark leave-point (ghost playhead / Return) on `main` tip

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

Distribution is **direct + Sparkle only** (Developer ID DMG). **Mac App Store is a never** — sandboxing would break arbitrary folders + optional ffmpeg. Do not list MAS/sandbox as future or deferred work.

## Path to impartial 9 (product finish)

Two different rulers — do not mix them:

| Ruler | What it measures | Current (2026-09-18) |
|-------|------------------|----------------------|
| **Organizer supremacy** | Vs peer Mac *library organizers* (browse / filter / batch / Reconnect / Storyboard / playback navigation) | **~9.9 / 10** |
| **Impartial product review** | Absolute Mac-app finish a careful reviewer would give (a11y, captions, format trust, daily polish) | **~8.2 / 10** → target **9** |

IPF, Reconnect, Storyboard, and batch/inspect polish raise the supremacy ladder. They do **not** by themselves close the impartial gap. Earning **9** means a reviewer can watch, navigate, and trust the catalog without hitting VoiceOver dead ends, caption helplessness, or “will this file play?” ambiguity.

### Already counted toward the impartial score (not the remaining point)

- Reconnect (Evidence Destinations, Ready / Needs attention / Unmatched, Undo)
- Storyboard as a first-class browse mode (⌘3)
- Interaction papercut burn-down (collection/batch, Inspector pin, Storyboard clicks)
- **In-player filmstrip + leave-point Return** — shipped on `main` (optional for 9; strengthens supremacy / playback navigation)

### Required for impartial 9 (ordered)

Ship **all three**. Partial credit does not get to 9.

#### 1. Accessibility P0

**Goal.** Core browse → inspect → play loops work with VoiceOver and Full Keyboard Access without hover-only traps.

| Area | Done when |
|------|-----------|
| Wall / Storyboard cards | Each card has a real accessibility name (title + key facts), not icon soup |
| Toolbar / rating | Icon-only controls have `.accessibilityLabel` (`.help` alone is insufficient) |
| Scrubber / filmstrip | Adjustable actions for seek / strip step; captions control is reachable |
| Settings destructive | Confirm / delete actions are keyboard-reachable (not hover-gated) |
| Captions (a11y half) | On/off is a real control (overlaps workstream 2) |

**Out of P0 for the 9 bar:** full Dynamic Type pass, AAA contrast, XCUITest a11y suite. Use `skagway-a11y-audit` for findings; P0 = Critical + blocking Serious on the audit surfaces list.

**Success criterion.** A VoiceOver user can open a library, focus a clip, play it, scrub, and toggle captions without a dead end on those paths.

#### 2. Captions as a first-class watch feature

**Goal.** Sidecar captions are something the user *drives* while watching — not only metadata badges and an always-on auto overlay.

**Already shipped (foundation, not first-class)**

- Sidecar `.srt` discovery + parse + timed overlay
- `SubtitleTrack.isEnabled` (no player UI yet)
- Four-value Inspector presence + CC badges on cards
- Generation stays **outside** Skagway (e.g. Submarine) — do not build ASR into Skagway for this bar

| Capability | Done when |
|------------|-----------|
| Toggle | Captions / CC control on the player transport (Compact / Windowed / Full); keyboard shortcut |
| Multi-sidecar | If several `basename*.srt` exist, user can pick which track (not silent English/shortest-wins only) |
| Empty honesty | No sidecar → control disabled or explicit “None,” not a dead affordance |
| Memory | Remember last on/off (and preferred language when chosen) for the session or prefs |
| Manual | Documented under Playback on the machii-labs manual |

**Out of scope for 9:** burned-in OCR, embedded mov_text muxing UI, caption editing, generating `.srt` inside Skagway.

**Success criterion.** With a multi-language sidecar set next to a clip, a user can show/hide captions and switch tracks in under two clicks (or one shortcut + menu), in every playback mode.

#### 3. Importer / format confidence

**Goal.** Users trust what Skagway will catalog vs play vs refuse — fewer ugly-file surprises. Not a 2014 importer rewrite.

| Capability | Done when |
|------------|-----------|
| Clear contract | Documented / in-app story: catalogs (indexed), plays (AVFoundation), needs helper (optional ffmpeg path), open externally |
| Scan honesty | Unsupported or dubious files don’t silently look “fine” then fail at play with no explanation |
| Play failure | Actionable error (codec/container hint, Open in External Player when appropriate) — not a blank panel |
| Evidence | Short matrix or Settings/help note covering common containers as actually behaved |

**Out of scope for 9:** full ffmpeg decode pipeline in-process, watch folders, auto-transcode-on-import.

**Success criterion.** A new user with a mixed folder can predict which clips will play in Skagway vs need external/re-encode, and a failed play always says why and what to do next.

### Explicitly not required for impartial 9

- Watch folders / auto-import
- Auto-tagging (filename or vision)
- Pre-Tahoe OS support
- Infuse-level codec coverage
- Collection icons

Those may raise supremacy or GTM tracks; they are **not** the 8.2 → 9 checklist.

**Will-not-do (not deferred):** Notes / descriptions are **already won** via custom **Text** fields (including a user-created “Notes”) — not a gap and not a reason to add a built-in Notes column. **Mac App Store / sandbox is a never** — distribution is direct Developer ID DMG + Sparkle only.

### How we’ll know we’re at 9

Re-score on the **impartial** ruler only after all three workstreams meet their success criteria above. Organizer supremacy may already be ~9.9; leave that ladder alone when judging this bar.

---

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
- **Still Phase 2 (not required for 1.0 / not on the impartial-9 bar):** auto-import / watch folders; auto-tagging ideas (see `AI-IMPROVEMENTS.md` — filename heuristics first)
- **Notes / descriptions (won via custom fields):** A user-created multiline **Text** field (named “Notes” or anything else) already sorts, filters, searches, and exports. That is strictly better than a single built-in Notes column — do **not** add one.
- **In-player filmstrip (shipped on `main`, 1.3 tip):** horizontal strip above the scrubber; shared `controlsVisible` fade; Settings → Show filmstrip in player. Leave-point ghost playhead + Return chip. Design notes below for history.

### In-player filmstrip — design notes (shipped)

**Goal.** Make “see the clip as frames” continuous from browse → play: Storyboard wall and Inspector filmstrip already teach frame thinking; the floating player shows a **horizontal frame strip above the scrubber** so the playhead sits under the sample you’re in.

**Non-negotiable overlay rule.** The strip is part of the **same transport overlay** as the scrubber (`PlaybackTimelineBar`). It shares `controlsVisible`, fades with the scrubber, and counts toward the stay-up hit band. Picture stays clean when transport idles out.

**Shipped shape.** Track-aligned width; N from width for ~16:9 cells; dedicated player-strip bake; click seeks to bucket center; Compact uses a thinner strip; bookmark diamonds stay on the scrubber; ghost playhead + Return under leave point after a bookmark jump.

**Out of v1 scope (still).** Waveform, per-frame exact scrub from strip alone, Storyboard wall reuse as the player strip, replacing Inspector Filmstrip.

### Phase 3 — AI Augmentation (exploratory)
- See `AI-IMPROVEMENTS.md`
- Potential areas: semantic search, smart tagging, content-aware suggestions, duplicate detection

### Phase 4 — Distribution & Longevity
- **Locked path (will-not-do MAS):** direct download via **Developer ID + notarized DMG** (`scripts/package_dmg.sh` → `dist/Skagway.dmg`) + Sparkle. Stay unsandboxed so arbitrary folders + optional ffmpeg work. **Mac App Store is a never** — sandboxing is incompatible; do not plan a MAS variant.
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
- For impartial finish work, use **Path to impartial 9** above — not Phase 2 leftovers — as the checklist.

---

*Last significant update: 2026-09-19 — Notes won via custom Text (not a gap); MAS/sandbox is a never (direct + Sparkle only), not deferred. Path to impartial 9 (2026-09-18) unchanged otherwise.*
