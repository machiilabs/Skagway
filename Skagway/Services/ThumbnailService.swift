import AppKit
import AVFoundation
import CryptoKit
import Foundation

private func withTimeout<T: Sendable>(seconds: Double, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}

/// Caps concurrent `AVAssetImageGenerator` work so 10k+ libraries don’t spawn unbounded AV decode pressure.
private actor ThumbnailGenerationGate {
    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        running += 1
    }

    func release() {
        running -= 1
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()
        }
    }
}

/// Dedicated scrub-hover decoder: reuses one generator per file, latest-wins cancellation, never
/// shares the grid/filmstrip generation gate (that queue was a major source of scrub lag).
private actor ScrubPreviewGenerator {
    private var path: String?
    private var generator: AVAssetImageGenerator?
    private var ticket = 0

    func image(url: URL, path: String, seconds: Double) async -> NSImage? {
        ticket += 1
        let myTicket = ticket

        let gen = ensureGenerator(url: url, path: path)
        // Drop any in-flight decode so a fast mouse move doesn’t wait on a stale time.
        gen.cancelAllCGImageGeneration()

        do {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let (cgImage, _) = try await gen.image(at: time)
            guard myTicket == ticket else { return nil }
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        } catch {
            return nil
        }
    }

    private func ensureGenerator(url: URL, path: String) -> AVAssetImageGenerator {
        if self.path == path, let generator {
            return generator
        }
        generator?.cancelAllCGImageGeneration()
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        // Preview card is 160×90 — keep decode tiny for speed.
        gen.maximumSize = CGSize(width: 180, height: 180)
        // Keyframe-only: much closer to YouTube sprite snappiness than exact-frame seeks.
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        generator = gen
        self.path = path
        return gen
    }
}

/// Disk + memory cache for thumbnails/filmstrips. **Not** an `actor`: fast `load*` calls must not wait behind
/// `generate*` work from hundreds of grid cells (that was causing multi‑second stalls in the detail pane).
final class ThumbnailService: @unchecked Sendable {
    /// On-disk root for this library session. Rebound after DB open via `setSessionCacheRoot`.
    private(set) var cacheDirectory: URL
    private let memoryCache = NSCache<NSString, NSImage>()
    /// Serializes cache directory mutations (migrate, bulk delete, clear).
    private let managementLock = NSLock()
    /// P0: bound concurrent AV thumbnail/filmstrip generation (grid + scanner + detail).
    private let generationGate = ThumbnailGenerationGate(maxConcurrent: 4)
    /// Scrub hover — isolated from `generationGate` so grid work can’t stall the timeline preview.
    private let scrubPreviewGenerator = ScrubPreviewGenerator()
    /// Coalesce multiple awaiters for the same path (grid scroll, scanner, detail).
    private let inflightLock = NSLock()
    private var inflightThumbnails: [String: Task<URL, Error>] = [:]
    private var inflightFilmstrips: [String: Task<NSImage, Error>] = [:]
    private var inflightStoryboards: [String: Task<NSImage, Error>] = [:]
    private var inflightDetailPreviews: [String: Task<URL, Error>] = [:]
    private let scrubPrefetchLock = NSLock()
    private var scrubPrefetchTask: Task<Void, Never>?

    var hasPendingThumbnails: Bool {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        return !inflightThumbnails.isEmpty
    }

    private static let filmstripCachePrefix = "_filmstrip"
    private static let storyboardCachePrefix = "_storyboard"
    private static let detailPreviewCachePrefix = "_detailPreview"
    private static let filmstripEpochKey = "Skagway.filmstripCacheEpoch"

    /// Bumped by Settings → Regenerate filmstrips so prior on-disk composites become unreachable
    /// without waiting on deleting thousands of cache files (see `invalidateAllFilmstrips()`).
    private var filmstripEpoch: Int

    /// Fixed cell footprint (points) used by `buildFilmstrip` for every composite. This is the
    /// layout contract that lets `filmstripGrid(in:)` recover rows/columns from a cached image,
    /// since per-video grid choices are not persisted anywhere else.
    static let filmstripCellSize = NSSize(width: 400, height: 225)

    /// Wall storyboard collage: fixed 2×3 frames baked into one card-sized JPEG
    /// (≈ poster disk cost, not six full-res stills). Aspect matches filmstrip cells (16:9 × 3/2).
    static let storyboardRows = 2
    static let storyboardColumns = 3
    static let storyboardCompositeSize = NSSize(width: 480, height: 180)

    /// Recover the rows×columns grid of a filmstrip composite from its point size.
    /// Works for both freshly built images and disk-cached JPEGs: the cache write path preserves
    /// DPI metadata, so `NSImage.size` stays in points (cell multiples) at any backing scale.
    /// Returns nil if the image is not a whole multiple of the cell footprint.
    static func filmstripGrid(in image: NSImage) -> (rows: Int, columns: Int)? {
        let columns = Int((image.size.width / filmstripCellSize.width).rounded())
        let rows = Int((image.size.height / filmstripCellSize.height).rounded())
        guard columns >= 1, rows >= 1,
              abs(image.size.width - CGFloat(columns) * filmstripCellSize.width) < 2,
              abs(image.size.height - CGFloat(rows) * filmstripCellSize.height) < 2
        else { return nil }
        return (rows, columns)
    }

    /// Presets for detail-pane JPEG long edge (Settings → Video; keep in sync with the picker there).
    static let detailPreviewLongEdgeChoices: [Int] = [480, 720, 1080, 1440, 2160]

    static func normalizedDetailLongEdge(_ value: Int) -> Int {
        if detailPreviewLongEdgeChoices.contains(value) { return value }
        return 1080
    }

    /// Default cache under `~/Library/Caches/Skagway/Skagway-cache` (Standard library home).
    static let cacheFolderName = ThumbnailCacheLocator.cacheFolderName
    static let legacyCacheFolderName = ThumbnailCacheLocator.legacyCacheFolderName

    static var standardCacheDirectory: URL {
        ThumbnailCacheLocator.standardSharedCacheDirectory
    }

    /// Co-located cache folder next to a custom library home (`…/Skagway-cache`).
    static func coLocatedCacheDirectory(inLibraryHome folder: URL) -> URL {
        if let existing = ThumbnailCacheLocator.resolveExistingCacheDirectory(inParent: folder) {
            return existing
        }
        return folder.appendingPathComponent(ThumbnailCacheLocator.cacheFolderName, isDirectory: true)
    }

    /// Prefer `Skagway-cache`, then `.Skagway-cache`, then legacy `thumbnails`.
    static func resolveCacheDirectory(inParent parent: URL) -> URL {
        if let existing = ThumbnailCacheLocator.resolveExistingCacheDirectory(inParent: parent) {
            return existing
        }
        return parent.appendingPathComponent(ThumbnailCacheLocator.cacheFolderName, isDirectory: true)
    }

