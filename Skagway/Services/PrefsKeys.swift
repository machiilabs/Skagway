import Foundation

/// Canonical UserDefaults keys for Skagway. Prefer these over string literals.
enum PrefsKeys {
    static let prefix = "Skagway."

    static let didCompleteLegacyRename = "Skagway.didCompleteLegacyRename"

    // Library bookmarks / paths
    // Standard / in-session askEachLaunch may use plain paths. rememberBookmark is bookmark-only
    // (no activeLibraryPath / thumbnailCachePath on disk).
    static let activeLibraryBookmark = "Skagway.activeLibraryBookmark"
    static let activeLibraryPath = "Skagway.activeLibraryPath"
    static let recentLibraryBookmarks = "Skagway.recentLibraryBookmarks"
    static let recentLibraryPaths = "Skagway.recentLibraryPaths"
    static let userClosedLibrary = "Skagway.userClosedLibrary"
    /// One-time privacy / library-home chooser completed (Standard vs custom folder).
    static let didCompleteLibraryHomeSetup = "Skagway.didCompleteLibraryHomeSetup"
    /// `LibraryHomeAccessMode.rawValue`: standard | rememberBookmark | askEachLaunch
    static let libraryHomeAccessMode = "Skagway.libraryHomeAccessMode"
    /// Legacy app-wide cache prefs (migration seed only). Live root is `library_cache` in each `.machii`.
    static let thumbnailCachePath = "Skagway.thumbnailCachePath"
    static let thumbnailCacheBookmark = "Skagway.thumbnailCacheBookmark"

    // Extensions / playback positions / split dividers
    static let videoExtensions = "Skagway.videoExtensions"
    static let playbackLastPositionsByPath = "Skagway.playback.lastPositionsByPath"
    static let playbackDividerSidebar = "Skagway.playbackDividerSidebar"
    static let playbackDividerContent = "Skagway.playbackDividerContent"

    // LibraryViewModel prefs (suffix after prefix)
    static let metadataExportFormat = "Skagway.metadataExportFormat"
    static let metadataExportColumnOrder = "Skagway.metadataExportColumnOrder"
    static let metadataExportIncludedColumns = "Skagway.metadataExportIncludedColumns"
    static let bulkRenamePattern = "Skagway.bulkRenamePattern"
    static let viewMode = "Skagway.viewMode"
    static let gridSize = "Skagway.gridSize"
    static let sortColumn = "Skagway.sortColumn"
    static let sortAscending = "Skagway.sortAscending"
    static let excludeCorrupt = "Skagway.excludeCorrupt"
    static let confirmDeletions = "Skagway.confirmDeletions"
    static let showThumbnailInDetail = "Skagway.showThumbnailInDetail"
    static let gridHoverPreviewEnabled = "Skagway.gridHoverPreviewEnabled"
    static let browsingLayout = "Skagway.browsingLayout"
    static let filmstripRows = "Skagway.filmstripRows"
    static let filmstripColumns = "Skagway.filmstripColumns"
    static let lastAppliedFilmstripRows = "Skagway.lastAppliedFilmstripRows"
    static let lastAppliedFilmstripColumns = "Skagway.lastAppliedFilmstripColumns"
    static let filmstripCacheEpoch = "Skagway.filmstripCacheEpoch"
    static let surpriseMeAutoPlays = "Skagway.surpriseMeAutoPlays"
    static let playAllLoops = "Skagway.playAllLoops"
    static let playerFloatingWidth = "Skagway.playerFloatingWidth"
    static let playerFloatingHeight = "Skagway.playerFloatingHeight"
    static let playerFloatingPositionX = "Skagway.playerFloatingPositionX"
    static let playerFloatingPositionY = "Skagway.playerFloatingPositionY"
    static let playerStartPreference = "Skagway.playerStartPreference"
    static let playerSizeIsCompact = "Skagway.playerSizeIsCompact"
    static let playerLastWasFullScreen = "Skagway.playerLastWasFullScreen"
    static let fadeResumeBannerAutomatically = "Skagway.fadeResumeBannerAutomatically"
    static let resumeBannerFadeDelaySeconds = "Skagway.resumeBannerFadeDelaySeconds"
    static let tagBlindDefaultState = "Skagway.tagBlindDefaultState"
    static let recentlyAddedDays = "Skagway.recentlyAddedDays"
    static let recentlyPlayedDays = "Skagway.recentlyPlayedDays"
    static let topRatedMinRating = "Skagway.topRatedMinRating"
    static let showRecentlyAdded = "Skagway.showRecentlyAdded"
    static let showRecentlyPlayed = "Skagway.showRecentlyPlayed"
    static let showTopRated = "Skagway.showTopRated"
    static let showDuplicates = "Skagway.showDuplicates"
    static let showCorrupt = "Skagway.showCorrupt"
    static let showMissing = "Skagway.showMissing"
    static let showRecentlyConverted = "Skagway.showRecentlyConverted"
    static let recentlyConvertedEntries = "Skagway.recentlyConvertedEntries"
    static let recentlyAppliedPaths = "Skagway.recentlyAppliedPaths"
    static let lastAddedPaths = "Skagway.lastAddedPaths"
    static let conversionJobs = "Skagway.conversionJobs"
    static let moveJobs = "Skagway.moveJobs"
    static let ffmpegPath = "Skagway.ffmpegPath"
    /// Legacy global field definitions (pre–per-library). Kept only as a one-time seed source when a
    /// library's `custom_metadata_field` table is empty; new edits write to the library DB only.
    static let customMetadataFieldDefinitions = "Skagway.customMetadataFieldDefinitions"
    static let missingCountScanned = "Skagway.missingCountScanned"
    static let filtersDrawerHeight = "Skagway.filtersDrawerHeight"
    static let filterDrawerHeightMode = "Skagway.filterDrawerHeightMode"
    static let filtersDrawerMode = "Skagway.filtersDrawerMode"
    static let inspectorHeroHeight = "Skagway.inspectorHeroHeight"
    static let missingVideoIds = "Skagway.missingVideoIds"
    static let listColumnPreferences = "Skagway.listColumnPreferences"

