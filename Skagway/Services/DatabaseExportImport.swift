import AppKit
import Foundation
import GRDB

struct RecentLibraryItem: Identifiable {
    let id: String
    let displayName: String
    let url: URL
}

enum DatabaseExportImport {
    private static let activeLibraryBookmarkKey = PrefsKeys.activeLibraryBookmark
    private static let activeLibraryPathKey = PrefsKeys.activeLibraryPath
    private static let recentLibraryBookmarksKey = PrefsKeys.recentLibraryBookmarks
    private static let recentLibraryPathsKey = PrefsKeys.recentLibraryPaths
    private static let userClosedLibraryKey = PrefsKeys.userClosedLibrary
    private static let maxRecentLibraries = 10

    /// On-disk library extension (Mach II Labs).
    static let libraryFilenameExtension = "machii"
    private static let appSupportFolderName = "Skagway"
    private static let defaultLibraryFileName = "Skagway.machii"

    /// Stored reference to the active dbPool, set by AppState on init.
    nonisolated(unsafe) static var activeDbPool: DatabasePool?

    /// Flushes the current library's WAL into the main file, closes every connection, then removes
    /// the emptied `-wal` / `-shm`. Call before quitting, switching, closing, or deleting.
    /// The files must not be deleted while the pool is open: that is an SQLite API violation
    /// ("vnode unlinked while in use") that can corrupt the library.
    static func checkpointAndCloseLibrary() {
        guard let pool = activeDbPool else { return }
        let path = pool.path
        do {
            try pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
            try pool.close()
            activeDbPool = nil
        } catch {
            // Something still holds a connection. Leave WAL/SHM; SQLite replays them on next open.
            return
        }
        let fm = FileManager.default
        let walSize = (try? fm.attributesOfItem(atPath: path + "-wal")[.size] as? NSNumber)?.intValue ?? 0
        guard walSize == 0 else { return }
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
    }

    private static var applicationSupportRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    static var dbDirectoryURL: URL {
        applicationSupportRootURL.appendingPathComponent(appSupportFolderName, isDirectory: true)
    }

    /// App Support library file. Only used when the user chose **Standard** at setup.
    static var defaultLibraryURL: URL {
        dbDirectoryURL.appendingPathComponent(defaultLibraryFileName, isDirectory: false)
    }

    /// How Skagway finds the library home after setup.
    enum LibraryHomeAccessMode: String {
        /// Application Support + system Caches; open automatically.
        case standard
        /// Custom folder; opaque bookmark kept on this Mac so the library can open when the volume is available.
        case rememberBookmark
        /// Custom folder; no location stored on the boot disk — user opens the library each launch.
        case askEachLaunch
    }

