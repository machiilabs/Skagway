import Foundation

/// Snapshot data required to evaluate Membership rules (smart libraries and albums).
struct LibraryFilterContext: Sendable {
    var duplicateVideoIds: Set<String>
    var missingVideoIds: Set<String>
    var recentlyAddedDays: Int
    var recentlyPlayedDays: Int
    var topRatedMinRating: Int
    var recentlyConvertedDates: [String: Date]
    var recentlyAppliedPaths: Set<String>
    var lastAddedPaths: Set<String>
    var thumbnailsSettled: Bool
    var cachedAlbumVideoIds: [Int64: [Int64]]

    static func from(
        duplicateVideoIds: Set<String>,
        missingVideoIds: Set<String>,
        recentlyAddedDays: Int,
        recentlyPlayedDays: Int,
        topRatedMinRating: Int,
        recentlyConvertedDates: [String: Date],
        recentlyAppliedPaths: Set<String>,
        lastAddedPaths: Set<String>,
        thumbnailsSettled: Bool,
        cachedAlbumVideoIds: [Int64: [Int64]]
    ) -> LibraryFilterContext {
        LibraryFilterContext(
            duplicateVideoIds: duplicateVideoIds,
            missingVideoIds: missingVideoIds,
            recentlyAddedDays: recentlyAddedDays,
            recentlyPlayedDays: recentlyPlayedDays,
            topRatedMinRating: topRatedMinRating,
            recentlyConvertedDates: recentlyConvertedDates,
            recentlyAppliedPaths: recentlyAppliedPaths,
            lastAddedPaths: lastAddedPaths,
            thumbnailsSettled: thumbnailsSettled,
            cachedAlbumVideoIds: cachedAlbumVideoIds
        )
    }
}

enum MembershipMatcher {
    static func matches(
        _ target: MembershipTarget,
        video: Video,
        context: LibraryFilterContext
    ) -> Bool {
        switch target {
        case .smartLibrary(let kind):
            return matchesSmartLibrary(kind, video: video, context: context)
        case .album(let collectionId):
            guard let dbId = video.databaseId else { return false }
            let members = Set(context.cachedAlbumVideoIds[collectionId] ?? [])
            return members.contains(dbId)
        }
    }

    private static func matchesSmartLibrary(
        _ kind: SmartLibraryKind,
        video: Video,
        context: LibraryFilterContext
    ) -> Bool {
        switch kind {
        case .recentlyAdded:
            let cutoff = Calendar.current.date(byAdding: .day, value: -context.recentlyAddedDays, to: Date()) ?? Date()
            return video.dateAdded >= cutoff
        case .recentlyPlayed:
            let cutoff = Calendar.current.date(byAdding: .day, value: -context.recentlyPlayedDays, to: Date()) ?? Date()
            return (video.lastPlayed ?? .distantPast) >= cutoff
        case .topRated:
            return video.rating >= context.topRatedMinRating
        case .duplicates:
            return context.duplicateVideoIds.contains(video.id)
        case .corrupt:
            return VideoIntegrity.isCorrupt(video, thumbnailsSettled: context.thumbnailsSettled)
        case .missing:
            return context.missingVideoIds.contains(video.id)
        case .recentlyConverted:
            return context.recentlyConvertedDates[video.filePath] != nil
        case .recentlyApplied:
            return context.recentlyAppliedPaths.contains(video.filePath)
        case .lastAdded:
            return context.lastAddedPaths.contains(video.filePath)
        }
    }
}