    /// Legacy fallback while no library is open yet. Live roots come from `library_cache` via
    /// `setSessionCacheRoot` after DB open.
    static func resolvedCacheDirectory() -> URL {
        let dir = standardCacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(cacheDirectory override: URL? = nil) {
        let dir = override ?? Self.resolvedCacheDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheDirectory = dir
        memoryCache.countLimit = 5000
        filmstripEpoch = UserDefaults.standard.object(forKey: Self.filmstripEpochKey) as? Int ?? 0
    }

    /// Point this process at the open library’s on-disk cache (does not clear memory cache).
    func setSessionCacheRoot(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cacheDirectory = url
        _ = url.startAccessingSecurityScopedResource()
    }

    private func pathHashString(for filePath: String) -> String {
        let hash = SHA256.hash(data: Data(filePath.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    func thumbnailURL(for filePath: String) -> URL {
        cacheDirectory.appendingPathComponent("\(pathHashString(for: filePath)).jpg")
    }

    func filmstripURL(for filePath: String) -> URL {
        let hash = pathHashString(for: filePath)
        // Epoch 0 keeps the legacy unversioned filename so existing caches keep working until
        // the first Settings → Regenerate (which advances the epoch).
        if filmstripEpoch == 0 {
            return cacheDirectory.appendingPathComponent("\(hash)_filmstrip.jpg")
        }
        return cacheDirectory.appendingPathComponent("\(hash)_filmstrip_e\(filmstripEpoch).jpg")
    }

    /// Card-sized 2×3 collage for Wall storyboard mode (`{hash}_storyboard.jpg`).
    func storyboardURL(for filePath: String) -> URL {
        let hash = pathHashString(for: filePath)
        return cacheDirectory.appendingPathComponent("\(hash)_storyboard.jpg")
    }

    private func filmstripMemoryKey(for filePath: String) -> NSString {
        (filePath + Self.filmstripCachePrefix + "_e\(filmstripEpoch)") as NSString
    }

    private func storyboardMemoryKey(for filePath: String) -> NSString {
        (filePath + Self.storyboardCachePrefix) as NSString
    }

    /// Disk path for hi-res detail still: `<hash>_detail_<longEdge>.jpg`.
    func detailPreviewURL(for filePath: String, longEdge: Int) -> URL {
        let edge = Self.normalizedDetailLongEdge(longEdge)
        let h = pathHashString(for: filePath)
        return cacheDirectory.appendingPathComponent("\(h)_detail_\(edge).jpg")
    }

    /// Pre–width-suffix cache file (`<hash>_detail.jpg`, treated as 1080 long edge when reading).
    private func legacyDetailPreviewURL(for filePath: String) -> URL {
        let h = pathHashString(for: filePath)
        return cacheDirectory.appendingPathComponent("\(h)_detail.jpg")
    }

    private var bookmarkStillsDirectory: URL {
        cacheDirectory.appendingPathComponent("bookmarks", isDirectory: true)
    }

    /// Dedicated still for a video bookmark — never collides with library/detail thumb keys.
    func bookmarkStillURL(videoId: Int64, bookmarkId: Int64) -> URL {
        bookmarkStillsDirectory.appendingPathComponent("\(videoId)_\(bookmarkId).jpg")
    }

    private func detailPreviewMemoryKey(filePath: String, longEdge: Int) -> NSString {
        let edge = Self.normalizedDetailLongEdge(longEdge)
        return (filePath + Self.detailPreviewCachePrefix + "_\(edge)") as NSString
    }

    private func inflightDetailPreviewKey(filePath: String, longEdge: Int) -> String {
        "\(filePath)\u{1e}\(Self.normalizedDetailLongEdge(longEdge))"
    }

    // MARK: - Fast path (memory + disk; never waits on AV / generation)

    /// Thread-safe: `NSCache` is thread-safe; disk read is local to this call.
    func loadThumbnail(for filePath: String) -> NSImage? {
        let key = filePath as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }
        let url = thumbnailURL(for: filePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url)
        else { return nil }
        memoryCache.setObject(image, forKey: key)
        return image
    }

    func loadFilmstrip(for filePath: String) -> NSImage? {
        let memKey = filmstripMemoryKey(for: filePath)
        if let cached = memoryCache.object(forKey: memKey) {
            return cached
        }
        let url = filmstripURL(for: filePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url)
        else { return nil }
        memoryCache.setObject(image, forKey: memKey)
        return image
    }

    /// Sync load of the Wall storyboard collage (memory → disk). Never waits on AV.
    func loadStoryboard(for filePath: String) -> NSImage? {
        let memKey = storyboardMemoryKey(for: filePath)
        if let cached = memoryCache.object(forKey: memKey) {
            return cached
        }
        let url = storyboardURL(for: filePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url)
        else { return nil }
        memoryCache.setObject(image, forKey: memKey)
        return image
    }

    /// Hi-res detail preview on disk (`<hash>_detail_<longEdge>.jpg`) + `NSCache` keyed by path and long edge.
    func loadDetailPreview(for filePath: String, longEdge: Int) -> NSImage? {
        let edge = Self.normalizedDetailLongEdge(longEdge)
        let memKey = detailPreviewMemoryKey(filePath: filePath, longEdge: edge)
        if let cached = memoryCache.object(forKey: memKey) {
            return cached
        }
        var urls = [detailPreviewURL(for: filePath, longEdge: edge)]
        if edge == 1080 {
            let legacy = legacyDetailPreviewURL(for: filePath)
            if legacy.path != urls[0].path { urls.append(legacy) }
        }
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path),
                  let image = NSImage(contentsOf: url)
            else { continue }
            memoryCache.setObject(image, forKey: memKey)
            return image
        }
        return nil
    }

    // MARK: - Generation (async; can run concurrently for different files)

    func generateThumbnail(for video: Video) async throws -> URL {
        let cacheURL = thumbnailURL(for: video.filePath)

        if FileManager.default.fileExists(atPath: cacheURL.path) {
            if let image = NSImage(contentsOf: cacheURL) {
                memoryCache.setObject(image, forKey: video.filePath as NSString)
            }
            return cacheURL
        }

        return try await coalescedThumbnailGeneration(for: video, filePath: video.filePath)
    }

    /// One in-flight generation per `filePath`; multiple awaiters share the same `Task`. AV work runs under a global concurrency cap.
    private func coalescedThumbnailGeneration(for video: Video, filePath: String) async throws -> URL {
        inflightLock.lock()
        if let existing = inflightThumbnails[filePath] {
            inflightLock.unlock()
            return try await existing.value
        }
        let task = Task<URL, Error> {
            await self.generationGate.acquire()
            do {
                let url = try await self.generateThumbnailWork(for: video)
                await self.generationGate.release()
                return url
            } catch {
                await self.generationGate.release()
                throw error
            }
        }
        inflightThumbnails[filePath] = task
        inflightLock.unlock()
        defer {
            inflightLock.lock()
            inflightThumbnails.removeValue(forKey: filePath)
            inflightLock.unlock()
        }
        return try await task.value
    }

    private func generateThumbnailWork(for video: Video) async throws -> URL {
        let cacheURL = thumbnailURL(for: video.filePath)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            if let image = NSImage(contentsOf: cacheURL) {
                memoryCache.setObject(image, forKey: video.filePath as NSString)
            }
            return cacheURL
        }

        let url = video.url
        let nsImage: NSImage = try await withTimeout(seconds: 10) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)