    static var libraryHomeAccessMode: LibraryHomeAccessMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: PrefsKeys.libraryHomeAccessMode),
               let mode = LibraryHomeAccessMode(rawValue: raw) {
                return mode
            }
            // Pre-access-mode installs: custom library bookmark ⇒ remembered; else standard.
            if hasCompletedLibraryHomeSetup {
                let hasCustomLibrary =
                    UserDefaults.standard.data(forKey: PrefsKeys.activeLibraryBookmark) != nil
                    || UserDefaults.standard.string(forKey: PrefsKeys.activeLibraryPath) != nil
                    || UserDefaults.standard.string(forKey: PrefsKeys.thumbnailCachePath) != nil
                    || UserDefaults.standard.data(forKey: PrefsKeys.thumbnailCacheBookmark) != nil
                return hasCustomLibrary ? .rememberBookmark : .standard
            }
            return .standard
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: PrefsKeys.libraryHomeAccessMode)
        }
    }

    /// Whether setup chose a custom folder (not Application Support).
    /// When true, there is no Application Support “default” library — only the chosen home.
    static var usesCustomLibraryHome: Bool {
        switch libraryHomeAccessMode {
        case .standard: return false
        case .rememberBookmark, .askEachLaunch: return true
        }
    }

    /// User must pick the library each launch (no remembered location on the boot disk).
    static var promptsForLibraryEachLaunch: Bool {
        libraryHomeAccessMode == .askEachLaunch
    }

    /// Remember-custom-home: only opaque bookmarks in prefs — never plain library/cache paths.
    static var storesLocationAsBookmarkOnly: Bool {
        libraryHomeAccessMode == .rememberBookmark
    }

    /// Folder that owns the startup library (custom home folder, or App Support for Standard).
    static var homeLibraryFolderURL: URL {
        if storesLocationAsBookmarkOnly {
            if let bookmark = UserDefaults.standard.data(forKey: activeLibraryBookmarkKey),
               let url = resolveLibraryBookmark(bookmark) {
                return url.deletingLastPathComponent()
            }
            // Legacy: home folder was inferred from the old app-wide cache bookmark.
            if let bookmark = UserDefaults.standard.data(forKey: PrefsKeys.thumbnailCacheBookmark),
               let url = resolveLibraryBookmark(bookmark) {
                return url.deletingLastPathComponent()
            }
            return dbDirectoryURL
        }
        if let path = UserDefaults.standard.string(forKey: activeLibraryPathKey),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        if let path = UserDefaults.standard.string(forKey: PrefsKeys.thumbnailCachePath) {
            return URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent()
        }
        return dbDirectoryURL
    }

    /// Where a library’s thumbnail cache should live when first bound.
    enum LibraryCachePlacement: Equatable {
        /// Sibling `Skagway-cache` next to the `.machii` (default for custom homes).
        case coLocated
        /// `~/Library/Caches/Skagway/…` — shared folder for Standard home; per-library subfolder otherwise.
        case systemDefault
        /// User-chosen folder.
        case custom(URL)
    }

    /// Library file for the startup home (chosen folder, or App Support only if Standard was chosen).
    static var homeLibraryURL: URL {
        if let existing = findLibraryFile(in: homeLibraryFolderURL) {
            return existing
        }
        return homeLibraryFolderURL.appendingPathComponent(defaultLibraryFileName, isDirectory: false)
    }

    static var homeLibraryExists: Bool {
        FileManager.default.fileExists(atPath: homeLibraryURL.path)
    }

    /// Whether the library that would open on launch is the startup home library.
    static var isHomeLibraryActive: Bool {
        guard let path = databasePathForLaunch() else { return false }
        return (path as NSString).standardizingPath
            == (homeLibraryURL.path as NSString).standardizingPath
    }

    /// Short path shown in help / alerts (tilde-abbreviated when under the home directory).
    static func pathForDisplay(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    static var defaultLibraryPathForDisplay: String {
        pathForDisplay(defaultLibraryURL)
    }

    static var homeLibraryPathForDisplay: String {
        pathForDisplay(homeLibraryURL)
    }

    /// Whether the user explicitly closed the library. Checked once at launch, then cleared.
    static var userClosedLibrary: Bool {
        UserDefaults.standard.bool(forKey: userClosedLibraryKey)
    }

    static func clearUserClosedLibrary() {
        UserDefaults.standard.removeObject(forKey: userClosedLibraryKey)
    }

    /// Path to open for database. Standard / askEachLaunch may use plain paths; rememberBookmark is bookmark-only.
    /// Nil = no library. Does **not** erase prefs when a bookmark fails to resolve after a rebuild —
    /// that used to wipe the active library and prune recents.
    static func databasePathForLaunch() -> String? {
        if storesLocationAsBookmarkOnly {
            scrubPlainLocationPathsFromPrefs()
            if let bookmark = UserDefaults.standard.data(forKey: activeLibraryBookmarkKey),
               let url = resolveLibraryBookmark(bookmark),
               FileManager.default.fileExists(atPath: url.path) {
                refreshBookmarkIfNeeded(for: url, isActive: true)
                return (url.path as NSString).standardizingPath
            }
            return nil
        }

        if let path = UserDefaults.standard.string(forKey: activeLibraryPathKey),
           FileManager.default.fileExists(atPath: path) {
            refreshBookmarkIfNeeded(forPath: path, isActive: true)
            return path
        }

        if let bookmark = UserDefaults.standard.data(forKey: activeLibraryBookmarkKey),
           let url = resolveLibraryBookmark(bookmark),
           FileManager.default.fileExists(atPath: url.path) {
            // Persist path for Standard / in-session askEachLaunch so the next launch survives
            // bookmark resolution failures.
            let path = (url.path as NSString).standardizingPath
            UserDefaults.standard.set(path, forKey: activeLibraryPathKey)
            return path
        }

        // No active library: use startup home only. App Support exists solely when Standard was chosen
        // (`usesCustomLibraryHome` == false). Never fall back to App Support after Choose Folder.
        if usesCustomLibraryHome {
            return homeLibraryExists ? homeLibraryURL.path : nil
        }
        if FileManager.default.fileExists(atPath: defaultLibraryURL.path) {
            return defaultLibraryURL.path
        }
        return nil
    }

    /// After home setup: open the existing home library, or create it if missing.
    /// Returns nil for Ask-each-launch (File menu), when the user just closed the library,
    /// or when a Remember-mode volume is offline (bookmarks don’t resolve).
    static func resolveOrCreateLibraryForLaunch(userClosedThisSession: Bool) -> String? {
        if userClosedThisSession { return nil }
        if let path = databasePathForLaunch() { return path }
        if promptsForLibraryEachLaunch { return nil }
        if storesLocationAsBookmarkOnly && !isRememberHomeVolumeReachable {
            return nil
        }
        return createHomeLibrarySilentlyIfNeeded()
    }

    /// True when Remember-mode bookmarks resolve to a reachable folder (volume online).
    private static var isRememberHomeVolumeReachable: Bool {
        guard storesLocationAsBookmarkOnly else { return true }
        if let bookmark = UserDefaults.standard.data(forKey: PrefsKeys.thumbnailCacheBookmark),
           resolveLibraryBookmark(bookmark) != nil {
            return true
        }
        if let bookmark = UserDefaults.standard.data(forKey: activeLibraryBookmarkKey),
           resolveLibraryBookmark(bookmark) != nil {
            return true
        }
        // No bookmarks yet (edge) — allow App Support / folder create only if we aren't
        // pretending a custom home is mounted.
        let hasAnyBookmark =
            UserDefaults.standard.data(forKey: PrefsKeys.thumbnailCacheBookmark) != nil
            || UserDefaults.standard.data(forKey: activeLibraryBookmarkKey) != nil
        return !hasAnyBookmark
    }

    /// Creates `homeLibraryURL` when missing, activates it, and returns its path. Never overwrites.
    private static func createHomeLibrarySilentlyIfNeeded() -> String? {
        let fm = FileManager.default
        let destURL = homeLibraryURL
        try? fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: destURL.path) {
            do {
                try DatabaseMigration.createEmptyDatabase(at: destURL.path)
            } catch {
                return nil
            }
        }
        seedLibraryCacheIfNeeded(at: destURL, preferredPlacement: defaultPlacement(for: destURL))
        setActiveLibraryPreferences(url: destURL)
        addToRecent(url: destURL)
        return (destURL.path as NSString).standardizingPath
    }

    /// Display name of the active library for window title (extension stripped). Empty when no library.
    static var activeLibraryDisplayName: String {
        if let path = databasePathForLaunch() {
            return displayName(for: URL(fileURLWithPath: path))
        }
        return ""
    }

    /// Returns display name for a library URL.
    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        for ext in [".machii", ".sqlite", ".db", ".sqlite3"] {
            if name.lowercased().hasSuffix(ext) {
                return String(name.dropLast(ext.count))
            }
        }
        return name
    }

    /// URL of the active library (for Save Copy, etc.). Nil when no library.
    static func activeLibraryURL() -> URL? {
        guard let path = databasePathForLaunch() else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func defaultExportFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Skagway-\(formatter.string(from: Date())).\(libraryFilenameExtension)"
    }

    /// Validates that the file is a valid Skagway library database (has video table).
    static func validateImportFile(at url: URL) throws {
        let db = try DatabaseQueue(path: url.path)
        _ = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM video") }
    }

    // MARK: - Bookmark / path helpers

    /// Resolve a saved bookmark. Tries plain resolution first (app is not sandboxed), then security-scope
    /// for older bookmarks created with `.withSecurityScope`.
    private static func resolveLibraryBookmark(_ data: Data) -> URL? {
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url
        }
        isStale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url
        }
        return nil
    }

    private static func makeLibraryBookmark(for url: URL) -> Data? {
        // Non-sandboxed app: plain bookmarks survive rebuilds far more reliably than security-scoped ones.
        if let data = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return data
        }
        return try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func setActiveLibraryPreferences(url: URL) {
        if let bookmark = makeLibraryBookmark(for: url) {
            UserDefaults.standard.set(bookmark, forKey: activeLibraryBookmarkKey)
        }
        if storesLocationAsBookmarkOnly {
            UserDefaults.standard.removeObject(forKey: activeLibraryPathKey)
        } else {
            let path = (url.path as NSString).standardizingPath
            UserDefaults.standard.set(path, forKey: activeLibraryPathKey)
        }
    }

    private static func clearActiveLibraryPreferences() {
        UserDefaults.standard.removeObject(forKey: activeLibraryBookmarkKey)
        UserDefaults.standard.removeObject(forKey: activeLibraryPathKey)
    }

    private static func refreshBookmarkIfNeeded(forPath path: String, isActive: Bool) {
        refreshBookmarkIfNeeded(for: URL(fileURLWithPath: path), isActive: isActive)
    }

    private static func refreshBookmarkIfNeeded(for url: URL, isActive: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let bookmark = makeLibraryBookmark(for: url) else { return }
        if isActive {
            UserDefaults.standard.set(bookmark, forKey: activeLibraryBookmarkKey)
        }
    }

    /// Drops plain library/cache/recent paths when Remember mode must stay bookmark-only.
    static func scrubPlainLocationPathsFromPrefs() {
        guard storesLocationAsBookmarkOnly else { return }
        UserDefaults.standard.removeObject(forKey: activeLibraryPathKey)
        UserDefaults.standard.removeObject(forKey: PrefsKeys.thumbnailCachePath)
        UserDefaults.standard.removeObject(forKey: recentLibraryPathsKey)
    }

    // MARK: - Recent Libraries

    /// Returns recent libraries for Open Recent / landing.
    /// Standard / ask-each-launch: path list is authoritative (bookmarks kept in sync).
    /// Remember (bookmark-only): bookmarks only — never a plain path list on the boot disk.
    /// Only drops entries whose files are actually gone — never solely because a bookmark failed to resolve.
    static func recentLibraryItems() -> [RecentLibraryItem] {
        if storesLocationAsBookmarkOnly {
            scrubPlainLocationPathsFromPrefs()
            return recentLibraryItemsFromBookmarks()
        }

        migrateRecentBookmarksIntoPathsIfNeeded()

        var paths = UserDefaults.standard.stringArray(forKey: recentLibraryPathsKey) ?? []
        var result: [RecentLibraryItem] = []
        var keptPaths: [String] = []

        for path in paths {
            let standardized = (path as NSString).standardizingPath
            guard FileManager.default.fileExists(atPath: standardized) else { continue }
            if keptPaths.contains(standardized) { continue }
            keptPaths.append(standardized)
            let url = URL(fileURLWithPath: standardized)
            result.append(RecentLibraryItem(
                id: standardized,
                displayName: displayName(for: url),
                url: url
            ))
        }

        if keptPaths != paths {
            UserDefaults.standard.set(keptPaths, forKey: recentLibraryPathsKey)
        }

        // Keep bookmark blobs in sync when we can (non-fatal if creation fails).
        var bookmarks: [Data] = []
        for path in keptPaths.prefix(maxRecentLibraries) {
            if let data = makeLibraryBookmark(for: URL(fileURLWithPath: path)) {
                bookmarks.append(data)
            }
        }
        UserDefaults.standard.set(bookmarks, forKey: recentLibraryBookmarksKey)

        return result
    }

    /// Resolve Open Recent from opaque bookmarks only (Remember mode).
    private static func recentLibraryItemsFromBookmarks() -> [RecentLibraryItem] {
        let bookmarks = UserDefaults.standard.array(forKey: recentLibraryBookmarksKey) as? [Data] ?? []
        var result: [RecentLibraryItem] = []
        var kept: [Data] = []
        var seenPaths = Set<String>()

        for data in bookmarks {
            guard let url = resolveLibraryBookmark(data) else {
                // Volume offline / resolve failed — keep the blob so history survives.
                kept.append(data)
                continue
            }
            let path = (url.path as NSString).standardizingPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if seenPaths.contains(path) { continue }
            seenPaths.insert(path)
            if let refreshed = makeLibraryBookmark(for: url) {
                kept.append(refreshed)
            } else {
                kept.append(data)
            }
            result.append(RecentLibraryItem(
                id: path,
                displayName: displayName(for: url),
                url: url
            ))
            if result.count >= maxRecentLibraries { break }
        }

        if kept != bookmarks {
            UserDefaults.standard.set(Array(kept.prefix(maxRecentLibraries)), forKey: recentLibraryBookmarksKey)
        }
        return result
    }

    /// One-shot: pull paths out of legacy bookmark-only recents so rebuilds don’t erase history.
    private static func migrateRecentBookmarksIntoPathsIfNeeded() {
        if storesLocationAsBookmarkOnly { return }

        var paths = UserDefaults.standard.stringArray(forKey: recentLibraryPathsKey) ?? []
        let bookmarks = UserDefaults.standard.array(forKey: recentLibraryBookmarksKey) as? [Data] ?? []

        var changed = false
        for data in bookmarks {
            guard let url = resolveLibraryBookmark(data) else { continue }
            let path = (url.path as NSString).standardizingPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if !paths.contains(path) {
                paths.append(path)
                changed = true
            }
        }
        if changed {
            UserDefaults.standard.set(Array(paths.prefix(maxRecentLibraries)), forKey: recentLibraryPathsKey)
        }

        // Also migrate active bookmark → path once (even when recents are empty).
        if UserDefaults.standard.string(forKey: activeLibraryPathKey) == nil,
           let bookmark = UserDefaults.standard.data(forKey: activeLibraryBookmarkKey),
           let url = resolveLibraryBookmark(bookmark),
           FileManager.default.fileExists(atPath: url.path) {
            UserDefaults.standard.set((url.path as NSString).standardizingPath, forKey: activeLibraryPathKey)
        }
    }

    /// Adds a library URL to the recent list. Dedupes by path, trims to max.
    /// Remember mode updates bookmarks only (no plain path list).
    static func addToRecent(url: URL) {
        let path = (url.path as NSString).standardizingPath

        if storesLocationAsBookmarkOnly {
            UserDefaults.standard.removeObject(forKey: recentLibraryPathsKey)
        } else {
            var paths = UserDefaults.standard.stringArray(forKey: recentLibraryPathsKey) ?? []
            paths.removeAll { ($0 as NSString).standardizingPath == path }
            paths.insert(path, at: 0)
            paths = Array(paths.prefix(maxRecentLibraries))
            UserDefaults.standard.set(paths, forKey: recentLibraryPathsKey)
        }

        if let bookmark = makeLibraryBookmark(for: url) {
            var kept: [Data] = []
            for data in UserDefaults.standard.array(forKey: recentLibraryBookmarksKey) as? [Data] ?? [] {
                guard let u = resolveLibraryBookmark(data),
                      (u.path as NSString).standardizingPath != path else { continue }
                kept.append(data)
            }
            kept.insert(bookmark, at: 0)
            UserDefaults.standard.set(Array(kept.prefix(maxRecentLibraries)), forKey: recentLibraryBookmarksKey)
        }
    }

    /// Switches to a library and restarts.
    static func switchToLibrary(_ item: RecentLibraryItem) {
        checkpointAndCloseLibrary()
        let didStartAccess = item.url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { item.url.stopAccessingSecurityScopedResource() } }
        seedLibraryCacheIfNeeded(at: item.url, preferredPlacement: nil)
        setActiveLibraryPreferences(url: item.url)
        addToRecent(url: item.url)
        clearUserClosedLibrary()
        relaunchAfterTerminate()
        NSApplication.shared.terminate(nil)
    }

    /// Clears all recent library bookmarks.
    static func clearRecentLibraries() {
        UserDefaults.standard.removeObject(forKey: recentLibraryBookmarksKey)
        UserDefaults.standard.removeObject(forKey: recentLibraryPathsKey)
    }

    /// Schedules the app to relaunch after this process terminates. Uses launchctl so the relaunch survives our exit.
    private static func relaunchAfterTerminate() {
        let appPath = Bundle.main.bundlePath
        let script = """
        #!/bin/bash
        sleep 2
        open "\(appPath)"
        launchctl remove com.machiilabs.skagway.relaunch 2>/dev/null || true
        """
        let scriptURL = dbDirectoryURL.appendingPathComponent("relaunch.sh", isDirectory: false)
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? (scriptURL as NSURL).setResourceValue(true, forKey: .isExecutableKey)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = [
                "submit", "-l", "com.machiilabs.skagway.relaunch",
                "-o", dbDirectoryURL.appendingPathComponent("relaunch_out.log").path,
                "-e", dbDirectoryURL.appendingPathComponent("relaunch_err.log").path,
                "--", "/bin/bash", scriptURL.path
            ]
            try task.run()
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
        }
    }

    // MARK: - Save Copy

    /// Saves a copy of the current library to a user-chosen path. Does not switch.
    static func saveCopy(dbPool: DatabasePool) {
        guard let sourceURL = activeLibraryURL() else { return }
        let panel = NSSavePanel()
        panel.allowedFileTypes = [libraryFilenameExtension]
        panel.nameFieldStringValue = defaultExportFileName()
        panel.title = "Save Copy"
        panel.message = "Saves one complete Skagway library file (.machii extension). Companion -wal / -shm files are temporary while Skagway is open and do not need to be copied."
        panel.showsTagField = false

        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        do {
            try dbPool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
            let fm = FileManager.default
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            // Drop stale sidecars next to an overwritten destination if any exist.
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: destURL.path + suffix)
                if fm.fileExists(atPath: side.path) {
                    try? fm.removeItem(at: side)
                }
            }
            try fm.copyItem(at: sourceURL, to: destURL)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Open Library

    /// Shows open panel and switches to the selected library.
    static func openLibraryFromUserSelection() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = [libraryFilenameExtension]
        panel.allowsOtherFileTypes = false
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Library"
        panel.message = "Select a library file to open."

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            try validateImportFile(at: sourceURL)
        } catch {
            NSAlert(error: error).runModal()
            return
        }

        seedLibraryCacheIfNeeded(at: sourceURL, preferredPlacement: nil)
        let item = RecentLibraryItem(
            id: sourceURL.path,
            displayName: sourceURL.lastPathComponent,
            url: sourceURL
        )
        switchToLibrary(item)
    }

    // MARK: - Create Library

    /// Creates the startup-home library if missing. Never overwrites an existing file.
    /// Standard home → App Support; custom home → chosen folder only (no App Support library).
    static func createHomeLibraryIfNeeded() {
        let fm = FileManager.default
        let destURL = homeLibraryURL
        try? fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: destURL.path) else {
            let alert = NSAlert()
            alert.messageText = "Library Already Exists"
            alert.informativeText = "A library already exists at \(homeLibraryPathForDisplay). Use Open Home Library to open it, or choose a different location with New Library…"
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        do {
            try DatabaseMigration.createEmptyDatabase(at: destURL.path)
            seedLibraryCacheIfNeeded(at: destURL, preferredPlacement: defaultPlacement(for: destURL))
            clearUserClosedLibrary()
            setActiveLibraryPreferences(url: destURL)
            addToRecent(url: destURL)
            relaunchAfterTerminate()
            NSApplication.shared.terminate(nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Switches to the startup-home library and relaunches.
    /// Always records the home library in Open Recent (including when it is already open).
    static func openHomeLibrary() {
        if promptsForLibraryEachLaunch {
            openLibraryFromUserSelection()
            return
        }
        guard homeLibraryExists else {
            let alert = NSAlert()
            alert.messageText = "Home Library Not Found"
            alert.informativeText = "No library exists at \(homeLibraryPathForDisplay). Use Create Home Library to create one, or Change Library & Cache Location…"
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        addToRecent(url: homeLibraryURL)
        if isHomeLibraryActive {
            return
        }
        checkpointAndCloseLibrary()
        seedLibraryCacheIfNeeded(at: homeLibraryURL, preferredPlacement: nil)
        setActiveLibraryPreferences(url: homeLibraryURL)
        clearUserClosedLibrary()
        relaunchAfterTerminate()
        NSApplication.shared.terminate(nil)
    }

    /// Creates a new empty library at user-chosen path and switches to it.
    static func createNewLibrary() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = [libraryFilenameExtension]
        panel.nameFieldStringValue = "New Library.\(libraryFilenameExtension)"
        panel.title = "New Library"
        panel.message = "Choose a location for the new library. Its thumbnail cache defaults to a Skagway-cache folder beside the file."
        panel.showsTagField = false

        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        let didStartAccess = destURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { destURL.stopAccessingSecurityScopedResource() } }

        do {
            try DatabaseMigration.createEmptyDatabase(at: destURL.path)
            seedLibraryCacheIfNeeded(at: destURL, preferredPlacement: .coLocated)
            let item = RecentLibraryItem(
                id: destURL.path,
                displayName: destURL.lastPathComponent,
                url: destURL
            )
            switchToLibrary(item)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Close / Delete

    /// Closes the current library and relaunches with no library open.
    /// Standard / Remember auto-open home again on the *next* cold launch; this session stays empty
    /// so File → Open / New / Recent can switch libraries. Ask-each-launch always starts empty.
    static func closeLibrary() {
        checkpointAndCloseLibrary()
        clearActiveLibraryPreferences()
        UserDefaults.standard.set(true, forKey: userClosedLibraryKey)
        UserDefaults.standard.synchronize()
        relaunchAfterTerminate()
        NSApplication.shared.terminate(nil)
    }

    /// Deletes the library file from disk, removes from recent, and relaunches. Requires confirmation.
    static func deleteThisLibrary(at url: URL) {
        if let active = activeLibraryURL(),
           (active.path as NSString).standardizingPath == (url.path as NSString).standardizingPath
        {
            checkpointAndCloseLibrary()
        }
        let fm = FileManager.default
        for ext in ["", "-wal", "-shm"] {
            let path = url.path + ext
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
        removeFromRecent(url: url)
        let standardized = (url.path as NSString).standardizingPath
        if let active = UserDefaults.standard.string(forKey: activeLibraryPathKey),
           (active as NSString).standardizingPath == standardized {
            clearActiveLibraryPreferences()
        } else if databasePathForLaunch() == url.path {
            clearActiveLibraryPreferences()
        }
        relaunchAfterTerminate()
        NSApplication.shared.terminate(nil)
    }

    /// Removes a library URL from the recent list.
    static func removeFromRecent(url: URL) {
        let path = (url.path as NSString).standardizingPath
        var paths = UserDefaults.standard.stringArray(forKey: recentLibraryPathsKey) ?? []
        paths.removeAll { ($0 as NSString).standardizingPath == path }
        UserDefaults.standard.set(paths, forKey: recentLibraryPathsKey)

        var kept: [Data] = []
        for data in UserDefaults.standard.array(forKey: recentLibraryBookmarksKey) as? [Data] ?? [] {
            guard let u = resolveLibraryBookmark(data),
                  (u.path as NSString).standardizingPath != path else { continue }
            kept.append(data)
        }
        UserDefaults.standard.set(kept, forKey: recentLibraryBookmarksKey)
    }

    // MARK: - Library home setup (privacy / location)

    /// Whether the one-time library-home chooser has been completed.
    static var hasCompletedLibraryHomeSetup: Bool {
        UserDefaults.standard.bool(forKey: PrefsKeys.didCompleteLibraryHomeSetup)
    }

    static func markLibraryHomeSetupComplete() {
        UserDefaults.standard.set(true, forKey: PrefsKeys.didCompleteLibraryHomeSetup)
    }

    /// Standard home: App Support library + system Caches (bound into that library’s `library_cache`).
    static func useStandardLibraryHome() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dbDirectoryURL, withIntermediateDirectories: true)
        clearThumbnailCachePreferences()
        clearUserClosedLibrary()

        if !fm.fileExists(atPath: defaultLibraryURL.path) {
            do {
                try DatabaseMigration.createEmptyDatabase(at: defaultLibraryURL.path)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
        }

        seedLibraryCacheIfNeeded(at: defaultLibraryURL, preferredPlacement: .systemDefault)
        clearActiveLibraryPreferences()
        addToRecent(url: defaultLibraryURL)
        libraryHomeAccessMode = .standard
        markLibraryHomeSetupComplete()
        relaunchAfterTerminate()
        NSApplication.shared.terminate(nil)
    }

    /// Quits and shows the library-home chooser again. Does not delete files on disk.
    static func changeLibraryAndCacheLocation() {
        let alert = NSAlert()
        alert.messageText = "Change Library Location?"
        alert.informativeText = """
        Skagway will quit and ask again where to store the library, and (for a chosen folder) where that library’s thumbnail cache should live and whether to remember the location.

        Your library files and thumbnails on disk are not deleted. Each library keeps its own cache location.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        checkpointAndCloseLibrary()
        UserDefaults.standard.set(false, forKey: PrefsKeys.didCompleteLibraryHomeSetup)
        UserDefaults.standard.removeObject(forKey: PrefsKeys.libraryHomeAccessMode)
        UserDefaults.standard.synchronize()
        relaunchAfterTerminate()
        NSApplication.shared.terminate(nil)
    }

    /// Folder picker only — caller shows cache placement, then remember vs ask-each-launch.
    static func pickCustomLibraryHomeFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Choose Library Location"
        panel.message = "Choose a folder for the library database. Next you will choose where this library’s thumbnail cache lives. If a library is already there, Skagway will use it; otherwise it creates a new empty library."

        guard panel.runModal() == .OK, let folderURL = panel.url else { return nil }

        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { folderURL.stopAccessingSecurityScopedResource() } }
        return folderURL
    }

    /// Custom home folder: `Skagway.machii` (or any existing `*.machii`) + chosen cache placement.
    /// Existing library / `library_cache` row are reused — never overwritten.
    static func activateCustomLibraryHome(
        _ folderURL: URL,
        accessMode: LibraryHomeAccessMode,
        cachePlacement: LibraryCachePlacement = .coLocated
    ) throws {
        precondition(accessMode == .rememberBookmark || accessMode == .askEachLaunch)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw LibraryHomeSetupError.notAFolder
        }

        let libraryURL: URL
        if let existing = findLibraryFile(in: folderURL) {
            try validateImportFile(at: existing)
            libraryURL = existing
        } else {
            libraryURL = folderURL.appendingPathComponent(defaultLibraryFileName, isDirectory: false)
            try DatabaseMigration.createEmptyDatabase(at: libraryURL.path)
        }

        let pool = try DatabasePool(path: libraryURL.path)
        try DatabaseMigration.migrate(pool)
        let hasStored = try pool.read { db in try LibraryCacheStore.hasStoredLocation(db: db) }
        _ = try ensureLibraryCacheRoot(
            dbPool: pool,
            libraryURL: libraryURL,
            preferredPlacement: hasStored ? nil : cachePlacement
        )

        libraryHomeAccessMode = accessMode
        clearUserClosedLibrary()
        clearThumbnailCachePreferences()

        switch accessMode {
        case .rememberBookmark:
            clearRecentLibraries()
            setActiveLibraryPreferences(url: libraryURL)
            addToRecent(url: libraryURL)
            scrubPlainLocationPathsFromPrefs()
        case .askEachLaunch:
            clearActiveLibraryPreferences()
            clearRecentLibraries()
            addToRecent(url: libraryURL)
        case .standard:
            break
        }

        markLibraryHomeSetupComplete()
        relaunchAfterTerminate()
        NSApplication.shared.terminate(nil)
    }

    /// Ensures the library DB has a `library_cache` row (migration seed). Live reads happen at open.
    static func syncCachePreferences(forLibraryURL url: URL) {
        seedLibraryCacheIfNeeded(at: url, preferredPlacement: nil)
    }

    /// Clears remembered library paths after a prompt-each-launch session (quit or next launch).
    static func clearSessionLocationPreferencesIfNeeded() {
        guard promptsForLibraryEachLaunch else { return }
        clearActiveLibraryPreferences()
        clearThumbnailCachePreferences()
    }

    /// Retarget the open library’s cache (pointer only; does not move existing files).
    static func changeThumbnailCacheLocation(dbPool: DatabasePool, thumbnailService: ThumbnailService) {
        guard let libraryURL = activeLibraryURL() else { return }
        let current = (try? dbPool.read { db in try LibraryCacheStore.resolvedURL(db: db) })
            ?? ThumbnailCacheLocator.coLocatedCacheDirectory(forLibraryURL: libraryURL)

        let alert = NSAlert()
        alert.messageText = "Change Thumbnail Cache Location"
        alert.informativeText = """
        Choose where this library’s thumbnails and filmstrips are stored. Other libraries keep their own cache locations.

        Current: \(pathForDisplay(current))

        Existing cache files are left in place; Skagway will read/write the new folder going forward.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Co-locate with Library")
        alert.addButton(withTitle: "System Default")
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()

        let placement: LibraryCachePlacement
        switch response {
        case .alertFirstButtonReturn:
            placement = .coLocated
        case .alertSecondButtonReturn:
            placement = .systemDefault
        case .alertThirdButtonReturn:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = "Choose Thumbnail Cache Folder"
            panel.message = "Skagway will store this library’s thumbnails in the folder you choose."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            placement = .custom(url)
        default:
            return
        }

        do {
            let root = try applyCachePlacement(placement, libraryURL: libraryURL, dbPool: dbPool)
            thumbnailService.setSessionCacheRoot(root)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Prefer `Skagway.machii`, else the first `*.machii` in the folder (non-recursive).
    static func findLibraryFile(in folderURL: URL) -> URL? {
        let fm = FileManager.default
        let preferred = folderURL.appendingPathComponent(defaultLibraryFileName, isDirectory: false)
        if fm.fileExists(atPath: preferred.path) {
            return preferred
        }
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents.first {
            $0.pathExtension.lowercased() == libraryFilenameExtension
        }
    }

    private static func clearThumbnailCachePreferences() {
        UserDefaults.standard.removeObject(forKey: PrefsKeys.thumbnailCachePath)
        UserDefaults.standard.removeObject(forKey: PrefsKeys.thumbnailCacheBookmark)
    }

    // MARK: - Per-library cache

    /// Best-effort seed used before relaunch / switch. Failures are non-fatal.
    static func seedLibraryCacheIfNeeded(at libraryURL: URL, preferredPlacement: LibraryCachePlacement?) {
        do {
            let pool = try DatabasePool(path: libraryURL.path)
            try DatabaseMigration.migrate(pool)
            _ = try ensureLibraryCacheRoot(
                dbPool: pool,
                libraryURL: libraryURL,
                preferredPlacement: preferredPlacement
            )
        } catch {
            // Open path will retry; avoid blocking switch/setup on seed failure.
        }
    }

    private static func defaultPlacement(for libraryURL: URL) -> LibraryCachePlacement {
        let parent = libraryURL.deletingLastPathComponent().standardizedFileURL
        if parent.path == dbDirectoryURL.standardizedFileURL.path {
            return .systemDefault
        }
        return .coLocated
    }

    /// Resolve the library’s cache root from `library_cache`, or seed and persist it.
    @discardableResult
    static func ensureLibraryCacheRoot(
        dbPool: DatabasePool,
        libraryURL: URL,
        preferredPlacement: LibraryCachePlacement? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let hasStored = try dbPool.read { db in try LibraryCacheStore.hasStoredLocation(db: db) }

        if let preferredPlacement, !hasStored {
            return try applyCachePlacement(preferredPlacement, libraryURL: libraryURL, dbPool: dbPool)
        }

        if let existing = try dbPool.read({ db in try LibraryCacheStore.resolvedURL(db: db) }) {
            if fm.fileExists(atPath: existing.path) {
                _ = existing.startAccessingSecurityScopedResource()
                return existing
            }
            // Stored path missing — look for a sibling known cache name beside the old parent.
            let parent = existing.deletingLastPathComponent()
            if let relocated = ThumbnailCacheLocator.resolveExistingCacheDirectory(inParent: parent) {
                return try persistCacheRoot(relocated, dbPool: dbPool)
            }
            // Recreate at the stored path when the parent folder is still reachable.
            if fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: existing, withIntermediateDirectories: true)
                return try persistCacheRoot(existing, dbPool: dbPool)
            }
        }

        // No usable stored row — seed without using an unrelated volume’s legacy global cache.
        if let sibling = ThumbnailCacheLocator.resolveExistingCacheDirectory(
            inParent: libraryURL.deletingLastPathComponent()
        ) {
            return try persistCacheRoot(sibling, dbPool: dbPool)
        }
        if let legacy = legacyGlobalCacheURL(), isReasonableLegacyCache(legacy, forLibrary: libraryURL) {
            return try persistCacheRoot(legacy, dbPool: dbPool)
        }
        return try applyCachePlacement(defaultPlacement(for: libraryURL), libraryURL: libraryURL, dbPool: dbPool)
    }

    private static func applyCachePlacement(
        _ placement: LibraryCachePlacement,
        libraryURL: URL,
        dbPool: DatabasePool
    ) throws -> URL {
        let fm = FileManager.default
        let root: URL
        switch placement {
        case .coLocated:
            root = ThumbnailCacheLocator.coLocatedCacheDirectory(forLibraryURL: libraryURL)
        case .systemDefault:
            let parent = libraryURL.deletingLastPathComponent().standardizedFileURL
            if parent.path == dbDirectoryURL.standardizedFileURL.path {
                root = ThumbnailCacheLocator.standardSharedCacheDirectory
            } else {
                root = ThumbnailCacheLocator.systemCacheDirectory(forLibraryURL: libraryURL)
            }
        case .custom(let url):
            root = url
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return try persistCacheRoot(root, dbPool: dbPool)
    }

    private static func persistCacheRoot(_ root: URL, dbPool: DatabasePool) throws -> URL {
        let bookmark = LibraryCacheStore.makeBookmark(for: root)
        try dbPool.write { db in
            try LibraryCacheStore.save(db: db, directory: root, bookmark: bookmark)
        }
        _ = root.startAccessingSecurityScopedResource()
        return root.standardizedFileURL
    }

    /// Legacy app-wide prefs — seed source only.
    private static func legacyGlobalCacheURL() -> URL? {
        if let path = UserDefaults.standard.string(forKey: PrefsKeys.thumbnailCachePath) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let bookmark = UserDefaults.standard.data(forKey: PrefsKeys.thumbnailCacheBookmark),
           let url = resolveLibraryBookmark(bookmark),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    /// Only adopt a legacy global cache when it clearly belongs to this library (same folder or
    /// Standard App Support + system Caches). Prevents LibB from inheriting Enc’s cache.
    private static func isReasonableLegacyCache(_ cache: URL, forLibrary libraryURL: URL) -> Bool {
        let cacheParent = cache.deletingLastPathComponent().standardizedFileURL
        let libraryParent = libraryURL.deletingLastPathComponent().standardizedFileURL
        if cacheParent.path == libraryParent.path { return true }
        if libraryParent.path == dbDirectoryURL.standardizedFileURL.path {
            let systemParent = ThumbnailCacheLocator.systemSkagwayCachesParent.standardizedFileURL
            if cacheParent.path == systemParent.path { return true }
            if cache.path.hasPrefix(systemParent.path + "/") { return true }
        }
        return false
    }

    // MARK: - Launch
    // MARK: - Launch

    /// Run at app launch. Ensures App Support folder exists. Does not create a default library.
    /// Does not touch the Open Recent list (Clear Menu must stay cleared across launches).
    static func prepareDatabaseForLaunch() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dbDirectoryURL, withIntermediateDirectories: true)
        scrubPlainLocationPathsFromPrefs()

        try? fm.removeItem(at: dbDirectoryURL.appendingPathComponent("relaunch.sh", isDirectory: false))
        try? fm.removeItem(at: dbDirectoryURL.appendingPathComponent("relaunch_out.log", isDirectory: false))
        try? fm.removeItem(at: dbDirectoryURL.appendingPathComponent("relaunch_err.log", isDirectory: false))
    }
}

enum LibraryHomeSetupError: LocalizedError {
    case notAFolder

    var errorDescription: String? {
        switch self {
        case .notAFolder:
            return "Choose a folder for the library and thumbnail cache."
        }
    }
}
