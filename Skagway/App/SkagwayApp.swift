import AppKit
import SwiftUI

@main
struct SkagwayApp: App {
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    private static let settingsWindowID = "settings"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    DatabaseExportImport.checkpointAndCleanWAL()
                    DatabaseExportImport.clearSessionLocationPreferencesIfNeeded()
                }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    openWindow(id: Self.settingsWindowID)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                Button("Grid View") {
                    appState.libraryViewModel?.scrollToSelectedOnViewSwitch = true
                    appState.libraryViewModel?.viewMode = .grid
                    appState.libraryViewModel?.savePreferences()
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(!appState.hasLibrary)

                Button("List View") {
                    appState.libraryViewModel?.scrollToSelectedOnViewSwitch = true
                    appState.libraryViewModel?.viewMode = .list
                    appState.libraryViewModel?.savePreferences()
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(!appState.hasLibrary)

                Divider()

                Button("Scroll to Selection") {
                    appState.libraryViewModel?.scrollToSelected()
                }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(appState.libraryViewModel?.selectedVideoIds.isEmpty != false)

                Button("Surprise Me!") {
                    appState.libraryViewModel?.surpriseMePickRandom()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(appState.libraryViewModel?.filteredVideos.isEmpty ?? true)

                Button("Play All") {
                    appState.libraryViewModel?.playAllFromStart()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(appState.libraryViewModel?.filteredVideos.isEmpty ?? true)

                Toggle("Loop Play All", isOn: Binding(
                    get: { appState.libraryViewModel?.playAllLoops ?? false },
                    set: { appState.libraryViewModel?.playAllLoops = $0 }
                ))
                .disabled(!appState.hasLibrary)

                Button("Quick Filter") {
                    appState.libraryViewModel?.openFiltersDrawer(mode: .quick)
                }
                .keyboardShortcut("q", modifiers: [.command, .option])
                .disabled(!appState.hasLibrary)

                Button("Advanced Filter") {
                    appState.libraryViewModel?.openFiltersDrawer(mode: .advanced)
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!appState.hasLibrary)

                Button("Clear Filters") {
                    appState.libraryViewModel?.resetAllFilters()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!appState.hasLibrary
                    || !(appState.libraryViewModel?.hasActiveFilters ?? false))

                Button("Toggle Thumbnail / Filmstrip") {
                    appState.libraryViewModel?.showThumbnailInDetail.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!appState.hasLibrary)

                Divider()

                Button("Re-encode Queue…") {
                    NotificationCenter.default.post(name: .openConversionQueue, object: nil)
                }
                .disabled(!(appState.libraryViewModel?.hasConversionActivity ?? false))

                Button("Move Queue…") {
                    NotificationCenter.default.post(name: .openMoveQueue, object: nil)
                }
                .disabled(!(appState.libraryViewModel?.hasMoveActivity ?? false))

                Divider()

                Button("Compact") {
                    guard let vm = appState.libraryViewModel else { return }
                    if vm.isPlayerFullScreen { vm.isPlayerFullScreen = false }
                    vm.playerSizeIsCompact = true
                    vm.playerLastWasFullScreen = false
                    vm.playerFloatingPosition = nil   // compact always anchors top-right
                }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(appState.libraryViewModel?.isPlayingInline != true)

                Button("Windowed") {
                    guard let vm = appState.libraryViewModel else { return }
                    if vm.isPlayerFullScreen { vm.isPlayerFullScreen = false }
                    vm.playerSizeIsCompact = false
                    vm.playerLastWasFullScreen = false
                }
                .keyboardShortcut("w", modifiers: [.command, .control])
                .disabled(appState.libraryViewModel?.isPlayingInline != true)

                Button("Toggle Full Screen") {
                    appState.libraryViewModel?.isPlayerFullScreen.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(appState.libraryViewModel?.isPlayingInline != true)

                // Restart from Beginning is reachable via ⌥-Space while a video is playing
                // (see the Space key handler in ContentView); the menu item stays for discoverability.
                Button("Restart from Beginning") {
                    appState.libraryViewModel?.playback.restartFromBeginning()
                }
                .disabled(appState.libraryViewModel?.isPlayingInline != true)

                Button("Skip Back 15 Seconds") {
                    appState.libraryViewModel?.playback.skipBy(-InlinePlaybackController.skipSeconds)
                }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(appState.libraryViewModel?.isPlayingInline != true)

                Button("Skip Forward 15 Seconds") {
                    appState.libraryViewModel?.playback.skipBy(InlinePlaybackController.skipSeconds)
                }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(appState.libraryViewModel?.isPlayingInline != true)

                Menu("Playback Speed") {
                    ForEach(InlinePlaybackController.playbackRateChoices, id: \.self) { rate in
                        Button(InlinePlaybackController.formatPlaybackRate(rate)) {
                            appState.libraryViewModel?.playback.setPlaybackRate(rate)
                        }
                    }
                }
                .disabled(appState.libraryViewModel?.isPlayingInline != true)

                Button("Make Thumbnail from Current Frame") {
                    appState.libraryViewModel?.playback.makeThumbnailFromCurrentFrame()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(appState.libraryViewModel?.isPlayingInline != true)

                Button("Bookmark Current Position") {
                    appState.libraryViewModel?.playback.addBookmarkAtCurrentTime()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(appState.libraryViewModel?.isPlayingInline != true)
            }
            // Fully replaces .pasteboard rather than composing "default + custom" via `after:` --
            // that approach previously produced a real, structural duplicate (the default group's
            // own Select All, stacked with a custom one) because its exact default contents aren't
            // something we control or fully know ahead of time. Specifying every item here removes
            // that ambiguity entirely.
            //
            // Cut/Copy/Paste forward to the standard responder-chain actions (same behavior as the
            // system default) so they still work correctly wherever a text field is focused (rename,
            // notes, custom metadata fields, search) -- nothing in the app implements clipboard
            // operations on videos themselves, but these are real, working text-editing commands,
            // not dead weight.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    NSApp.sendAction(Selector(("cut:")), to: nil, from: nil)
                }
                .keyboardShortcut("x", modifiers: .command)

                Button("Copy") {
                    NSApp.sendAction(Selector(("copy:")), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Paste") {
                    NSApp.sendAction(Selector(("paste:")), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: .command)

                Divider()

                // Select All routes through the responder chain first — which is exactly what the
                // system's own Edit ▸ Select All is (a nil-targeted `selectAll:`): a focused text
                // field selects its own text (rename, notes, custom fields, search), List's table
                // selects all rows. Only when nothing in the chain claims the action does ⌘A mean
                // "select all videos." The decision MUST happen here at action time — gating via
                // `.disabled(...)` on the current first responder cannot work, because SwiftUI
                // only re-evaluates these commands when *observed* state changes, and AppKit
                // focus is not observable state, so such a check is permanently stale. (That
                // stale check is also why ⌘A kept stealing "select all text" from focused fields
                // no matter how the key monitor's deferral logic was adjusted.)
                Button("Select All") {
                    if !NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) {
                        appState.libraryViewModel?.selectAllVideos()
                    }
                }
                .keyboardShortcut("a", modifiers: .command)

                Button("Clear Collection") {
                    appState.libraryViewModel?.deselectAllVideos()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(appState.libraryViewModel?.selectedVideoIds.isEmpty != false)

                Button("Toggle in Selection") {
                    appState.libraryViewModel?.toggleFocusedInCollectedSet()
                }
                .disabled(appState.libraryViewModel?.focusedVideoId == nil
                    && appState.libraryViewModel?.selectedVideoIds.isEmpty != false)

                Divider()

                Button("Delete\u{2026}") {
                    guard let vm = appState.libraryViewModel,
                          !vm.selectedVideoIds.isEmpty
                    else { return }
                    if vm.confirmDeletions {
                        vm.pendingDeleteIds = vm.selectedVideoIds
                        vm.showDeleteConfirmation = true
                    } else {
                        let ids = vm.selectedVideoIds
                        Task { await vm.deleteVideos(ids) }
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(appState.libraryViewModel?.selectedVideoIds.isEmpty != false)

                Button("Remove from Library") {
                    guard let vm = appState.libraryViewModel,
                          !vm.selectedVideoIds.isEmpty
                    else { return }
                    let ids = vm.selectedVideoIds
                    Task { await vm.removeVideosFromLibrary(ids) }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(appState.libraryViewModel?.selectedVideoIds.isEmpty != false)
            }
            // Find/Spelling/Format/Print stay empty — Repair Links owns Undo when a remap is pending.
            Group {
                CommandGroup(replacing: .undoRedo) {
                    Button("Undo Repair Links") {
                        Task { await appState.libraryViewModel?.undoLocationRelink() }
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(appState.libraryViewModel?.locationRelinkUndo == nil
                        || (appState.libraryViewModel?.isApplyingLocationRelink ?? false))
                }
                CommandGroup(replacing: .textEditing) { }
                CommandGroup(replacing: .textFormatting) { }
                CommandGroup(replacing: .printItem) { }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Skagway") {
                    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    let year = Calendar.current.component(.year, from: Date())
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center
                    let credits = NSAttributedString(
                        string: "Free forever.\n\n© \(year) Mach II Labs\nmachiilabs.com",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .paragraphStyle: paragraph
                        ]
                    )
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Skagway",
                        .applicationVersion: short,
                        .version: "build \(build)",
                        .credits: credits
                    ])
                }
                Divider()
                Button("Check for Updates…") {
                    UpdateChecker.shared.checkForUpdates()
                }
                .disabled(!UpdateChecker.shared.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Folder\u{2026}") {
                    appState.libraryViewModel?.showFolderPicker()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!appState.hasLibrary)

                Button("Scan for New Videos") {
                    Task { await appState.libraryViewModel?.importNew() }
                }
                .disabled(!appState.hasLibrary || (appState.libraryViewModel?.isScanning ?? false))
                .help("Scan your library folders for newly added video files")

                Button("Scan for Subtitles") {
                    Task { await appState.libraryViewModel?.scanForSubtitles() }
                }
                .disabled(!appState.hasLibrary
                    || (appState.libraryViewModel?.isScanning ?? false)
                    || (appState.libraryViewModel?.videos.isEmpty ?? true))

                Divider()

                Button("Repair Links\u{2026}") {
                    appState.libraryViewModel?.beginLocationRelink()
                }
                .disabled(!appState.hasLibrary
                    || (appState.libraryViewModel?.videos.isEmpty ?? true)
                    || (appState.libraryViewModel?.isApplyingLocationRelink ?? false))
                .help("Repair catalog links after moving an entire library folder tree")
            }
            CommandGroup(replacing: .importExport) {
                Button("Play in External Player") {
                    guard let vm = appState.libraryViewModel,
                          let videoId = vm.focusedVideoId ?? vm.selectedVideoIds.first,
                          let video = vm.filteredVideo(forPath: videoId)
                    else { return }
                    NSWorkspace.shared.open(video.url)
                    Task { await vm.recordPlay(for: video) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(appState.libraryViewModel?.focusedVideoId == nil
                    && appState.libraryViewModel?.selectedVideoIds.first == nil)

                Button("Show in Finder") {
                    guard let vm = appState.libraryViewModel,
                          let videoId = vm.focusedVideoId ?? vm.selectedVideoIds.first,
                          let video = vm.filteredVideo(forPath: videoId)
                    else { return }
                    NSWorkspace.shared.selectFile(video.filePath, inFileViewerRootedAtPath: "")
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(appState.libraryViewModel?.focusedVideoId == nil
                    && appState.libraryViewModel?.selectedVideoIds.first == nil)

                if let vm = appState.libraryViewModel,
                   let videoId = vm.focusedVideoId ?? vm.selectedVideoIds.first,
                   let video = vm.filteredVideo(forPath: videoId)
                {
                    Menu("Open With") {
                        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: video.url)
                        ForEach(appURLs, id: \.self) { appURL in
                            Button(appURL.deletingPathExtension().lastPathComponent) {
                                NSWorkspace.shared.open(
                                    [video.url],
                                    withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()
                                )
                                Task { await vm.recordPlay(for: video) }
                            }
                        }
                    }
                }

                Divider()

                if DatabaseExportImport.promptsForLibraryEachLaunch {
                    Button("Open Library\u{2026}") {
                        DatabaseExportImport.openLibraryFromUserSelection()
                    }
                    .help("You chose to pick the library each launch — no location is remembered on this Mac.")
                } else if !DatabaseExportImport.homeLibraryExists {
                    Button("Create Home Library") {
                        DatabaseExportImport.createHomeLibraryIfNeeded()
                    }
                    .disabled(appState.hasLibrary)
                    .help("Creates \(DatabaseExportImport.homeLibraryPathForDisplay)")
                } else {
                    Button("Open Home Library") {
                        DatabaseExportImport.openHomeLibrary()
                        appState.noteRecentLibrariesChanged()
                    }
                    .help(DatabaseExportImport.homeLibraryPathForDisplay)
                }
                Button("New Library\u{2026}") {
                    DatabaseExportImport.createNewLibrary()
                }
                Button("Open Library\u{2026}") {
                    DatabaseExportImport.openLibraryFromUserSelection()
                }
                Menu("Open Recent") {
                    ForEach(appState.recentLibraryItems()) { item in
                        Button(item.displayName) {
                            DatabaseExportImport.switchToLibrary(item)
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        appState.clearRecentLibraries()
                    }
                    .disabled(appState.recentLibraryItems().isEmpty)
                }
                .disabled(appState.recentLibraryItems().isEmpty)
                Divider()
                Button("Save Copy\u{2026}") {
                    if let pool = appState.dbManager?.dbPool {
                        DatabaseExportImport.saveCopy(dbPool: pool)
                    }
                }
                .disabled(!appState.hasLibrary)
                Button("Export Metadata\u{2026}") {
                    appState.libraryViewModel?.presentExportMetadata(scope: .filtered)
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!(appState.hasLibrary)
                    || (appState.libraryViewModel?.filteredVideos.isEmpty ?? true))
                .help("Export metadata for the current filtered video set")
                Button("Bulk Rename\u{2026}") {
                    appState.libraryViewModel?.presentBulkRename(scope: .filtered)
                }
                .disabled(!(appState.hasLibrary)
                    || (appState.libraryViewModel?.filteredVideos.isEmpty ?? true))
                .help("Rename filtered videos on disk using a name pattern")
                Button("Import Metadata\u{2026}") {
                    ApplyMetadataFilePicker.present(
                        onPicked: { url, data in
                            appState.libraryViewModel?.presentApplyMetadata(from: url, data: data)
                        },
                        onReadError: { message in
                            appState.libraryViewModel?.presentApplyMetadataReadError(message)
                        }
                    )
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(!appState.hasLibrary)
                .help("Import metadata from a CSV or JSON Lines file (updates matched videos)")
                Divider()
                Button("Change Library Location\u{2026}") {
                    DatabaseExportImport.changeLibraryAndCacheLocation()
                }
                .help("Quit and choose again where the library lives. Each library keeps its own thumbnail cache. Files on disk are not deleted.")
                Button("Change Thumbnail Cache Location\u{2026}") {
                    if let pool = appState.dbManager?.dbPool {
                        DatabaseExportImport.changeThumbnailCacheLocation(
                            dbPool: pool,
                            thumbnailService: appState.thumbnailService
                        )
                    }
                }
                .disabled(!appState.hasLibrary)
                .help("Choose where the open library’s thumbnails are stored. Other libraries are unaffected.")
                Button("Close Library\u{2026}") {
                    DatabaseExportImport.closeLibrary()
                }
                .disabled(!appState.hasLibrary)
                Button("Delete This Library\u{2026}") {
                    guard let url = DatabaseExportImport.activeLibraryURL() else { return }
                    let alert = NSAlert()
                    alert.messageText = "Delete This Library?"
                    alert.informativeText = "This will permanently delete the library file from disk. This action cannot be undone."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        DatabaseExportImport.deleteThisLibrary(at: url)
                    }
                }
                .disabled(!appState.hasLibrary)
            }

            CommandGroup(replacing: .help) {
                Button("Skagway Help") {
                    if let url = URL(string: "https://machiilabs.com/skagway/manual") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Contact Support…") {
                    if let url = URL(string: "mailto:support@machiilabs.com?subject=Skagway%20support%20request") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        // Custom Settings window (not the system `Settings` scene) so chrome is fully ours.
        Window("Settings", id: Self.settingsWindowID) {
            SettingsView(appState: appState)
        }
        .defaultSize(width: 780, height: 560)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
