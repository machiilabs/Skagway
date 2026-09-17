import Foundation

/// Whole-tree Location A → Location B remap for missing library media.
///
/// Matches `oldRoot/relative` → `newRoot/relative`. Soft checks (file size when cheap)
/// only flag conflicts — they never force a re-import or ffmpeg probe.
enum LocationRelink {

    // MARK: - Path helpers

    /// Strip trailing slashes (except root `/`) and standardize.
    static func normalizeRoot(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var p = url.path
        while p.count > 1, p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    /// True when `path` is `root` or a descendant (path-separator boundary).
    static func isUnder(root: String, path: String) -> Bool {
        let r = normalizeRoot(root)
        let p = normalizeRoot(path)
        if p.caseInsensitiveCompare(r) == .orderedSame { return true }
        guard p.count > r.count + 1 else { return false }
        let prefix = String(p.prefix(r.count))
        guard prefix.caseInsensitiveCompare(r) == .orderedSame else { return false }
        let sep = p[p.index(p.startIndex, offsetBy: r.count)]
        return sep == "/"
    }

    /// Relative path under `root`, or `nil` if not under root.
    static func relativePath(under root: String, fullPath: String) -> String? {
        let r = normalizeRoot(root)
        let p = normalizeRoot(fullPath)
        if p.caseInsensitiveCompare(r) == .orderedSame { return "" }
        guard isUnder(root: r, path: p) else { return nil }
        let start = p.index(p.startIndex, offsetBy: r.count + 1)
        return String(p[start...])
    }

    /// Path segments for sorting (no empty/`/` components).
    static func pathSortComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: normalizeRoot(path)).pathComponents.filter { $0 != "/" && !$0.isEmpty }
    }

    /// Component-wise path order: compare each segment case-insensitively; a shorter
    /// equal-prefix path sorts before a longer one.
    ///
    /// So `/Volumes/Media` and `/Volumes/Media/Shows` both sort before `/Volumes/Media 2`
    /// (full-string compare wrongly puts `Media 2` first because space < `/`).
    static func comparePathsByComponents(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = pathSortComponents(lhs)
        let b = pathSortComponents(rhs)
        let n = min(a.count, b.count)
        for i in 0..<n {
            let cmp = a[i].localizedCaseInsensitiveCompare(b[i])
            if cmp != .orderedSame { return cmp }
        }
        if a.count < b.count { return .orderedAscending }
        if a.count > b.count { return .orderedDescending }
        return .orderedSame
    }

    static func join(root: String, relative: String) -> String {
        let r = normalizeRoot(root)
        if relative.isEmpty { return r }
        return URL(fileURLWithPath: r).appendingPathComponent(relative).path
    }

    // MARK: - Shared missing root

    /// Infer the shared missing library folder from missing video paths.
    /// Prefers an exact Data Source root when one covers all (or most) missing files.
    static func inferSharedMissingRoot(
        missingPaths: [String],
        dataSourceRoots: [String] = []
    ) -> String? {
        let missing = missingPaths.map(normalizeRoot).filter { !$0.isEmpty }
        guard !missing.isEmpty else { return nil }

        // Prefer a data source that owns every missing path and whose folder is itself missing.
        let fm = FileManager.default
        let coveringSources = dataSourceRoots
            .map(normalizeRoot)
            .filter { root in
                missing.allSatisfy { isUnder(root: root, path: $0) }
                    && !fm.fileExists(atPath: root)
            }
            .sorted { $0.count > $1.count }
        if let best = coveringSources.first {
            return best
        }

        // Longest common directory prefix of the missing files.
        guard let common = longestCommonDirectoryPrefix(of: missing) else { return nil }
        // Don't offer `/` or a home-directory-level root — too broad.
        let components = URL(fileURLWithPath: common).pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
        guard components.count >= 2 else { return nil }
        return common
    }

    static func longestCommonDirectoryPrefix(of paths: [String]) -> String? {
        guard let first = paths.first else { return nil }
        var prefixComponents = URL(fileURLWithPath: first).pathComponents
        for path in paths.dropFirst() {
            let comps = URL(fileURLWithPath: path).pathComponents
            var i = 0
            while i < prefixComponents.count, i < comps.count, prefixComponents[i] == comps[i] {
                i += 1
            }
            prefixComponents = Array(prefixComponents.prefix(i))
            if prefixComponents.isEmpty { return nil }
        }
        // Drop the filename component of the first path if the "prefix" still includes a file.
        // We want a directory: if every path shares up through the parent of the files, good.
        // When all files sit in the same leaf folder, common prefix includes that folder.
        // When paths are files, last shared component may be a directory already.
        guard prefixComponents.count >= 2 else { return nil }
        // If the common prefix is identical to one of the file paths, step up to parent.
        let joined = NSString.path(withComponents: prefixComponents)
        if paths.contains(where: { normalizeRoot($0) == normalizeRoot(joined) }) {
            prefixComponents.removeLast()
            guard prefixComponents.count >= 2 else { return nil }
            return NSString.path(withComponents: prefixComponents)
        }
        return joined
    }

    // MARK: - Old-location candidates (no filesystem picker)

    enum OldRootSource: String, Equatable {
        case dataSource
        case libraryFolder
    }

    /// A folder the user can pick as Location A — derived from catalog paths, not from browsing disk.
    struct OldRootCandidate: Equatable, Identifiable, Hashable {
        var id: String { path }
        var path: String
        var videoCount: Int
        var sources: Set<OldRootSource>

        var subtitle: String {
            var parts: [String] = ["\(videoCount) clip\(videoCount == 1 ? "" : "s")"]
            if sources.contains(.dataSource) { parts.append("Data Source") }
            return parts.joined(separator: " · ")
        }
    }

    /// Collect selectable old roots from stored video paths and configured data sources.
    ///
    /// Includes:
    /// - every data source root
    /// - every ancestor folder of each video that sits under a data source (recursive under DS)
    /// - parent folders of videos not under any data source (library path prefixes)
    ///
    /// Does **not** consult the live filesystem — missing/offline roots stay choosable.
    static func collectOldRootCandidates(
        videoPaths: [String],
        dataSourceRoots: [String],
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) -> [OldRootCandidate] {
        let videos = videoPaths.map(normalizeRoot).filter { !$0.isEmpty }
        let sources = Array(Set(dataSourceRoots.map(normalizeRoot).filter { !$0.isEmpty }))
            .sorted { $0.count > $1.count } // longest first for ownership

        var candidatePaths = Set<String>()
        var tags: [String: Set<OldRootSource>] = [:]

        func note(_ path: String, _ source: OldRootSource) {
            let p = normalizeRoot(path)
            guard isSelectableOldRoot(p) else { return }
            candidatePaths.insert(p)
            tags[p, default: []].insert(source)
        }

        onProgress?(0.02)
        for source in sources {
            note(source, .dataSource)
        }

        let videoTotal = max(videos.count, 1)
        for (index, video) in videos.enumerated() {
            let parent = URL(fileURLWithPath: video).deletingLastPathComponent().path
            let owningSource = sources.first { isUnder(root: $0, path: video) }

            if let owningSource {
                // Walk from the file's folder up through the data source root (inclusive).
                var cursor = normalizeRoot(parent)
                while isSelectableOldRoot(cursor), isUnder(root: owningSource, path: cursor) {
                    let tag: OldRootSource = (cursor.caseInsensitiveCompare(owningSource) == .orderedSame)
                        ? .dataSource : .libraryFolder
                    note(cursor, tag)
                    if cursor.caseInsensitiveCompare(owningSource) == .orderedSame { break }
                    let next = URL(fileURLWithPath: cursor).deletingLastPathComponent().path
                    let nextNorm = normalizeRoot(next)
                    if nextNorm == cursor { break }
                    cursor = nextNorm
                }
            } else {
                // No data source — offer parent folders up to a shallow bound.
                var cursor = normalizeRoot(parent)
                var depth = 0
                while isSelectableOldRoot(cursor), depth < 8 {
                    note(cursor, .libraryFolder)
                    let next = URL(fileURLWithPath: cursor).deletingLastPathComponent().path
                    let nextNorm = normalizeRoot(next)
                    if nextNorm == cursor { break }
                    cursor = nextNorm
                    depth += 1
                }
            }
            if index == videos.count - 1 || index % 128 == 0 {
                onProgress?(0.05 + 0.70 * Double(index + 1) / Double(videoTotal))
            }
        }

        var result: [OldRootCandidate] = []
        let pathList = Array(candidatePaths)
        let pathTotal = max(pathList.count, 1)
        for (index, path) in pathList.enumerated() {
            let videoCount = videos.filter { isUnder(root: path, path: $0) }.count
            let src = tags[path] ?? [.libraryFolder]
            // Keep zero-video data sources; drop empty library-only folders.
            if videoCount == 0 && !src.contains(.dataSource) { continue }
            result.append(OldRootCandidate(path: path, videoCount: videoCount, sources: src))
            if index == pathList.count - 1 || index % 16 == 0 {
                onProgress?(0.75 + 0.24 * Double(index + 1) / Double(pathTotal))
            }
        }

        onProgress?(1.0)
        return result.sorted {
            comparePathsByComponents($0.path, $1.path) == .orderedAscending
        }
    }

    /// Skip `/`, bare `/Volumes`, and `/Users/name` — too broad to remount as Location A.
    static func isSelectableOldRoot(_ path: String) -> Bool {
        let p = normalizeRoot(path)
        guard !p.isEmpty, p != "/" else { return false }
        let comps = URL(fileURLWithPath: p).pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if comps.count < 2 { return false }
        if comps.count == 2, comps[0] == "Users" { return false }
        return true
    }

    // MARK: - Preview

    enum MatchKind: Equatable {
        /// New path exists and soft checks pass (or no metadata to check).
        case reconnect
        /// New path exists but size (or library collision) needs attention.
        case needsAttention(reason: String)
        /// Relative path not found under the new root.
        case stillMissing
    }

    enum MatchSource: Equatable {
        /// Relative path under a whole-folder old→new root pair.
        case wholeFolder
        /// Basename (+ soft size) under a user-chosen Evidence Destination.
        case evidenceDestination(root: String)
    }

    struct Candidate: Equatable, Identifiable {
        var id: String { oldPath }
        var videoDatabaseId: Int64?
        var oldPath: String
        var newPath: String
        var relativePath: String
        var kind: MatchKind
        var expectedSize: Int64?
        var foundSize: Int64?
        var matchSource: MatchSource = .wholeFolder

        /// Destination root used for basename matches (nil for whole-folder relative remaps).
        var evidenceDestination: String? {
            if case .evidenceDestination(let root) = matchSource { return root }
            return nil
        }
    }

    struct Preview: Equatable {
        var oldRoot: String
        var newRoot: String
        var candidates: [Candidate]
        /// User-chosen Evidence Destination folders for this session (may be empty).
        var evidenceDestinations: [String] = []

        var reconnectCount: Int { candidates.filter { $0.kind == .reconnect }.count }
        var needsAttentionCount: Int {
            candidates.filter {
                if case .needsAttention = $0.kind { return true }
                return false
            }.count
        }
        var stillMissingCount: Int { candidates.filter { $0.kind == .stillMissing }.count }

        /// True when this preview includes a whole-folder root remap (data sources/excludes).
        var hasWholeFolderRemap: Bool {
            !oldRoot.isEmpty && !newRoot.isEmpty
                && oldRoot.caseInsensitiveCompare(newRoot) != .orderedSame
        }
    }

    /// Build a dry-run preview for remapping every video under `oldRoot` to `newRoot`.
    ///
    /// - Parameters:
    ///   - videos: library videos (typically those under oldRoot; others are ignored).
    ///   - existingLibraryPaths: all current `filePath` values (to detect destination collisions).
    ///   - fileExists: injectable for tests.
    ///   - fileSize: injectable soft check (nil = skip size check).
    static func buildPreview(
        videos: [(databaseId: Int64?, filePath: String, fileSize: Int64)],
        oldRoot: String,
        newRoot: String,
        existingLibraryPaths: Set<String>,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        fileSize: (String) -> Int64? = { path in
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        }
    ) -> Preview {
        let old = normalizeRoot(oldRoot)
        let neu = normalizeRoot(newRoot)
        var reservedNew = Set(existingLibraryPaths.map(normalizeRoot))
        // Paths we're vacating under oldRoot become free for other remaps in this batch.
        for v in videos where isUnder(root: old, path: v.filePath) {
            reservedNew.remove(normalizeRoot(v.filePath))
        }

        var candidates: [Candidate] = []
        for video in videos {
            guard let rel = relativePath(under: old, fullPath: video.filePath) else { continue }
            let dest = join(root: neu, relative: rel)
            let destNorm = normalizeRoot(dest)

            let kind: MatchKind
            var found: Int64?
            if !fileExists(dest) {
                kind = .stillMissing
            } else if reservedNew.contains(destNorm), destNorm.caseInsensitiveCompare(normalizeRoot(video.filePath)) != .orderedSame {
                kind = .needsAttention(reason: "Another library clip already uses this path")
                found = fileSize(dest)
            } else {
                found = fileSize(dest)
                if let found, video.fileSize > 0, found != video.fileSize {
                    kind = .needsAttention(reason: "File size differs (library \(video.fileSize), disk \(found))")
                } else {
                    kind = .reconnect
                }
            }

            if kind != .stillMissing {
                reservedNew.insert(destNorm)
            }

            candidates.append(
                Candidate(
                    videoDatabaseId: video.databaseId,
                    oldPath: video.filePath,
                    newPath: dest,
                    relativePath: rel,
                    kind: kind,
                    expectedSize: video.fileSize > 0 ? video.fileSize : nil,
                    foundSize: found
                )
            )
        }

        candidates.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return Preview(oldRoot: old, newRoot: neu, candidates: candidates)
    }

    /// Paths that should be written on Apply.
    static func mappingsToApply(
        preview: Preview,
        includeNeedsAttention: Bool
    ) -> [(oldPath: String, newPath: String, videoDatabaseId: Int64?)] {
        preview.candidates.compactMap { c in
            switch c.kind {
            case .reconnect:
                return (c.oldPath, c.newPath, c.videoDatabaseId)
            case .needsAttention where includeNeedsAttention:
                return (c.oldPath, c.newPath, c.videoDatabaseId)
            case .needsAttention, .stillMissing:
                return nil
            }
        }
    }

    /// Remap a folder path that sits under `oldRoot` (data sources / excludes).
    static func remapFolderPath(_ path: String, oldRoot: String, newRoot: String) -> String? {
        guard let rel = relativePath(under: oldRoot, fullPath: path) else { return nil }
        return join(root: newRoot, relative: rel)
    }

    // MARK: - Find missing folder (orphan → parent folder remap)

    enum FindMissingFolderRootsError: Error, Equatable {
        case emptyPath
    }

    /// Derive Location A/B roots from an orphan library path + the folder the user located on disk.
    ///
    /// Remap scope is the orphan’s parent folder → the chosen folder (`oldRoot/rel` → `newRoot/rel`).
    /// Siblings rematch by basename under that folder; nested clips keep relative structure.
    static func rootsFromLocatedFolder(
        orphanPath: String,
        locatedFolder: String
    ) -> Result<(oldRoot: String, newRoot: String), FindMissingFolderRootsError> {
        let orphanRaw = orphanPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderRaw = locatedFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orphanRaw.isEmpty, !folderRaw.isEmpty else { return .failure(.emptyPath) }

        let orphan = normalizeRoot(orphanRaw)
        let folder = normalizeRoot(folderRaw)
        guard !orphan.isEmpty, !folder.isEmpty else { return .failure(.emptyPath) }

        let oldRoot = normalizeRoot(
            URL(fileURLWithPath: orphan).deletingLastPathComponent().path
        )
        guard !oldRoot.isEmpty else { return .failure(.emptyPath) }
        return .success((oldRoot: oldRoot, newRoot: folder))
    }

    // MARK: - Situational missing banner

    /// Cheap local classification for the Missing / focus banner (no telemetry).
    enum MissingBannerSituation: Equatable {
        /// Inferred shared root (or orphan parent) is not on disk.
        case parentGone(folderName: String)
        /// Parent folder exists; one or more children under it are missing.
        case parentPresent(missingCount: Int)
        /// Missing clips fan out across distinct parents with no single plausible root.
        case scattered
    }

    struct BannerCopy: Equatable {
        var title: String
        var body: String
        var cta: String
        var icon: String
    }

    /// Classify missing situation for banner copy.
    ///
    /// Prefer the focused orphan when provided; otherwise the Missing set.
    /// Ambiguous → prefer parentPresent over parentGone when the parent exists;
    /// prefer scattered only when multi-root scatter is clear.
    static func classifyMissingSituation(
        missingPaths: [String],
        focusPath: String? = nil,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> MissingBannerSituation {
        let paths = missingPaths.map(normalizeRoot).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return .parentPresent(missingCount: 0) }

        if let focusRaw = focusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !focusRaw.isEmpty
        {
            let focus = normalizeRoot(focusRaw)
            if paths.contains(where: { $0.caseInsensitiveCompare(focus) == .orderedSame }) {
                return classifyAroundParent(
                    of: focus,
                    allMissing: paths,
                    fileExists: fileExists
                )
            }
        }

        let parents = Set(
            paths.map {
                normalizeRoot(URL(fileURLWithPath: $0).deletingLastPathComponent().path)
            }
        )

        if let shared = inferSharedMissingRoot(missingPaths: paths, dataSourceRoots: []),
           isSelectableOldRoot(shared)
        {
            if fileExists(shared) {
                return .parentPresent(missingCount: paths.count)
            }
            let name = URL(fileURLWithPath: shared).lastPathComponent
            return .parentGone(folderName: name.isEmpty ? shared : name)
        }

        if parents.count >= 2 {
            return .scattered
        }

        if let onlyParent = parents.first {
            if fileExists(onlyParent) {
                return .parentPresent(missingCount: paths.count)
            }
            let name = URL(fileURLWithPath: onlyParent).lastPathComponent
            return .parentGone(folderName: name.isEmpty ? onlyParent : name)
        }

        return .scattered
    }

    private static func classifyAroundParent(
        of filePath: String,
        allMissing: [String],
        fileExists: (String) -> Bool
    ) -> MissingBannerSituation {
        let parent = normalizeRoot(
            URL(fileURLWithPath: filePath).deletingLastPathComponent().path
        )
        // Taxonomy from the focused orphan’s parent; count is always the full missing set.
        let totalMissing = max(allMissing.count, 1)
        if fileExists(parent) {
            return .parentPresent(missingCount: totalMissing)
        }
        let name = URL(fileURLWithPath: parent).lastPathComponent
        return .parentGone(folderName: name.isEmpty ? parent : name)
    }

    /// Exact customer-facing banner strings (Reconnect UX).
    /// `parentPresent` count is the **full library** missing set (same as Missing / Reconnect).
    static func bannerCopy(for situation: MissingBannerSituation) -> BannerCopy {
        switch situation {
        case .parentGone(let folderName):
            return BannerCopy(
                title: "Folder moved or missing",
                body: "Clips that lived under “\(folderName)” can’t be found. Point Skagway at that folder’s new location.",
                cta: "Reconnect…",
                icon: "folder.badge.questionmark"
            )
        case .parentPresent(let missingCount):
            let n = max(missingCount, 1)
            let body: String
            if n == 1 {
                body = "1 clip is missing. Locate where it moved."
            } else {
                body = "\(n) clips are missing. Locate where they moved."
            }
            return BannerCopy(
                title: "Some clips are missing",
                body: body,
                cta: "Reconnect…",
                icon: "doc.badge.ellipsis"
            )
        case .scattered:
            return BannerCopy(
                title: "Clips moved to different places",
                body: "Missing clips don’t share one new folder. Add destinations where they landed, then review matches.",
                cta: "Reconnect…",
                icon: "folder.badge.gearshape"
            )
        }
    }

    /// Placeholder while the full-library missing scan is still running.
    static var bannerCopyChecking: BannerCopy {
        BannerCopy(
            title: "Some clips are missing",
            body: "Checking…",
            cta: "Reconnect…",
            icon: "doc.badge.ellipsis"
        )
    }

    /// Kept for call-site compatibility; Reconnect UI is Destinations-only.
    enum ReconnectMode: String, Equatable, CaseIterable, Identifiable {
        case destinations

        var id: String { rawValue }

        var title: String { "Destinations" }

        static func suggested(for situation: MissingBannerSituation) -> ReconnectMode {
            _ = situation
            return .destinations
        }
    }

    // MARK: - Evidence Destinations (multi-destination basename match)

    struct IndexedFile: Equatable {
        var path: String
        var basename: String
        var size: Int64?
    }

    /// Bounded index of video files under a user-chosen Evidence Destination.
    struct DestinationIndex: Equatable {
        var root: String
        /// Lowercased basename → files found under this destination.
        var byBasename: [String: [IndexedFile]]

        var fileCount: Int { byBasename.values.reduce(0) { $0 + $1.count } }
    }

    private static let defaultVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm", "mpg", "mpeg",
        "3gp", "ts", "mts", "vob", "ogv", "divx", "dv", "m2ts", "mxf"
    ]

    /// Recursively index video files under `root` only (no volume-wide scan).
    static func indexEvidenceDestination(
        root: String,
        maxFiles: Int = 50_000,
        videoExtensions: Set<String> = defaultVideoExtensions,
        fileSize: (String) -> Int64? = { path in
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        }
    ) -> DestinationIndex {
        let rootNorm = normalizeRoot(root)
        guard !rootNorm.isEmpty else {
            return DestinationIndex(root: rootNorm, byBasename: [:])
        }

        var byBasename: [String: [IndexedFile]] = [:]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: rootNorm),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return DestinationIndex(root: rootNorm, byBasename: [:])
        }

        var counted = 0
        while let item = enumerator.nextObject() {
            if counted >= maxFiles { break }
            let url: URL
            if let u = item as? URL {
                url = u
            } else if let path = item as? String {
                url = URL(fileURLWithPath: path)
            } else {
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard videoExtensions.contains(ext) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if let isFile = values?.isRegularFile, !isFile { continue }
            let path = normalizeRoot(url.path)
            let base = url.lastPathComponent
            byBasename[base.lowercased(), default: []].append(
                IndexedFile(path: path, basename: base, size: fileSize(path))
            )
            counted += 1
        }
        return DestinationIndex(root: rootNorm, byBasename: byBasename)
    }

    /// Build a session preview: optional whole-folder relative remap, then basename match
    /// leftovers under Evidence Destinations.
    static func buildSessionPreview(
        videos: [(databaseId: Int64?, filePath: String, fileSize: Int64)],
        wholeFolder: (oldRoot: String, newRoot: String)?,
        destinationIndexes: [DestinationIndex],
        existingLibraryPaths: Set<String>,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        fileSize: (String) -> Int64? = { path in
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        }
    ) -> Preview {
        var reservedNew = Set(existingLibraryPaths.map(normalizeRoot))
        var byOldPath: [String: Candidate] = [:]

        if let pair = wholeFolder {
            let old = normalizeRoot(pair.oldRoot)
            let neu = normalizeRoot(pair.newRoot)
            for v in videos where isUnder(root: old, path: v.filePath) {
                reservedNew.remove(normalizeRoot(v.filePath))
            }
            let folderPreview = buildPreview(
                videos: videos,
                oldRoot: old,
                newRoot: neu,
                existingLibraryPaths: existingLibraryPaths,
                fileExists: fileExists,
                fileSize: fileSize
            )
            for c in folderPreview.candidates {
                byOldPath[normalizeRoot(c.oldPath)] = c
                if c.kind != .stillMissing {
                    reservedNew.insert(normalizeRoot(c.newPath))
                }
            }
        }

        // Basename match for leftovers (still missing or never covered by whole-folder).
        let coveredReady = Set(
            byOldPath.values
                .filter { $0.kind != .stillMissing }
                .map { normalizeRoot($0.oldPath) }
        )

        for video in videos {
            let oldNorm = normalizeRoot(video.filePath)
            if coveredReady.contains(oldNorm) { continue }

            let basename = URL(fileURLWithPath: video.filePath).lastPathComponent
            let key = basename.lowercased()
            var hits: [(destination: String, file: IndexedFile)] = []
            for index in destinationIndexes {
                if let files = index.byBasename[key] {
                    for file in files {
                        hits.append((index.root, file))
                    }
                }
            }
            // Nested destinations (B containing C) index the same file twice — collapse by
            // standardized path so one unique URL stays Ready, not “2 matches” of itself.
            hits = uniqueEvidenceHits(hits)

            let candidate: Candidate
            if hits.isEmpty {
                if let existing = byOldPath[oldNorm], existing.kind == .stillMissing {
                    continue
                }
                candidate = Candidate(
                    videoDatabaseId: video.databaseId,
                    oldPath: video.filePath,
                    newPath: video.filePath,
                    relativePath: basename,
                    kind: .stillMissing,
                    expectedSize: video.fileSize > 0 ? video.fileSize : nil,
                    foundSize: nil,
                    matchSource: destinationIndexes.first.map { .evidenceDestination(root: $0.root) } ?? .wholeFolder
                )
            } else if hits.count == 1, let hit = hits.first {
                let destNorm = normalizeRoot(hit.file.path)
                let found = hit.file.size ?? fileSize(destNorm)
                let kind: MatchKind
                if reservedNew.contains(destNorm),
                   destNorm.caseInsensitiveCompare(oldNorm) != .orderedSame
                {
                    kind = .needsAttention(reason: "Another library clip already uses this path")
                } else if let found, video.fileSize > 0, found != video.fileSize {
                    kind = .needsAttention(
                        reason: "File size differs (library \(video.fileSize), disk \(found))"
                    )
                } else {
                    kind = .reconnect
                }
                if kind != .stillMissing {
                    reservedNew.insert(destNorm)
                }
                candidate = Candidate(
                    videoDatabaseId: video.databaseId,
                    oldPath: video.filePath,
                    newPath: hit.file.path,
                    relativePath: basename,
                    kind: kind,
                    expectedSize: video.fileSize > 0 ? video.fileSize : nil,
                    foundSize: found,
                    matchSource: .evidenceDestination(root: hit.destination)
                )
            } else {
                // Distinct paths share this basename — propose first hit, flag Needs attention.
                let sortedHits = hits.sorted {
                    comparePathsByComponents($0.file.path, $1.file.path) == .orderedAscending
                }
                let hit = sortedHits[0]
                let destNorm = normalizeRoot(hit.file.path)
                let found = hit.file.size ?? fileSize(destNorm)
                let pathsPreview = sortedHits.prefix(3).map(\.file.path).joined(separator: "; ")
                let reason = "\(hits.count) matches for “\(basename)” — pick carefully (\(pathsPreview))"
                reservedNew.insert(destNorm)
                candidate = Candidate(
                    videoDatabaseId: video.databaseId,
                    oldPath: video.filePath,
                    newPath: hit.file.path,
                    relativePath: basename,
                    kind: .needsAttention(reason: reason),
                    expectedSize: video.fileSize > 0 ? video.fileSize : nil,
                    foundSize: found,
                    matchSource: .evidenceDestination(root: hit.destination)
                )
            }
            byOldPath[oldNorm] = candidate
        }

        var candidates = Array(byOldPath.values)
        candidates.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }

        let oldRoot = wholeFolder.map { normalizeRoot($0.oldRoot) } ?? ""
        let newRoot = wholeFolder.map { normalizeRoot($0.newRoot) } ?? ""
        return Preview(
            oldRoot: oldRoot,
            newRoot: newRoot,
            candidates: candidates,
            evidenceDestinations: destinationIndexes.map(\.root)
        )
    }

    /// Collapse basename hits that resolve to the same on-disk path (nested Evidence Destinations).
    /// Prefers the more specific destination root (longer path) when the same file appears twice.
    static func uniqueEvidenceHits(
        _ hits: [(destination: String, file: IndexedFile)]
    ) -> [(destination: String, file: IndexedFile)] {
        var bestByPath: [String: (destination: String, file: IndexedFile)] = [:]
        var order: [String] = []

        for hit in hits {
            let pathKey = normalizeRoot(hit.file.path).lowercased()
            if let existing = bestByPath[pathKey] {
                let existingRootLen = normalizeRoot(existing.destination).count
                let newRootLen = normalizeRoot(hit.destination).count
                // Same standardized path — keep the more nested destination root for grouping.
                if newRootLen > existingRootLen {
                    bestByPath[pathKey] = hit
                }
            } else {
                bestByPath[pathKey] = hit
                order.append(pathKey)
            }
        }

        return order.compactMap { bestByPath[$0] }
    }

    /// Group candidates for Destinations UI: Ready / Needs attention / Unmatched per destination.
    static func groupEvidenceCandidates(
        _ candidates: [Candidate]
    ) -> (
        byDestination: [(destination: String, ready: [Candidate], needsAttention: [Candidate])],
        unmatched: [Candidate]
    ) {
        var unmatched: [Candidate] = []
        var readyByDest: [String: [Candidate]] = [:]
        var attentionByDest: [String: [Candidate]] = [:]
        var destOrder: [String] = []

        func noteDest(_ dest: String) {
            if !destOrder.contains(where: { $0.caseInsensitiveCompare(dest) == .orderedSame }) {
                destOrder.append(dest)
            }
        }

        for c in candidates {
            switch c.kind {
            case .stillMissing:
                unmatched.append(c)
            case .reconnect:
                let dest = c.evidenceDestination ?? "(whole folder)"
                noteDest(dest)
                readyByDest[dest, default: []].append(c)
            case .needsAttention:
                let dest = c.evidenceDestination ?? "(whole folder)"
                noteDest(dest)
                attentionByDest[dest, default: []].append(c)
            }
        }

        let grouped = destOrder.map { dest in
            (destination: dest, ready: readyByDest[dest] ?? [], needsAttention: attentionByDest[dest] ?? [])
        }
        return (grouped, unmatched)
    }
}
