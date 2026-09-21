# AGENTS.md — Skagway

This document defines how AI agents (Cursor, Claude, etc.) should work on the Skagway project.

## Project Snapshot

- **Name**: Skagway
- **Type**: Native macOS SwiftUI application
- **Target**: macOS 26 (Tahoe)
- **Stack**: SwiftUI + GRDB.swift (SQLite) + AVFoundation
- **Architecture**: MVVM + Repository pattern
- **Current version**: See `project.yml` (`MARKETING_VERSION`)

**Core constraint**: Child views receive `LibraryViewModel` and `ThumbnailService` **as explicit parameters**, not via `@Environment`. This is required because macOS `Table`, `Menu`, and `NavigationSplitView` often render in isolated window contexts.

## Core Workflow Rules (Non-Negotiable)

1. **After every code change (CRITICAL — non-negotiable)**
   - Run **only** the official build script — never substitute raw `xcodebuild build`:
     ```bash
     bash scripts/build_and_install.sh
     ```
   - Every normal run **must**: bump `CURRENT_PROJECT_VERSION`, build Release, copy to `/Applications/Skagway.app`, run `cleanup_stray_skagway_apps.sh`, and print the final line.
   - **Always announce** that line in your reply (e.g. `✓ Skagway 1.1.0 (1046) [Release]`). A build without reporting the build number is incomplete.
   - **Stage all changes**: Use `git add -A` (or equivalent) to include every tracked modification **and** every untracked file.
   - **Update `CHANGELOG.md`**: Add high-level bullet points describing the changes to the `## Unreleased` section. Do this on/around every commit so the changelog reflects work as it happens.
   - Commit the changes (including the changelog update) as part of the work.

2. **Versioning**
   - Single source of truth: `project.yml`
   - `CURRENT_PROJECT_VERSION` (build number) **must increase** on every deploy.
   - `MARKETING_VERSION` only changes for releases (patch/minor/major).

3. **Releases**
   - When the user says "release" (patch / minor / major), follow `.cursor/rules/release-workflow.mdc`.
   - The detailed steps, versioning rules, and script usage live in `.cursor/rules/build-deploy.mdc` (Release Commands section).
   - **Notarized DMG required**: After `build_and_install.sh`, run `bash scripts/package_dmg.sh --no-bump` so `dist/` gets a Developer ID–signed, notarized, stapled DMG (`Skagway-X.Y.Z-NNN.dmg` and `Skagway.dmg`). `dist/` is gitignored — do not commit the DMG.
   - **Before releasing**:
     - Stage **all** changes with `git add -A` (tracked modifications + untracked files).
     - Commit **all completed/ready work** together with the version bump and changelog consolidation. Releases must not leave completed work uncommitted.
   - **Consolidate the changelog**: Move all items from the `## Unreleased` section into a new top-level release entry (`## X.Y.Z (build NNN) - date`). Clear the Unreleased section afterward. The consolidated text must correlate with the release commit message.
  - Always create an annotated tag and push tags (`git push origin HEAD --tags`).
  - **After push — publish Sparkle (mandatory):** Upload `dist/Skagway.dmg` + `dist/Skagway.appcast.xml` to R2 (both together). Run `bash scripts/verify_sparkle_publish.sh dist/Skagway.appcast.xml` — must pass before announcing the release. See `docs/SPARKLE.md`.
  - **12k library gate (human, before announce):** Backup with **File → Save Copy…**, recreate from **New Library…** + **Add Folder…** / scan, log timings in `docs/release-perf-log.md`. Agents do not drive the GUI and must not skip this. See `docs/human-qa-script.md` (Before every release).

4. **Commit discipline**
   - For every commit: always stage **all** changes using `git add -A` (or equivalent). This includes modifications to tracked files **and** any untracked files that belong in the commit.
   - Never leave completed work sitting uncommitted when it should be part of the change set.

5. **Testing Changes**
   - For UI/behavior changes, you are expected to build + run the app (or guide the user to run it) rather than only describing changes.
   - **Do not drive the GUI yourself.** Launching/activating the app is fine, but do not attempt to simulate clicks, drags, keystrokes, or otherwise control the mouse/keyboard (`osascript`/System Events, `cliclick`, or similar) to click through the running app. The user does interactive testing themselves — hand off with clear repro steps ("right-click a card → Delete Video… → confirm the dialog appears") instead of trying to automate it.

