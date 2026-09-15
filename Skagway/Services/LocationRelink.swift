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

    // MARK: - Preview

    enum MatchKind: Equatable {
        /// New path exists and soft checks pass (or no metadata to check).
        case reconnect
        /// New path exists but size (or library collision) needs attention.
        case needsAttention(reason: String)
        /// Relative path not found under the new root.
        case stillMissing
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
    }

    struct Preview: Equatable {
        var oldRoot: String
        var newRoot: String
        var candidates: [Candidate]

        var reconnectCount: Int { candidates.filter { $0.kind == .reconnect }.count }
        var needsAttentionCount: Int {
            candidates.filter {
                if case .needsAttention = $0.kind { return true }
                return false
            }.count
        }
        var stillMissingCount: Int { candidates.filter { $0.kind == .stillMissing }.count }
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
}