    /// Suffixes that map former `*.<suffix>` prefs into `Skagway.<suffix>` (see LegacyRenameMigrator).
    static let migratableSuffixes: [String] = [
        "activeLibraryBookmark",
        "activeLibraryPath",
        "recentLibraryBookmarks",
        "recentLibraryPaths",
        "userClosedLibrary",
        "lastOpenedLibraryBookmark", // maps into activeLibraryBookmark specially if needed
        "videoExtensions",
        "metadataExportFormat",
        "metadataExportColumnOrder",
        "metadataExportIncludedColumns",
        "viewMode",
        "gridSize",
        "sortColumn",
        "sortAscending",
        "excludeCorrupt",
        "confirmDeletions",
        "showThumbnailInDetail",
        "browsingLayout",
        "filmstripRows",
        "filmstripColumns",
        "lastAppliedFilmstripRows",
        "lastAppliedFilmstripColumns",
        "filmstripCacheEpoch",
        "surpriseMeAutoPlays",
        "playAllLoops",
        "gridHoverPreviewEnabled",
        "playerFloatingWidth",
        "playerFloatingHeight",
        "playerFloatingPositionX",
        "playerFloatingPositionY",
        "playerStartPreference",
        "playerSizeIsCompact",
        "playerLastWasFullScreen",
        "fadeResumeBannerAutomatically",
        "resumeBannerFadeDelaySeconds",
        "tagBlindDefaultState",
        "recentlyAddedDays",
        "recentlyPlayedDays",
        "topRatedMinRating",
        "showRecentlyAdded",
        "showRecentlyPlayed",
        "showTopRated",
        "showDuplicates",
        "showCorrupt",
        "showMissing",
        "showRecentlyConverted",
        "recentlyConvertedEntries",
        "recentlyAppliedPaths",
        "lastAddedPaths",
        "conversionJobs",
        "moveJobs",
        "ffmpegPath",
        "customMetadataFieldDefinitions",
        "missingCountScanned",
        "filtersDrawerHeight",
        "filterDrawerHeightMode",
        "inspectorHeroHeight",
        "missingVideoIds",
        "listColumnPreferences",
        "detailHeight",
        "detailWidth",
        "columnCustomization",
    ]
}