            var targetSeconds: Double = 5.0
            if let d = try? await asset.load(.duration) {
                let total = CMTimeGetSeconds(d)
                if total.isFinite && total > 0 {
                    targetSeconds = min(total * 0.1, 30)
                }
            }
            let time = CMTime(seconds: targetSeconds, preferredTimescale: 600)
            let (cgImage, _) = try await generator.image(at: time)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.75]
              )
        else {
            throw ThumbnailError.encodingFailed
        }

        try jpegData.write(to: cacheURL)
        memoryCache.setObject(nsImage, forKey: video.filePath as NSString)
        return cacheURL
    }

    // MARK: - Detail preview (disk + memory; long edge from settings)

    /// Loads cached detail JPEG from disk/memory, or generates once and persists under the active Skagway-cache directory.
    func detailPreviewImage(for video: Video, longEdge: Int) async -> NSImage? {
        let path = video.filePath
        let edge = Self.normalizedDetailLongEdge(longEdge)
        if let img = loadDetailPreview(for: path, longEdge: edge) { return img }
        guard (try? await generateDetailPreview(for: video, longEdge: edge)) != nil else { return nil }
        return loadDetailPreview(for: path, longEdge: edge)
    }

    func generateDetailPreview(for video: Video, longEdge: Int) async throws -> URL {
        let edge = Self.normalizedDetailLongEdge(longEdge)
        let cacheURL = detailPreviewURL(for: video.filePath, longEdge: edge)
        let memKey = detailPreviewMemoryKey(filePath: video.filePath, longEdge: edge)

        if FileManager.default.fileExists(atPath: cacheURL.path) {
            if let image = NSImage(contentsOf: cacheURL) {
                memoryCache.setObject(image, forKey: memKey)
            }
            return cacheURL
        }

        if edge == 1080 {
            let legacyURL = legacyDetailPreviewURL(for: video.filePath)
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                if let image = NSImage(contentsOf: legacyURL) {
                    memoryCache.setObject(image, forKey: memKey)
                }
                return legacyURL
            }
        }

        return try await coalescedDetailPreviewGeneration(for: video, filePath: video.filePath, longEdge: edge)
    }

    private func coalescedDetailPreviewGeneration(for video: Video, filePath: String, longEdge: Int) async throws -> URL {
        let coalesceKey = inflightDetailPreviewKey(filePath: filePath, longEdge: longEdge)
        inflightLock.lock()
        if let existing = inflightDetailPreviews[coalesceKey] {
            inflightLock.unlock()
            return try await existing.value
        }
        let task = Task<URL, Error> {
            await self.generationGate.acquire()
            do {
                let url = try await self.generateDetailPreviewWork(for: video, longEdge: longEdge)
                await self.generationGate.release()
                return url
            } catch {
                await self.generationGate.release()
                throw error
            }
        }
        inflightDetailPreviews[coalesceKey] = task
        inflightLock.unlock()
        defer {
            inflightLock.lock()
            inflightDetailPreviews.removeValue(forKey: coalesceKey)
            inflightLock.unlock()
        }
        return try await task.value
    }

    private func generateDetailPreviewWork(for video: Video, longEdge: Int) async throws -> URL {
        let edge = Self.normalizedDetailLongEdge(longEdge)
        let cacheURL = detailPreviewURL(for: video.filePath, longEdge: edge)
        let memKey = detailPreviewMemoryKey(filePath: video.filePath, longEdge: edge)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            if let image = NSImage(contentsOf: cacheURL) {
                memoryCache.setObject(image, forKey: memKey)
            }
            return cacheURL
        }

        if edge == 1080 {
            let legacyURL = legacyDetailPreviewURL(for: video.filePath)
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                if let image = NSImage(contentsOf: legacyURL) {
                    memoryCache.setObject(image, forKey: memKey)
                }
                return legacyURL
            }
        }

        let url = video.url
        let dim = CGFloat(edge)
        let nsImage: NSImage = try await withTimeout(seconds: 15) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: dim, height: dim)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)

            var targetSeconds: Double = 5.0
            if let d = try? await asset.load(.duration) {
                let total = CMTimeGetSeconds(d)
                if total.isFinite && total > 0 {
                    targetSeconds = min(total * 0.1, 30)
                }
            }
            let time = CMTime(seconds: targetSeconds, preferredTimescale: 600)
            let (cgImage, _) = try await generator.image(at: time)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.82]
              )
        else {
            throw ThumbnailError.encodingFailed
        }

        try jpegData.write(to: cacheURL)
        memoryCache.setObject(nsImage, forKey: memKey)
        return cacheURL
    }

    func generateFilmstrip(for video: Video, rows: Int = 2, columns: Int = 5) async throws -> NSImage {
        let cacheURL = filmstripURL(for: video.filePath)
        let memKey = filmstripMemoryKey(for: video.filePath)

        // Any cached composite wins (including per-video Modify Filmstrip overrides whose
        // grid may differ from the current Settings default).
        if let cached = memoryCache.object(forKey: memKey) {
            return cached
        }
        if FileManager.default.fileExists(atPath: cacheURL.path),
           let image = NSImage(contentsOf: cacheURL)
        {
            memoryCache.setObject(image, forKey: memKey)
            return image
        }

        return try await coalescedFilmstrip(for: video, rows: rows, columns: columns)
    }

    func regenerateFilmstrip(for video: Video, rows: Int, columns: Int) async throws -> NSImage {
        cancelInflightFilmstrips(for: video.filePath)
        let cacheURL = filmstripURL(for: video.filePath)
        let memKey = filmstripMemoryKey(for: video.filePath)
        try? FileManager.default.removeItem(at: cacheURL)
        memoryCache.removeObject(forKey: memKey)
        return try await runFilmstripBuildWithGate(for: video, rows: rows, columns: columns)
    }

    /// Drop any in-flight filmstrip builds for this path so a slower older layout cannot
    /// overwrite a newer `regenerateFilmstrip` / different-size generation.
    private func cancelInflightFilmstrips(for filePath: String) {
        let prefix = "\(filePath)\u{1e}fs\u{1e}"
        inflightLock.lock()
        let keys = inflightFilmstrips.keys.filter { $0.hasPrefix(prefix) }
        let tasks = keys.compactMap { inflightFilmstrips.removeValue(forKey: $0) }
        inflightLock.unlock()
        for task in tasks {
            task.cancel()
        }
    }

    private func filmstripInflightKey(filePath: String, rows: Int, columns: Int) -> String {
        "\(filePath)\u{1e}fs\u{1e}\(rows)x\(columns)"
    }

    private func coalescedFilmstrip(for video: Video, rows: Int, columns: Int) async throws -> NSImage {
        let key = filmstripInflightKey(filePath: video.filePath, rows: rows, columns: columns)
        inflightLock.lock()
        if let existing = inflightFilmstrips[key] {
            inflightLock.unlock()
            return try await existing.value
        }
        let task = Task<NSImage, Error> {
            await self.generationGate.acquire()
            do {
                let image = try await self.buildFilmstrip(for: video, rows: rows, columns: columns)
                await self.generationGate.release()
                return image
            } catch {
                await self.generationGate.release()
                throw error
            }
        }
        inflightFilmstrips[key] = task
        inflightLock.unlock()
        defer {
            inflightLock.lock()
            inflightFilmstrips.removeValue(forKey: key)
            inflightLock.unlock()
        }
        return try await task.value
    }

    private func runFilmstripBuildWithGate(for video: Video, rows: Int, columns: Int) async throws -> NSImage {
        await generationGate.acquire()
        do {
            let image = try await buildFilmstrip(for: video, rows: rows, columns: columns)
            await generationGate.release()
            return image
        } catch {
            await generationGate.release()
            throw error
        }
    }

    private func buildFilmstrip(for video: Video, rows: Int, columns: Int) async throws -> NSImage {
        let cacheURL = filmstripURL(for: video.filePath)
        let memKey = filmstripMemoryKey(for: video.filePath)
        let totalFrames = rows * columns
        let url = video.url

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ThumbnailError.fileNotFound
        }

        let frames: [CGImage] = try await withTimeout(seconds: 30) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let totalSeconds = CMTimeGetSeconds(duration)

            guard totalSeconds.isFinite, totalSeconds > 2.0 else {
                throw ThumbnailError.generationFailed
            }

            let fractions = (1...totalFrames).map { Double($0) / Double(totalFrames + 1) }
            let times = fractions.map { CMTime(seconds: totalSeconds * $0, preferredTimescale: 600) }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

            var result: [CGImage] = []
            for time in times {
                try Task.checkCancellation()
                if let (cgImage, _) = try? await generator.image(at: time) {
                    result.append(cgImage)
                }
            }
            return result
        }

        guard frames.count == totalFrames else {
            throw ThumbnailError.generationFailed
        }

        let cellWidth = Self.filmstripCellSize.width
        let cellHeight = Self.filmstripCellSize.height
        let compositeWidth = cellWidth * CGFloat(columns)
        let compositeHeight = cellHeight * CGFloat(rows)

        let compositeImage = NSImage(size: NSSize(width: compositeWidth, height: compositeHeight))
        compositeImage.lockFocus()
        NSColor.black.setFill()
        for (index, cgImage) in frames.enumerated() {
            let col = index % columns
            let row = index / columns
            let cellX = CGFloat(col) * cellWidth
            let cellY = compositeHeight - CGFloat(row + 1) * cellHeight

            let frameW = CGFloat(cgImage.width)
            let frameH = CGFloat(cgImage.height)
            let scale = min(cellWidth / frameW, cellHeight / frameH)
            let drawW = frameW * scale
            let drawH = frameH * scale
            let drawX = cellX + (cellWidth - drawW) / 2
            let drawY = cellY + (cellHeight - drawH) / 2

            NSRect(x: cellX, y: cellY, width: cellWidth, height: cellHeight).fill()
            let frameImage = NSImage(cgImage: cgImage, size: NSSize(width: frameW, height: frameH))
            frameImage.draw(in: NSRect(x: drawX, y: drawY, width: drawW, height: drawH))
        }
        compositeImage.unlockFocus()

        guard let tiffData = compositeImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else {
            throw ThumbnailError.encodingFailed
        }

        try Task.checkCancellation()
        try jpegData.write(to: cacheURL)
        memoryCache.setObject(compositeImage, forKey: memKey)
        return compositeImage
    }

    // MARK: - Storyboard (Wall 2×3 card-sized collage)

    /// Load or build the Wall storyboard: one JPEG at `storyboardCompositeSize` with 2×3 frames.
    /// Prefers baking from an existing filmstrip when it has ≥2 rows and ≥3 columns; otherwise
    /// samples six frames from the video (same gate/coalesce pattern as filmstrips).
    func generateStoryboard(for video: Video) async throws -> NSImage {
        let memKey = storyboardMemoryKey(for: video.filePath)
        if let cached = memoryCache.object(forKey: memKey) {
            return cached
        }
        let cacheURL = storyboardURL(for: video.filePath)
        if FileManager.default.fileExists(atPath: cacheURL.path),
           let image = NSImage(contentsOf: cacheURL)
        {
            memoryCache.setObject(image, forKey: memKey)
            return image
        }

        if let filmstrip = loadFilmstrip(for: video.filePath),
           let baked = bakeStoryboard(fromFilmstrip: filmstrip)
        {
            try storeStoryboard(baked, for: video.filePath)
            return baked
        }

        return try await coalescedStoryboard(for: video)
    }

    private func storyboardInflightKey(filePath: String) -> String {
        "\(filePath)\u{1e}sb\u{1e}2x3"
    }

    private func coalescedStoryboard(for video: Video) async throws -> NSImage {
        let key = storyboardInflightKey(filePath: video.filePath)
        inflightLock.lock()
        if let existing = inflightStoryboards[key] {
            inflightLock.unlock()
            return try await existing.value
        }
        let task = Task<NSImage, Error> {
            await self.generationGate.acquire()
            do {
                let image = try await self.buildStoryboard(for: video)
                await self.generationGate.release()
                return image
            } catch {
                await self.generationGate.release()
                throw error
            }
        }
        inflightStoryboards[key] = task
        inflightLock.unlock()
        defer {
            inflightLock.lock()
            inflightStoryboards.removeValue(forKey: key)
            inflightLock.unlock()
        }
        return try await task.value
    }

    /// Downscale (and optionally crop) an inspector filmstrip into the card-sized 2×3 collage.
    /// Requires at least 2 rows and 3 columns so we can take the top-left 2×3 block.
    func bakeStoryboard(fromFilmstrip filmstrip: NSImage) -> NSImage? {
        guard let grid = Self.filmstripGrid(in: filmstrip),
              grid.rows >= Self.storyboardRows,
              grid.columns >= Self.storyboardColumns
        else { return nil }

        let srcW = Self.filmstripCellSize.width * CGFloat(Self.storyboardColumns)
        let srcH = Self.filmstripCellSize.height * CGFloat(Self.storyboardRows)
        // NSImage is flipped relative to CG when drawing; take top-left cells in image coords
        // (row 0 is at the top of the composite = high y in AppKit lockFocus space).
        let sourceRect = NSRect(
            x: 0,
            y: filmstrip.size.height - srcH,
            width: srcW,
            height: srcH
        )
        let destSize = Self.storyboardCompositeSize
        let out = NSImage(size: destSize)
        out.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: destSize).fill()
        filmstrip.draw(
            in: NSRect(origin: .zero, size: destSize),
            from: sourceRect,
            operation: .copy,
            fraction: 1.0
        )
        out.unlockFocus()
        return out
    }

    private func buildStoryboard(for video: Video) async throws -> NSImage {
        let rows = Self.storyboardRows
        let columns = Self.storyboardColumns
        let totalFrames = rows * columns
        let url = video.url

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ThumbnailError.fileNotFound
        }

        // Prefer an inspector filmstrip that appeared while we waited on the gate.
        if let filmstrip = loadFilmstrip(for: video.filePath),
           let baked = bakeStoryboard(fromFilmstrip: filmstrip)
        {
            try storeStoryboard(baked, for: video.filePath)
            return baked
        }

        let frames: [CGImage] = try await withTimeout(seconds: 30) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let totalSeconds = CMTimeGetSeconds(duration)

            guard totalSeconds.isFinite, totalSeconds > 2.0 else {
                throw ThumbnailError.generationFailed
            }

            let fractions = (1...totalFrames).map { Double($0) / Double(totalFrames + 1) }
            let times = fractions.map { CMTime(seconds: totalSeconds * $0, preferredTimescale: 600) }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // Modest decode size — final collage is card-sized (~480×180).
            generator.maximumSize = CGSize(width: 240, height: 240)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

            var result: [CGImage] = []
            for time in times {
                try Task.checkCancellation()
                if let (cgImage, _) = try? await generator.image(at: time) {
                    result.append(cgImage)
                }
            }
            return result
        }

        guard frames.count == totalFrames else {
            throw ThumbnailError.generationFailed
        }

        let destSize = Self.storyboardCompositeSize
        let cellWidth = destSize.width / CGFloat(columns)
        let cellHeight = destSize.height / CGFloat(rows)

        let composite = NSImage(size: destSize)
        composite.lockFocus()
        NSColor.black.setFill()
        for (index, cgImage) in frames.enumerated() {
            let col = index % columns
            let row = index / columns
            let cellX = CGFloat(col) * cellWidth
            let cellY = destSize.height - CGFloat(row + 1) * cellHeight

            let frameW = CGFloat(cgImage.width)
            let frameH = CGFloat(cgImage.height)
            let scale = min(cellWidth / frameW, cellHeight / frameH)
            let drawW = frameW * scale
            let drawH = frameH * scale
            let drawX = cellX + (cellWidth - drawW) / 2
            let drawY = cellY + (cellHeight - drawH) / 2

            NSRect(x: cellX, y: cellY, width: cellWidth, height: cellHeight).fill()
            let frameImage = NSImage(cgImage: cgImage, size: NSSize(width: frameW, height: frameH))
            frameImage.draw(in: NSRect(x: drawX, y: drawY, width: drawW, height: drawH))
        }
        composite.unlockFocus()

        try storeStoryboard(composite, for: video.filePath)
        return composite
    }

    private func storeStoryboard(_ image: NSImage, for filePath: String) throws {
        let cacheURL = storyboardURL(for: filePath)
        let memKey = storyboardMemoryKey(for: filePath)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        else {
            throw ThumbnailError.encodingFailed
        }
        try Task.checkCancellation()
        try jpegData.write(to: cacheURL)
        memoryCache.setObject(image, forKey: memKey)
    }

    /// Regenerate the thumbnail *and* the 720pt detail-preview still — together, at the same fresh
    /// random position between 10% and 90% of the video's duration — replacing whatever's cached.
    /// Both need regenerating: the Curated Wall grid card and Inspector hero actually display the
    /// *detail preview*, using the small thumbnail only as a fast first paint, so regenerating just
    /// the thumbnail wouldn't change what's visible there. Clears every cached detail-preview size
    /// for this file so nothing stale can be served under a different long-edge setting.
    /// Used by the "Regenerate Thumbnail" context-menu action when the auto-picked frame (10% in,
    /// capped at 30s) looks bad — e.g. a black frame, title card, or blurry transition.
    func regenerateThumbnail(for video: Video) async throws -> URL {
        await generationGate.acquire()
        do {
            let url = try await performRegenerateThumbnail(for: video)
            await generationGate.release()
            return url
        } catch {
            await generationGate.release()
            throw error
        }
    }

    private func performRegenerateThumbnail(for video: Video) async throws -> URL {
        let filePath = video.filePath
        let asset = AVURLAsset(url: video.url)
        var targetSeconds = 5.0
        if let d = try? await asset.load(.duration) {
            let total = CMTimeGetSeconds(d)
            if total.isFinite, total > 0 {
                targetSeconds = total * Double.random(in: 0.1...0.9)
            }
        }

        let thumbURL = thumbnailURL(for: filePath)
        clearCachedStills(filePath: filePath)

        try await writeStill(
            for: video, atSeconds: targetSeconds, maxDimension: 400,
            compressionFactor: 0.75, cacheURL: thumbURL,
            memoryKey: filePath as NSString, timeout: 10
        )
        try await writeStill(
            for: video, atSeconds: targetSeconds, maxDimension: 720,
            compressionFactor: 0.82, cacheURL: detailPreviewURL(for: filePath, longEdge: 720),
            memoryKey: detailPreviewMemoryKey(filePath: filePath, longEdge: 720), timeout: 15
        )
        return thumbURL
    }

    /// Capture the exact frame at `atSeconds` (the current playback position) and set it as both the
    /// small library thumbnail and the 720pt detail-preview still, replacing whatever was cached.
    /// Unlike `regenerateThumbnail` (random position, 3s tolerance — "close enough" for an auto pick),
    /// this uses zero tolerance so the captured frame is exactly the one on screen, matching the
    /// precedent in `InlinePlaybackController.start(video:at:)` for filmstrip-click seeks. The "pro"
    /// precise-control counterpart to "Regenerate Thumbnail".
    func captureCurrentFrameAsThumbnail(for video: Video, atSeconds seconds: Double) async throws -> URL {
        await generationGate.acquire()
        do {
            let url = try await performCaptureCurrentFrame(for: video, atSeconds: seconds)
            await generationGate.release()
            return url
        } catch {
            await generationGate.release()
            throw error
        }
    }

    private func performCaptureCurrentFrame(for video: Video, atSeconds seconds: Double) async throws -> URL {
        let filePath = video.filePath
        clearCachedStills(filePath: filePath)

        let thumbURL = thumbnailURL(for: filePath)
        try await writeStill(
            for: video, atSeconds: seconds, maxDimension: 400,
            compressionFactor: 0.75, cacheURL: thumbURL,
            memoryKey: filePath as NSString, timeout: 10, tolerance: .zero
        )
        try await writeStill(
            for: video, atSeconds: seconds, maxDimension: 720,
            compressionFactor: 0.82, cacheURL: detailPreviewURL(for: filePath, longEdge: 720),
            memoryKey: detailPreviewMemoryKey(filePath: filePath, longEdge: 720), timeout: 15, tolerance: .zero
        )
        return thumbURL
    }

    /// Replace the library poster (grid thumb + 720pt detail still) with a user-chosen image.
    /// Does not touch the filmstrip. Same cache keys as frame capture so UI refresh paths stay unchanged.
    func setPoster(fromImageURL imageURL: URL, for video: Video) async throws -> URL {
        await generationGate.acquire()
        do {
            let url = try await performSetPoster(fromImageURL: imageURL, for: video)
            await generationGate.release()
            return url
        } catch {
            await generationGate.release()
            throw error
        }
    }

    private func performSetPoster(fromImageURL imageURL: URL, for video: Video) async throws -> URL {
        let accessing = imageURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { imageURL.stopAccessingSecurityScopedResource() }
        }
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw ThumbnailError.fileNotFound
        }
        guard let source = NSImage(contentsOf: imageURL) else {
            throw ThumbnailError.generationFailed
        }

        let filePath = video.filePath
        clearCachedStills(filePath: filePath)

        let thumbURL = thumbnailURL(for: filePath)
        try writeImageStill(
            source,
            maxDimension: 400,
            compressionFactor: 0.75,
            cacheURL: thumbURL,
            memoryKey: filePath as NSString
        )
        try writeImageStill(
            source,
            maxDimension: 720,
            compressionFactor: 0.82,
            cacheURL: detailPreviewURL(for: filePath, longEdge: 720),
            memoryKey: detailPreviewMemoryKey(filePath: filePath, longEdge: 720)
        )
        return thumbURL
    }

    /// JPEG-encode a scaled copy of `source` into the thumbnail cache (poster path, not AV frame).
    private func writeImageStill(
        _ source: NSImage,
        maxDimension: CGFloat,
        compressionFactor: CGFloat,
        cacheURL: URL,
        memoryKey: NSString
    ) throws {
        let scaled = Self.scaledImage(source, maxDimension: maxDimension)
        guard let tiffData = scaled.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
        else {
            throw ThumbnailError.encodingFailed
        }
        try jpegData.write(to: cacheURL)
        memoryCache.setObject(scaled, forKey: memoryKey)
    }

    private static func scaledImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return image }
        let width = CGFloat(rep.pixelsWide)
        let height = CGFloat(rep.pixelsHigh)
        let longest = max(width, height)
        guard longest > maxDimension, longest > 0 else {
            if let cgImage = rep.cgImage {
                return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
            }
            return image
        }
        let scale = maxDimension / longest
        let targetW = max(1, Int((width * scale).rounded()))
        let targetH = max(1, Int((height * scale).rounded()))
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetW,
            pixelsHigh: targetH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
            from: NSRect(x: 0, y: 0, width: width, height: height),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: NSSize(width: targetW, height: targetH))
        result.addRepresentation(out)
        return result
    }

    /// Capture a frame for a bookmark still. Does **not** touch library/detail thumbnail caches.
    func captureBookmarkStill(
        for video: Video,
        atSeconds seconds: Double,
        videoId: Int64,
        bookmarkId: Int64
    ) async throws -> URL {
        await generationGate.acquire()
        do {
            let url = try await performCaptureBookmarkStill(
                for: video, atSeconds: seconds, videoId: videoId, bookmarkId: bookmarkId
            )
            await generationGate.release()
            return url
        } catch {
            await generationGate.release()
            throw error
        }
    }

    private func performCaptureBookmarkStill(
        for video: Video,
        atSeconds seconds: Double,
        videoId: Int64,
        bookmarkId: Int64
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: bookmarkStillsDirectory, withIntermediateDirectories: true)
        let cacheURL = bookmarkStillURL(videoId: videoId, bookmarkId: bookmarkId)
        let memoryKey = "bookmark:\(videoId):\(bookmarkId)" as NSString
        try await writeStill(
            for: video, atSeconds: seconds, maxDimension: 320,
            compressionFactor: 0.78, cacheURL: cacheURL,
            memoryKey: memoryKey, timeout: 10, tolerance: .zero
        )
        return cacheURL
    }

    func deleteBookmarkStill(at path: String?) {
        guard let path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    func deleteBookmarkStill(videoId: Int64, bookmarkId: Int64) {
        try? FileManager.default.removeItem(at: bookmarkStillURL(videoId: videoId, bookmarkId: bookmarkId))
    }

    /// Scrub timeline quantization (~2 frames/sec). Coarser than exact playhead → hotter memory cache
    /// and fewer decodes while the pointer moves (YouTube sprite sheets are often ~1s or coarser).
    private static let scrubPreviewStepSeconds: Double = 0.5

    private static func quantizeScrubSeconds(_ seconds: Double) -> Double {
        let step = scrubPreviewStepSeconds
        return (max(0, seconds) / step).rounded() * step
    }

    private static func scrubPreviewCacheKey(filePath: String, quantizedSeconds: Double) -> NSString {
        "scrubPreview:\(filePath):\(String(format: "%.2f", quantizedSeconds))" as NSString
    }

    /// Synchronous cache peek for instant UI paint (no debounce / no await).
    func cachedScrubPreviewImage(for video: Video, atSeconds seconds: Double) -> NSImage? {
        let quantized = Self.quantizeScrubSeconds(seconds)
        return memoryCache.object(forKey: Self.scrubPreviewCacheKey(filePath: video.filePath, quantizedSeconds: quantized))
    }

    /// Lightweight still for scrubber hover preview. Memory-cached; not written to disk.
    /// Bypasses the shared thumbnail gate, reuses a warm generator, and prefetches neighbors.
    func scrubPreviewImage(for video: Video, atSeconds seconds: Double) async -> NSImage? {
        await scrubPreviewImage(for: video, atSeconds: seconds, prefetchNeighbors: true)
    }

    private func scrubPreviewImage(
        for video: Video,
        atSeconds seconds: Double,
        prefetchNeighbors: Bool
    ) async -> NSImage? {
        let quantized = Self.quantizeScrubSeconds(seconds)
        let key = Self.scrubPreviewCacheKey(filePath: video.filePath, quantizedSeconds: quantized)
        if let cached = memoryCache.object(forKey: key) {
            if prefetchNeighbors {
                scheduleScrubNeighborPrefetch(video: video, around: quantized)
            }
            return cached
        }

        guard let image = await scrubPreviewGenerator.image(
            url: video.url,
            path: video.filePath,
            seconds: quantized
        ) else {
            return nil
        }
        memoryCache.setObject(image, forKey: key)
        if prefetchNeighbors {
            scheduleScrubNeighborPrefetch(video: video, around: quantized)
        }
        return image
    }

    /// Warm ±1 / ±2 scrub steps so the next mouse move often hits memory cache.
    private func scheduleScrubNeighborPrefetch(video: Video, around seconds: Double) {
        let step = Self.scrubPreviewStepSeconds
        let targets = [seconds + step, seconds - step, seconds + 2 * step, seconds - 2 * step]
            .map(Self.quantizeScrubSeconds)
            .filter { $0 >= 0 }

        scrubPrefetchLock.lock()
        scrubPrefetchTask?.cancel()
        scrubPrefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            var seen = Set<Double>()
            for t in targets {
                guard !Task.isCancelled else { return }
                guard seen.insert(t).inserted else { continue }
                let key = Self.scrubPreviewCacheKey(filePath: video.filePath, quantizedSeconds: t)
                if self.memoryCache.object(forKey: key) != nil { continue }
                _ = await self.scrubPreviewImage(for: video, atSeconds: t, prefetchNeighbors: false)
            }
        }
        scrubPrefetchLock.unlock()
    }

    /// Deletes every cached still (thumbnail + all detail-preview long-edge variants + legacy detail
    /// file) for `filePath`, on disk and in the memory cache, so a fresh capture can't be shadowed by
    /// a stale file under a different long-edge setting. Shared by `regenerateThumbnail` and
    /// `captureCurrentFrameAsThumbnail`.
    private func clearCachedStills(filePath: String) {
        try? FileManager.default.removeItem(at: thumbnailURL(for: filePath))
        memoryCache.removeObject(forKey: filePath as NSString)
        for edge in Self.detailPreviewLongEdgeChoices {
            try? FileManager.default.removeItem(at: detailPreviewURL(for: filePath, longEdge: edge))
            memoryCache.removeObject(forKey: detailPreviewMemoryKey(filePath: filePath, longEdge: edge))
        }
        try? FileManager.default.removeItem(at: legacyDetailPreviewURL(for: filePath))
    }

    /// Shared still-frame capture for `regenerateThumbnail` / `captureCurrentFrameAsThumbnail`: seek
    /// to `seconds`, JPEG-encode, write to `cacheURL`, populate the memory cache. Kept separate from
    /// `generateThumbnailWork` / `generateDetailPreviewWork` (which pick their own position and
    /// early-return when already cached) so these always-regenerate paths can't hit their "already
    /// cached" fast return. `tolerance` defaults to the auto-pick's 3s "close enough"; the precise
    /// current-frame capture passes `.zero` so it lands on the exact frame, not a nearby keyframe.
    private func writeStill(
        for video: Video, atSeconds seconds: Double, maxDimension: CGFloat,
        compressionFactor: CGFloat, cacheURL: URL, memoryKey: NSString, timeout: Double,
        tolerance: CMTime = CMTime(seconds: 3, preferredTimescale: 600)
    ) async throws {
        let url = video.url
        let nsImage: NSImage = try await withTimeout(seconds: timeout) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let (cgImage, _) = try await generator.image(at: time)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
        else {
            throw ThumbnailError.encodingFailed
        }
        try jpegData.write(to: cacheURL)
        memoryCache.setObject(nsImage, forKey: memoryKey)
    }

    /// Settings → Regenerate filmstrips: advance the cache epoch so every prior composite is
    /// immediately a miss (including files that fail to delete while an `NSImage` still holds them).
    /// Orphaned files are removed in the background.
    func invalidateAllFilmstrips() {
        cancelAllInflightFilmstrips()
        managementLock.lock()
        filmstripEpoch &+= 1
        UserDefaults.standard.set(filmstripEpoch, forKey: Self.filmstripEpochKey)
        managementLock.unlock()
        memoryCache.removeAllObjects()

        let directory = cacheDirectory
        Task.detached(priority: .utility) {
            Self.deleteAllFilmstripFiles(in: directory)
        }
    }

    /// Legacy name kept for call sites; now invalidates via epoch rather than relying solely on deletes.
    func deleteAllFilmstrips() {
        invalidateAllFilmstrips()
    }

    private static func deleteAllFilmstripFiles(in directory: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        while let item = enumerator.nextObject() as? URL {
            let name = item.lastPathComponent
            guard name.contains("_filmstrip") && name.hasSuffix(".jpg") else { continue }
            try? fm.removeItem(at: item)
        }
    }

    private func cancelAllInflightFilmstrips() {
        inflightLock.lock()
        let tasks = Array(inflightFilmstrips.values)
        inflightFilmstrips.removeAll()
        inflightLock.unlock()
        for task in tasks {
            task.cancel()
        }
    }

    func migrateCacheKey(from oldFilePath: String, to newFilePath: String) {
        guard oldFilePath != newFilePath else { return }
        migrateCacheKeys([(from: oldFilePath, to: newFilePath)], onProgress: nil)
    }

    /// Prefer the source cache file when remapping. If the destination already has an
    /// auto-generated thumb, replace it so custom posters (Set Poster from Image) survive Repair Links.
    private func moveOrReplaceCacheFile(from source: URL, to dest: URL, fm: FileManager) {
        guard fm.fileExists(atPath: source.path) else { return }
        if source.path == dest.path { return }
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)
        }
        try? fm.moveItem(at: source, to: dest)
    }

    /// Remaps a stored `thumbnailPath` onto the cache URL for `newFilePath`, keeping any `#version` suffix.
    /// Returns `nil` when there was no stored path (do not invent one).
    func remappedThumbnailPath(_ existing: String?, newFilePath: String) -> String? {
        guard let existing, !existing.isEmpty else { return nil }
        let newBare = thumbnailURL(for: newFilePath).path
        if let hashIdx = existing.firstIndex(of: "#") {
            return newBare + String(existing[hashIdx...])
        }
        return newBare
    }

    /// Batch thumb/filmstrip/detail cache remaps for Location Relink.
    /// Lists the cache directory once (not once per clip). Skips pairs where `from == to`.
    /// When the old poster exists, it **replaces** any file already at the new path-hash
    /// (custom posters must not lose to a pre-generated frame at the destination).
    /// `onProgress` reports remapped clip count (changed paths only).
    func migrateCacheKeys(
        _ mappings: [(from: String, to: String)],
        onProgress: ((Int, Int) -> Void)?
    ) {
        let changed = mappings.filter { $0.from != $0.to }
        guard !changed.isEmpty else {
            onProgress?(0, 0)
            return
        }

        managementLock.lock()
        defer { managementLock.unlock() }

        let fm = FileManager.default
        let cacheContents = (try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        var hashRemap: [String: String] = [:]
        hashRemap.reserveCapacity(changed.count)

        let total = changed.count
        for (index, pair) in changed.enumerated() {
            let oldH = pathHashString(for: pair.from)
            let newH = pathHashString(for: pair.to)
            hashRemap[oldH] = newH

            moveOrReplaceCacheFile(
                from: thumbnailURL(for: pair.from),
                to: thumbnailURL(for: pair.to),
                fm: fm
            )
            moveOrReplaceCacheFile(
                from: filmstripURL(for: pair.from),
                to: filmstripURL(for: pair.to),
                fm: fm
            )

            let oldKey = pair.from as NSString
            let newKey = pair.to as NSString
            if let image = memoryCache.object(forKey: oldKey) {
                memoryCache.setObject(image, forKey: newKey)
                memoryCache.removeObject(forKey: oldKey)
            }
            let oldFsKey = filmstripMemoryKey(for: pair.from)
            let newFsKey = filmstripMemoryKey(for: pair.to)
            if let image = memoryCache.object(forKey: oldFsKey) {
                memoryCache.setObject(image, forKey: newFsKey)
                memoryCache.removeObject(forKey: oldFsKey)
            }
            let oldSbKey = storyboardMemoryKey(for: pair.from)
            let newSbKey = storyboardMemoryKey(for: pair.to)
            if let image = memoryCache.object(forKey: oldSbKey) {
                memoryCache.setObject(image, forKey: newSbKey)
                memoryCache.removeObject(forKey: oldSbKey)
            }
            moveOrReplaceCacheFile(
                from: storyboardURL(for: pair.from),
                to: storyboardURL(for: pair.to),
                fm: fm
            )
            memoryCache.removeObject(forKey: (pair.from + Self.detailPreviewCachePrefix) as NSString)
            for edge in Self.detailPreviewLongEdgeChoices {
                let oldDetailKey = detailPreviewMemoryKey(filePath: pair.from, longEdge: edge)
                let newDetailKey = detailPreviewMemoryKey(filePath: pair.to, longEdge: edge)
                if let image = memoryCache.object(forKey: oldDetailKey) {
                    memoryCache.setObject(image, forKey: newDetailKey)
                    memoryCache.removeObject(forKey: oldDetailKey)
                }
            }

            // Drop any in-flight generation for both keys so a late auto-frame can't overwrite
            // the migrated custom poster.
            inflightLock.lock()
            inflightThumbnails[pair.from]?.cancel()
            inflightThumbnails[pair.to]?.cancel()
            inflightThumbnails.removeValue(forKey: pair.from)
            inflightThumbnails.removeValue(forKey: pair.to)
            inflightFilmstrips[pair.from]?.cancel()
            inflightFilmstrips[pair.to]?.cancel()
            inflightFilmstrips.removeValue(forKey: pair.from)
            inflightFilmstrips.removeValue(forKey: pair.to)
            let oldSbInflight = storyboardInflightKey(filePath: pair.from)
            let newSbInflight = storyboardInflightKey(filePath: pair.to)
            inflightStoryboards[oldSbInflight]?.cancel()
            inflightStoryboards[newSbInflight]?.cancel()
            inflightStoryboards.removeValue(forKey: oldSbInflight)
            inflightStoryboards.removeValue(forKey: newSbInflight)
            for edge in Self.detailPreviewLongEdgeChoices {
                let oldDK = inflightDetailPreviewKey(filePath: pair.from, longEdge: edge)
                let newDK = inflightDetailPreviewKey(filePath: pair.to, longEdge: edge)
                inflightDetailPreviews[oldDK]?.cancel()
                inflightDetailPreviews[newDK]?.cancel()
                inflightDetailPreviews.removeValue(forKey: oldDK)
                inflightDetailPreviews.removeValue(forKey: newDK)
            }
            inflightLock.unlock()

            onProgress?(index + 1, total)
        }

        // One pass over on-disk detail variants (and any leftover hash-prefixed files).
        for url in cacheContents {
            let name = url.lastPathComponent
            guard name.count >= 64 else { continue }
            let oldH = String(name.prefix(64))
            guard let newH = hashRemap[oldH], newH != oldH else { continue }

            if name == "\(oldH).jpg" {
                let dest = cacheDirectory.appendingPathComponent("\(newH).jpg")
                moveOrReplaceCacheFile(from: url, to: dest, fm: fm)
                continue
            }
            if name == "\(oldH)_detail.jpg" {
                let dest = cacheDirectory.appendingPathComponent("\(newH)_detail_1080.jpg")
                moveOrReplaceCacheFile(from: url, to: dest, fm: fm)
                continue
            }
            if name.hasPrefix("\(oldH)_") {
                let rest = String(name.dropFirst(oldH.count))
                let dest = cacheDirectory.appendingPathComponent("\(newH)\(rest)")
                moveOrReplaceCacheFile(from: url, to: dest, fm: fm)
            }
        }
    }

    func clearCache() throws {
        managementLock.lock()
        defer { managementLock.unlock() }
        memoryCache.removeAllObjects()
        let contents = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )
        for file in contents {
            try FileManager.default.removeItem(at: file)
        }
    }
}

enum ThumbnailError: Error, LocalizedError {
    case encodingFailed
    case generationFailed
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode thumbnail image"
        case .generationFailed: return "Failed to generate thumbnail"
        case .fileNotFound: return "File does not exist"
        }
    }
}
