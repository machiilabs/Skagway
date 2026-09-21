import Foundation

/// Sort-aware one-line copy for the browser scroll chip.
///
/// Lookup is O(1): callers map scroll fraction → `filteredVideos` index, then format that row.
enum ScrollIndexHUDLabel {
    enum Sort: Equatable {
        case title
        case dateAdded
        case creationDate
        case lastPlayed
        case duration
        case rating
        case fileSize
        case resolution
        case playCount
        case parentFolder
        case albumOrder
        case random
        case custom
    }

    /// Item index for a 0...1 scroll fraction. Empty lists return `nil`.
    static func index(fraction: Double, count: Int) -> Int? {
        guard count > 0 else { return nil }
        if count == 1 { return 0 }
        let clamped = min(1, max(0, fraction))
        return min(count - 1, Int((clamped * Double(count - 1)).rounded()))
    }

    static func sort(
        isRandomOrder: Bool,
        isShowingAlbumOrder: Bool,
        hasCustomSort: Bool,
        keyPath: PartialKeyPath<Video>?
    ) -> Sort {
        if isRandomOrder { return .random }
        if isShowingAlbumOrder { return .albumOrder }
        if hasCustomSort { return .custom }
        guard let keyPath else { return .dateAdded }
        if keyPath == \Video.displayTitle as PartialKeyPath<Video>
            || keyPath == \Video.fileName as PartialKeyPath<Video>
        {
            return .title
        }
        if keyPath == \Video.sortableDuration as PartialKeyPath<Video> { return .duration }
        if keyPath == \Video.fileSize as PartialKeyPath<Video> { return .fileSize }
        if keyPath == \Video.rating as PartialKeyPath<Video> { return .rating }
        if keyPath == \Video.sortableResolutionHeight as PartialKeyPath<Video>
            || keyPath == \Video.sortablePixelCount as PartialKeyPath<Video>
        {
            return .resolution
        }
        if keyPath == \Video.playCount as PartialKeyPath<Video>
            || keyPath == \Video.sortablePlayCount as PartialKeyPath<Video>
        {
            return .playCount
        }
        if keyPath == \Video.dateAdded as PartialKeyPath<Video> { return .dateAdded }
        if keyPath == \Video.sortableCreationDate as PartialKeyPath<Video>
            || keyPath == \Video.creationDate as PartialKeyPath<Video>
        {
            return .creationDate
        }
        if keyPath == \Video.sortableLastPlayed as PartialKeyPath<Video>
            || keyPath == \Video.lastPlayed as PartialKeyPath<Video>
        {
            return .lastPlayed
        }
        if keyPath == \Video.filePath as PartialKeyPath<Video> { return .parentFolder }
        return .dateAdded
    }

    static func text(
        sort: Sort,
        video: Video,
        index: Int,
        count: Int,
        customDisplay: String? = nil
    ) -> String {
        switch sort {
        case .title:
            return titlePrefix(video.displayTitle)
        case .dateAdded:
            return dateText(video.dateAdded)
        case .creationDate:
            return video.creationDate.map(dateText) ?? "—"
        case .lastPlayed:
            return video.lastPlayed.map(dateText) ?? "—"
        case .duration:
            return durationText(video.duration)
        case .rating:
            return ratingText(video.rating)
        case .fileSize:
            return video.formattedFileSize
        case .resolution:
            return video.resolutionLabel ?? "—"
        case .playCount:
            return playCountText(video.playCount)
        case .parentFolder:
            return parentFolderName(filePath: video.filePath)
        case .albumOrder, .random:
            return "#\(index + 1) of \(count)"
        case .custom:
            let trimmed = customDisplay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "—" : trimmed
        }
    }

    /// First three characters of the title, uppercased. Short titles stay as-is; empty → "•".
    static func titlePrefix(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "•" }
        return String(trimmed.prefix(3)).localizedUppercase
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `< 1 min` → `NN sec`; `1..<60 min` → `mm:ss`; `>= 60 min` → `hh:mm:ss`.
    static func durationText(_ duration: Double?) -> String {
        guard let duration, duration >= 0 else { return "—" }
        let totalSeconds = Int(duration)
        if totalSeconds < 60 {
            return String(format: "%02d sec", totalSeconds)
        }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours >= 1 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func ratingText(_ rating: Int) -> String {
        if rating <= 0 { return "Unrated" }
        return String(repeating: "★", count: min(5, rating))
    }

    static func playCountText(_ count: Int) -> String {
        count == 1 ? "1 play" : "\(count) plays"
    }

    static func parentFolderName(filePath: String) -> String {
        let url = URL(fileURLWithPath: filePath)
        let parent = url.deletingLastPathComponent().lastPathComponent
        if parent.isEmpty || parent == "/" { return "—" }
        return parent
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