## Key Architectural Principles

- **Performance first for large libraries** (thousands of videos):
  - `filteredVideos` is a **stored property** (not computed) and is updated in only one place via `applyFilteredVideos()`.
  - `applyFilteredVideos()` uses an equality guard and bumps `filteredVideosVersion` **only when row membership changes** (add/remove/rename), never on pure reorder.
  - Grid and list use `.id(viewModel.filteredVideosVersion)` to force SwiftUI to recreate the view tree instead of diffing.
  - Wrap sort-driven reorders in `withAnimation(nil)` to suppress implicit animations.
  - Prefer O(1) or batched work: `ScrollCommandHandler`, precompiled collection rules, single-pass library counts, debounced refreshes, batch JOINs for tags/rules.
  - Thumbnails: `NSCache` (memory) + disk in `ThumbnailService`; generation is coalesced per path and concurrency-capped.

- **State ownership**:
  - `LibraryViewModel` is the single source of truth for library state, filtering, selection, playback mode, and layout.
  - Most heavy work (filtering, collection matching, counts) should be moved off the main actor when possible.

- **Playback modes** (as of v0.13+):
  - Detail pane (freezes browser layout)
  - Overlay (floating panel, does not reshape browser)
  - Full screen (separate window)
  - `inlinePlaybackReshapesBrowser` is the key computed property.

- **Persistence**:
  - Layouts (browsing vs playback), sort, view mode, column customization, and many preferences live in `LayoutParams` + UserDefaults.
  - Be careful restoring the correct layout when exiting playback.
  - **Thumbnail / filmstrip disk cache is per library**: stored in the library DB (`library_cache`). Default co-locate is sibling `Skagway-cache` (system Caches for the standard App Support library). Hidden `.Skagway-cache` / legacy `thumbnails` are still recognized. Save Copy keeps the original cache pointer. Memory cache stays process-wide.

## Build & Environment Notes

- `SWIFT_VERSION: "5"` is pinned in `project.yml` for compatibility with the Swift 6.2.4 compiler.
- App sandboxing is disabled (see `Skagway.entitlements`).
- `eraseDatabaseOnSchemaChange` is deliberately **not** used in the GRDB migrator — it would wipe user data on schema changes. See the comment in `DatabaseMigration.swift`.

## Documentation & Planning

- **High-level direction and phases**: See `ROADMAP.md`
- **Detailed improvement / AI ideas**: See `AI-IMPROVEMENTS.md` (and relevant sections of `ROADMAP.md`)
- **Changelog**: `CHANGELOG.md`
  - Maintained live: agents add high-level change summaries to the `## Unreleased` section as work is committed.
  - Consolidated on release: Unreleased content is turned into a dated `## X.Y.Z (build NNN)` entry and the Unreleased section is cleared.
  - This is mandatory (see Core Workflow Rules and release process).
- **User-facing documentation**: The manual is **machii-labs** `/skagway/manual` ([live](https://machiilabs.com/skagway/manual)). `docs/USER_GUIDE.md` only points there. In-app UI, menus, Settings, and tooltips still matter for day-to-day use.
- **Technical history / performance notes**: `GRID-PERFORMANCE.md`
- **Release 12k perf log**: `docs/release-perf-log.md` (backup + recreate from scratch before every release)

When making significant changes, update the relevant document(s).

## Skills & Subagents

See `SKILLS.md` for the current set of recommended skills and when to invoke specialized subagents (e.g., for reviews, architecture, or complex refactors).

## Communication Style

- Be direct and precise.
- When proposing changes, briefly explain *why* (especially performance, architecture, or user experience impact).
- Always surface build/deploy status after code changes.
- If something is ambiguous, ask a clarifying question rather than guessing.

## Common Pitfalls to Avoid

- Do not assume `@Environment` will propagate through `Table` / split views on macOS.
- Do not mutate `filteredVideos` directly from many places — go through the proper recompute path.
- Do not forget to bump the build number before building.
- Do not skip updating the `## Unreleased` section of `CHANGELOG.md` after changes (this is required on the normal post-build flow).
- When working with scroll or layout during playback, respect `inlinePlaybackReshapesBrowser`.
- Grid cells and filmstrips are performance-sensitive — avoid unnecessary view invalidation.

---

This file should be the first thing an agent reads when starting work on Skagway.