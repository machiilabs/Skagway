import Foundation

/// One searchable settings entry. Selecting a match opens its sheet (no scroll-to-row).
struct SettingsSearchItem: Identifiable, Hashable {
    let id: String
    let title: String
    let category: SettingsCategory
    let keywords: [String]

    func matches(query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if title.lowercased().contains(q) { return true }
        if category.title.lowercased().contains(q) { return true }
        return keywords.contains { $0.lowercased().contains(q) }
    }
}

enum SettingsSearchCatalog {
    static let all: [SettingsSearchItem] = [
        // Sheets
        .init(id: "sheet.library", title: "Library", category: .library, keywords: ["settings"]),
        .init(id: "sheet.video", title: "Video", category: .video, keywords: ["settings"]),
        .init(id: "sheet.dataSources", title: "Data Sources", category: .dataSources, keywords: ["folders", "scan", "import", "watch", "exclude"]),
        .init(id: "sheet.fileExt", title: "Extensions", category: .fileExt, keywords: ["file ext", "formats", "mp4", "mov", "mkv"]),
        .init(id: "sheet.tools", title: "Tools", category: .tools, keywords: ["ffmpeg"]),
        .init(id: "sheet.customMetadata", title: "Custom Metadata", category: .customMetadata, keywords: ["fields", "inspector"]),

        // Library
        .init(
            id: "library.excludeCorrupt",
            title: "Exclude corrupt files from filters",
            category: .library,
            keywords: ["corrupt", "filters", "hide"]
        ),
        .init(
            id: "library.confirmDeletions",
            title: "Confirm deletions",
            category: .library,
            keywords: ["delete", "trash", "confirmation"]
        ),
        .init(
            id: "library.storage",
            title: "Library location",
            category: .library,
            keywords: ["storage", "location", "folder", "encrypted", "home"]
        ),
        .init(
            id: "library.storage.change",
            title: "Change Library Location…",
            category: .library,
            keywords: ["storage", "location", "folder", "setup", "startup", "home"]
        ),
        .init(
            id: "library.storage.cache",
            title: "Change Thumbnail Cache Location…",
            category: .library,
            keywords: ["storage", "location", "cache", "folder", "thumbnail", "filmstrip"]
        ),
        .init(
            id: "library.autoUpdates",
            title: "Automatically check for updates",
            category: .library,
            keywords: ["sparkle", "update", "download", "appcast"]
        ),
        .init(
            id: "library.smartLibraries",
            title: "Smart Libraries",
            category: .library,
            keywords: ["sidebar", "filters"]
        ),
        .init(
            id: "library.recentlyAdded",
            title: "Recently Added",
            category: .library,
            keywords: ["smart libraries", "days"]
        ),
        .init(
            id: "library.recentlyPlayed",
            title: "Recently Played",
            category: .library,
            keywords: ["smart libraries", "days"]
        ),
        .init(
            id: "library.topRated",
            title: "Top Rated",
            category: .library,
            keywords: ["smart libraries", "rating", "stars"]
        ),
        .init(id: "library.duplicates", title: "Duplicates", category: .library, keywords: ["smart libraries"]),
        .init(id: "library.corrupt", title: "Corrupt", category: .library, keywords: ["smart libraries"]),
        .init(id: "library.missing", title: "Missing", category: .library, keywords: ["smart libraries"]),
        .init(
            id: "library.recentlyConverted",
            title: "Recently Converted",
            category: .library,
            keywords: ["smart libraries", "re-encode", "fix for built-in player"]
        ),
        .init(
            id: "library.listColumns",
            title: "List view columns",
            category: .library,
            keywords: ["columns", "duration", "resolution", "rating", "plays", "custom"]
        ),
        .init(id: "library.col.duration", title: "Duration", category: .library, keywords: ["list", "columns"]),
        .init(id: "library.col.resolution", title: "Resolution", category: .library, keywords: ["list", "columns"]),
        .init(id: "library.col.size", title: "File size", category: .library, keywords: ["list", "columns"]),
        .init(id: "library.col.rating", title: "Rating", category: .library, keywords: ["list", "columns"]),
        .init(id: "library.col.dateAdded", title: "Date added", category: .library, keywords: ["list", "columns"]),
        .init(id: "library.col.plays", title: "Plays", category: .library, keywords: ["list", "columns", "play count"]),
        .init(id: "library.col.created", title: "Created", category: .library, keywords: ["list", "columns"]),
        .init(id: "library.col.lastPlayed", title: "Last played", category: .library, keywords: ["list", "columns"]),

        // Video
        .init(
            id: "video.filmstrip",
            title: "Default Filmstrip Size",
            category: .video,
            keywords: ["rows", "columns", "frames", "regenerate"]
        ),
        .init(id: "video.filmstrip.rows", title: "Rows", category: .video, keywords: ["filmstrip"]),
        .init(id: "video.filmstrip.columns", title: "Columns", category: .video, keywords: ["filmstrip"]),
        .init(
            id: "video.filmstrip.regenerate",
            title: "Regenerate filmstrips",
            category: .video,
            keywords: ["filmstrip", "cache"]
        ),
        .init(
            id: "video.surpriseMe",
            title: "Surprise Me! auto-plays selected video",
            category: .video,
            keywords: ["surprise", "autoplay", "random"]
        ),
        .init(
            id: "video.playAllLoop",
            title: "Loop Play All",
            category: .video,
            keywords: ["album", "loop", "playlist", "repeat", "play all"]
        ),
        .init(
            id: "video.hoverPreview",
            title: "Hover preview on Grid and List",
            category: .video,
            keywords: ["hover", "scrub", "grid", "list", "thumbnail"]
        ),
        .init(
            id: "video.tagBlind",
            title: "Tag blind default state",
            category: .video,
            keywords: ["tags", "inspector", "add tags"]
        ),
        .init(
            id: "video.filterDrawer",
            title: "Filter drawer height",
            category: .video,
            keywords: ["filters", "drawer"]
        ),
        .init(
            id: "video.playerOpens",
            title: "Player opens at",
            category: .video,
            keywords: ["playback", "compact", "full screen", "size"]
        ),
        .init(
            id: "video.playerFilmstrip",
            title: "Show filmstrip in player",
            category: .video,
            keywords: ["filmstrip", "playback", "scrubber", "frames", "player"]
        ),
        .init(
            id: "video.resumeBanner",
            title: "Fade resume banner after delay",
            category: .video,
            keywords: ["playback", "resume", "banner"]
        ),
        .init(
            id: "video.resumeSeconds",
            title: "Seconds before fade",
            category: .video,
            keywords: ["playback", "resume", "banner", "delay"]
        ),

        // Data Sources
        .init(
            id: "dataSources.folders",
            title: "Folders",
            category: .dataSources,
            keywords: ["data sources", "scan", "import", "watch", "add folder"]
        ),
        .init(
            id: "dataSources.excludedFolders",
            title: "Exclude a subfolder",
            category: .dataSources,
            keywords: ["data sources", "scan", "exclude", "skip", "ignore", "exclude folder", "hover"]
        ),

        // File Ext
        .init(
            id: "fileExt.extensions",
            title: "Extensions",
            category: .fileExt,
            keywords: ["extensions", "video formats", "mp4", "mov", "mkv", "file ext"]
        ),
        .init(
            id: "fileExt.add",
            title: "Add Extension",
            category: .fileExt,
            keywords: ["new extension", "file ext"]
        ),
        .init(
            id: "fileExt.reset",
            title: "Reset to Defaults",
            category: .fileExt,
            keywords: ["extensions", "file ext"]
        ),

        // Tools
        .init(
            id: "tools.ffmpeg",
            title: "FFmpeg",
            category: .tools,
            keywords: ["tools", "encode", "repair"]
        ),
        .init(
            id: "tools.status",
            title: "Status",
            category: .tools,
            keywords: ["ffmpeg", "fix for built-in player", "re-encode"]
        ),
        .init(
            id: "tools.path",
            title: "Path",
            category: .tools,
            keywords: ["ffmpeg", "custom path", "homebrew"]
        ),

        // Custom Metadata
        .init(
            id: "customMetadata.fields",
            title: "Fields",
            category: .customMetadata,
            keywords: ["custom metadata", "fields", "name", "type", "inspector"]
        ),
        .init(
            id: "customMetadata.manage",
            title: "Manage",
            category: .customMetadata,
            keywords: ["custom metadata", "fields", "add"]
        ),
        .init(
            id: "customMetadata.newField",
            title: "New field",
            category: .customMetadata,
            keywords: ["custom metadata", "add field", "manage", "name", "type"]
        ),
    ]

    static func matches(for searchText: String) -> [SettingsSearchItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return all.filter { $0.matches(query: q) }
    }
}
