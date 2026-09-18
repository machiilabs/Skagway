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
    private var inflightPlayerStrips: [String: Task<NSImage, Error>] = [:]
    private var inflightDetailPreviews: [String: Task<URL, Error>] = [:]
    /// Per-file sample times (seconds) for the six storyboard collage cells — kept in sync with bake/build.
    private var storyboardCellTimesByPath: [String: [Double]] = [:]
    /// Per-file sample times for the in-player filmstrip (1×N).
    private var playerStripCellTimesByPath: [String: [Double]] = [:]
    private let scrubPrefetchLock = NSLock()
    private var scrubPrefetchTask: Task<Void, Never>?

    var hasPendingThumbnails: Bool {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        return !inflightThumbnails.isEmpty
    }

    private static let filmstripCachePrefix = "_filmstrip"
    private static let storyboardCachePrefix = "_storyboard"
    private static let playerStripCachePrefix = "_playerstrip"
    private static let detailPreviewCachePrefix = "_detailPreview"
    private static let filmstripEpochKey = "Skagway.filmstripCacheEpoch"

    /// Bumped by Settings → Regenerate filmstrips so prior on-disk composites become unreachable
    /// without waiting on deleting thousands of cache files (see `invalidateAllFilmstrips()`).
    private var filmstripEpoch: Int

    /// Fixed cell footprint (points) used by `buildFilmstrip` for every composite. This is the
    /// layout contract that lets `filmstripGrid(in:)` recover rows/columns from a cached image,
    /// since per-video grid choices are not persisted anywhere else.
    static let filmstripCellSize = NSSize(width: 400, height: 225)

    /// Wall storyboard collage: fixed 2×3 frames baked into one larger JPEG for Storyboard View.
    /// Aspect matches filmstrip cells (16:9 × 3/2). Larger than poster card thumbs so strips stay readable.
    static let storyboardRows = 2
    static let storyboardColumns = 3
    static let storyboardFrameCount = storyboardRows * storyboardColumns
    static let storyboardCompositeSize = NSSize(width: 960, height: 360)

    /// True when a cached collage matches the current Storyboard View composite contract.
    static func isValidStoryboardImage(_ image: NSImage) -> Bool {
        abs(image.size.width - storyboardCompositeSize.width) < 2
            && abs(image.size.height - storyboardCompositeSize.height) < 2
    }

    /// In-player filmstrip (IPF): 1×N strip above the scrubber. N is chosen from track width so
    /// each cell stays ~16:9 while the strip spans the same horizontal extent as the scrubber.
    static let playerStripMinFrames = 4
    static let playerStripMaxFrames = 24
    static let playerStripCellAspect: CGFloat = 16.0 / 9.0
    /// Bake cell footprint (points). Display scales the whole composite to the track.
    static let playerStripBakeCellHeight: CGFloat = 54
    static var playerStripBakeCellWidth: CGFloat { playerStripBakeCellHeight * playerStripCellAspect }

    /// How many 16:9 cells fit across `trackWidth` at `stripHeight` (clamped).
    static func playerStripFrameCount(trackWidth: CGFloat, stripHeight: CGFloat) -> Int {
        let h = max(1, stripHeight)
        let cellW = h * playerStripCellAspect
        guard cellW > 1, trackWidth > 1 else { return playerStripMinFrames }
        // Quantize width so tiny resizes don’t thrash N / cache.
        let quantized = max(cellW, (trackWidth / 16).rounded() * 16)
        let n = Int((quantized / cellW).rounded())
        return min(playerStripMaxFrames, max(playerStripMinFrames, n))
    }

    static func playerStripCompositeSize(frameCount: Int) -> NSSize {
        let n = max(1, frameCount)
        return NSSize(
            width: playerStripBakeCellWidth * CGFloat(n),
            height: playerStripBakeCellHeight
        )
    }

    static func isValidPlayerStripImage(_ image: NSImage, frameCount: Int) -> Bool {
        let expected = playerStripCompositeSize(frameCount: frameCount)
        return abs(image.size.width - expected.width) < 2
            && abs(image.size.height - expected.height) < 2
    }

    static func isValidPlayerStripCellTimes(_ seconds: [Double], frameCount: Int) -> Bool {
        guard seconds.count == frameCount else { return false }
        return seconds.allSatisfy { $0.isFinite && $0 >= 0 }
    }

    /// Map a click in the displayed strip to a cell index (0…N-1).
    static func playerStripCellIndex(at location: CGPoint, size: CGSize, frameCount: Int) -> Int {
        guard size.width > 0, frameCount > 0 else { return 0 }
        let column = Int(location.x / size.width * CGFloat(frameCount))
        return min(frameCount - 1, max(0, column))
    }

    static func playerStripEvenSplitSeconds(index: Int, duration: Double, frameCount: Int) -> Double {
        let n = max(1, frameCount)
        let i = min(n - 1, max(0, index))
        // Center of each equal-width time bucket so the scrubber playhead lands mid-cell on click.
        return (Double(i) + 0.5) / Double(n) * max(0, duration)
    }

    /// Playhead cell that lines up with the scrubber’s linear time mapping (equal-width buckets).
    static func playerStripPlayheadIndex(seconds: Double, duration: Double, frameCount: Int) -> Int {
        guard frameCount > 0, duration > 0 else { return 0 }
        let f = min(1, max(0, seconds / duration))
        if f >= 1 { return frameCount - 1 }
        return min(frameCount - 1, Int(f * Double(frameCount)))
    }

    /// True when `seconds` is a full set of per-cell sample times for the 2×3 collage.
    static func isValidStoryboardCellTimes(_ seconds: [Double]) -> Bool {
        guard seconds.count == storyboardFrameCount else { return false }
        return seconds.allSatisfy { $0.isFinite && $0 >= 0 }
    }

    /// Map a click inside a 2×3 storyboard collage to the cell index (row-major).
    static func storyboardCellIndex(at location: CGPoint, size: CGSize) -> Int {
        let w = max(1.0, size.width)
        let h = max(1.0, size.height)
        let column = min(storyboardColumns - 1, max(0, Int(location.x / w * CGFloat(storyboardColumns))))
        let row = min(storyboardRows - 1, max(0, Int(location.y / h * CGFloat(storyboardRows))))
        return row * storyboardColumns + column
    }

    /// Ideal even-timeline sample for cell `index` (fallback when no stored times exist yet).
    static func storyboardEvenSplitSeconds(index: Int, duration: Double) -> Double {
        let i = min(storyboardFrameCount - 1, max(0, index))
        return Double(i + 1) / Double(storyboardFrameCount + 1) * max(0, duration)
    }

    /// Map a click to the sample time used for that cell’s pixels (stored at bake/build).
    /// Falls back to even-split only if times are missing (should be rare after cache invalidation).
    func storyboardClickSeconds(
        for filePath: String,
        at location: CGPoint,
        size: CGSize,
        duration: Double
    ) -> Double {
        let index = Self.storyboardCellIndex(at: location, size: size)
        if let times = loadStoryboardCellTimes(for: filePath), Self.isValidStoryboardCellTimes(times) {
            return times[index]
        }
        return Self.storyboardEvenSplitSeconds(index: index, duration: duration)
    }

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

    /// Larger 2×3 collage for Storyboard View (`{hash}_storyboard.jpg`).
    func storyboardURL(for filePath: String) -> URL {
        let hash = pathHashString(for: filePath)
        return cacheDirectory.appendingPathComponent("\(hash)_storyboard.jpg")
    }

    /// Sidecar with six sample times (seconds) matching collage cell pixels (`{hash}_storyboard_times.json`).
    func storyboardTimesURL(for filePath: String) -> URL {
        let hash = pathHashString(for: filePath)
        return cacheDirectory.appendingPathComponent("\(hash)_storyboard_times.json")
    }

    /// In-player filmstrip composite (`{hash}_playerstrip_n{N}_c2.jpg`).
    func playerStripURL(for filePath: String, frameCount: Int) -> URL {
        let hash = pathHashString(for: filePath)
        return cacheDirectory.appendingPathComponent("\(hash)_playerstrip_n\(frameCount)_c2.jpg")
    }

    /// Sample times for IPF cells (`{hash}_playerstrip_n{N}_c2_times.json`).
    func playerStripTimesURL(for filePath: String, frameCount: Int) -> URL {
        let hash = pathHashString(for: filePath)
        return cacheDirectory.appendingPathComponent("\(hash)_playerstrip_n\(frameCount)_c2_times.json")
    }

    private func filmstripMemoryKey(for filePath: String) -> NSString {
        (filePath + Self.filmstripCachePrefix + "_e\(filmstripEpoch)") as NSString
    }

    private func storyboardMemoryKey(for filePath: String) -> NSString {
        (filePath + Self.storyboardCachePrefix) as NSString
    }

    private func playerStripMemoryKey(for filePath: String, frameCount: Int) -> NSString {
        (filePath + Self.playerStripCachePrefix + "_n\(frameCount)_c2") as NSString
    }

    private func playerStripTimesCacheKey(filePath: String, frameCount: Int) -> String {
        "\(filePath)\u{1e}\(frameCount)"
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
    /// Rejects legacy small composites and collages without a matching cell-times sidecar so
    /// Storyboard View regenerates with the click-to-play time contract.
    func loadStoryboard(for filePath: String) -> NSImage? {
        guard loadStoryboardCellTimes(for: filePath) != nil else {
            // Drop orphan JPEG / stale memory so generateStoryboard rebakes with times.
            memoryCache.removeObject(forKey: storyboardMemoryKey(for: filePath))
            return nil
        }
        let memKey = storyboardMemoryKey(for: filePath)
        if let cached = memoryCache.object(forKey: memKey), Self.isValidStoryboardImage(cached) {
            return cached
        }
        let url = storyboardURL(for: filePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url),
              Self.isValidStoryboardImage(image)
        else { return nil }
        memoryCache.setObject(image, forKey: memKey)
        return image
    }

    /// Sample times (seconds) for the six collage cells, or nil if missing/invalid (forces rebake).
    func loadStoryboardCellTimes(for filePath: String) -> [Double]? {
        inflightLock.lock()
        if let cached = storyboardCellTimesByPath[filePath], Self.isValidStoryboardCellTimes(cached) {
            inflightLock.unlock()
            return cached
        }
        inflightLock.unlock()

        let url = storyboardTimesURL(for: filePath)
        guard let data = try? Data(contentsOf: url),
              let times = Self.decodeStoryboardCellTimes(data)
        else { return nil }

        inflightLock.lock()
        storyboardCellTimesByPath[filePath] = times
        inflightLock.unlock()
        return times
    }

    private static func decodeStoryboardCellTimes(_ data: Data) -> [Double]? {
        struct Payload: Decodable {
            let version: Int?
            let seconds: [Double]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              isValidStoryboardCellTimes(payload.seconds)
        else { return nil }
        return payload.seconds
    }

    private static func encodeStoryboardCellTimes(_ seconds: [Double]) throws -> Data {
        struct Payload: Encodable {
            let version: Int
            let seconds: [Double]
        }
        return try JSONEncoder().encode(Payload(version: 1, seconds: seconds))
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

    // MARK: - In-player filmstrip (1×N above scrubber)

    /// Fast memory/disk load of the IPF composite for a given frame count (no generation).
    func loadPlayerStrip(for filePath: String, frameCount: Int) -> NSImage? {
        let memKey = playerStripMemoryKey(for: filePath, frameCount: frameCount)
        if let cached = memoryCache.object(forKey: memKey),
           Self.isValidPlayerStripImage(cached, frameCount: frameCount)
        {
            return cached
        }
        let url = playerStripURL(for: filePath, frameCount: frameCount)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url),
              Self.isValidPlayerStripImage(image, frameCount: frameCount)
        else { return nil }
        memoryCache.setObject(image, forKey: memKey)
        return image
    }

    func loadPlayerStripCellTimes(for filePath: String, frameCount: Int) -> [Double]? {
        let cacheKey = playerStripTimesCacheKey(filePath: filePath, frameCount: frameCount)
        inflightLock.lock()
        if let cached = playerStripCellTimesByPath[cacheKey],
           Self.isValidPlayerStripCellTimes(cached, frameCount: frameCount)
        {
            inflightLock.unlock()
            return cached
        }
        inflightLock.unlock()

        let url = playerStripTimesURL(for: filePath, frameCount: frameCount)
        guard let data = try? Data(contentsOf: url),
              let times = Self.decodePlayerStripCellTimes(data, frameCount: frameCount)
        else { return nil }

        inflightLock.lock()
        playerStripCellTimesByPath[cacheKey] = times
        inflightLock.unlock()
        return times
    }

    private static func decodePlayerStripCellTimes(_ data: Data, frameCount: Int) -> [Double]? {
        struct Payload: Decodable {
            let version: Int?
            let seconds: [Double]
        }
        // v2+ = center-of-bucket sample times (v1 was (i+1)/(N+1) and misaligned the playhead).
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              (payload.version ?? 0) >= 2,
              isValidPlayerStripCellTimes(payload.seconds, frameCount: frameCount)
        else { return nil }
        return payload.seconds
    }

    private static func encodePlayerStripCellTimes(_ seconds: [Double]) throws -> Data {
        struct Payload: Encodable {
            let version: Int
            let seconds: [Double]
        }
        return try JSONEncoder().encode(Payload(version: 2, seconds: seconds))
    }

    private func storePlayerStrip(
        _ image: NSImage,
        cellTimes: [Double],
        for filePath: String,
        frameCount: Int
    ) throws {
        guard Self.isValidPlayerStripImage(image, frameCount: frameCount),
              Self.isValidPlayerStripCellTimes(cellTimes, frameCount: frameCount)
        else {
            throw ThumbnailError.encodingFailed
        }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        else {
            throw ThumbnailError.encodingFailed
        }
        try jpegData.write(to: playerStripURL(for: filePath, frameCount: frameCount))
        try Self.encodePlayerStripCellTimes(cellTimes)
            .write(to: playerStripTimesURL(for: filePath, frameCount: frameCount))
        memoryCache.setObject(image, forKey: playerStripMemoryKey(for: filePath, frameCount: frameCount))
        let cacheKey = playerStripTimesCacheKey(filePath: filePath, frameCount: frameCount)
        inflightLock.lock()
        playerStripCellTimesByPath[cacheKey] = cellTimes
        inflightLock.unlock()
    }

    /// Load or build the in-player filmstrip + cell times for `frameCount` cells.
    func generatePlayerStrip(for video: Video, frameCount: Int) async throws -> NSImage {
        let n = min(Self.playerStripMaxFrames, max(Self.playerStripMinFrames, frameCount))
        let memKey = playerStripMemoryKey(for: video.filePath, frameCount: n)
        if let cached = memoryCache.object(forKey: memKey),
           Self.isValidPlayerStripImage(cached, frameCount: n),
           loadPlayerStripCellTimes(for: video.filePath, frameCount: n) != nil
        {
            return cached
        }
        if let image = loadPlayerStrip(for: video.filePath, frameCount: n),
           loadPlayerStripCellTimes(for: video.filePath, frameCount: n) != nil
        {
            return image
        }
        return try await coalescedPlayerStrip(for: video, frameCount: n)
    }

    private func playerStripInflightKey(filePath: String, frameCount: Int) -> String {
        // `c2` = center-of-bucket sample contract (invalidates in-flight / cache coalesces from v1).
        "\(filePath)\u{1e}ps\u{1e}1x\(frameCount)\u{1e}c2"
    }

    private func coalescedPlayerStrip(for video: Video, frameCount: Int) async throws -> NSImage {
        let key = playerStripInflightKey(filePath: video.filePath, frameCount: frameCount)
        inflightLock.lock()
        if let existing = inflightPlayerStrips[key] {
            inflightLock.unlock()
            return try await existing.value
        }
        let task = Task<NSImage, Error> {
            await self.generationGate.acquire()
            do {
                let image = try await self.buildPlayerStrip(for: video, frameCount: frameCount)
                await self.generationGate.release()
                return image
            } catch {
                await self.generationGate.release()
                throw error
            }
        }
        inflightPlayerStrips[key] = task
        inflightLock.unlock()
        defer {
            inflightLock.lock()
            inflightPlayerStrips.removeValue(forKey: key)
            inflightLock.unlock()
        }
        return try await task.value
    }

    private func buildPlayerStrip(for video: Video, frameCount: Int) async throws -> NSImage {
        let url = video.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ThumbnailError.fileNotFound
        }

        let totalFrames = frameCount
        let result: (frames: [CGImage], times: [Double]) = try await withTimeout(seconds: 45) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let totalSeconds = CMTimeGetSeconds(duration)
            guard totalSeconds.isFinite, totalSeconds > 0.5 else {
                throw ThumbnailError.generationFailed
            }

            // Centers of equal-width time buckets — scrubber playhead sits mid-cell after a click.
            let times = (0..<totalFrames).map { index in
                Self.playerStripEvenSplitSeconds(
                    index: index,
                    duration: totalSeconds,
                    frameCount: totalFrames
                )
            }
            let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 192, height: 192)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 1.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1.5, preferredTimescale: 600)

            var frames: [CGImage] = []
            frames.reserveCapacity(totalFrames)
            for time in cmTimes {
                try Task.checkCancellation()
                if let (cgImage, _) = try? await generator.image(at: time) {
                    frames.append(cgImage)
                }
            }
            return (frames, times)
        }

        guard result.frames.count == totalFrames else {
            throw ThumbnailError.generationFailed
        }

        let cellWidth = Self.playerStripBakeCellWidth
        let cellHeight = Self.playerStripBakeCellHeight
        let composite = Self.playerStripCompositeSize(frameCount: totalFrames)

        let compositeImage = NSImage(size: composite)
        compositeImage.lockFocus()
        NSColor.black.setFill()
        for (index, cgImage) in result.frames.enumerated() {
            let cellX = CGFloat(index) * cellWidth
            let cellY: CGFloat = 0
            let frameW = CGFloat(cgImage.width)
            let frameH = CGFloat(cgImage.height)
            // Fill the 16:9 cell (crop/center) so display isn’t letterboxed inside each cell.
            let scale = max(cellWidth / frameW, cellHeight / frameH)
            let drawW = frameW * scale
            let drawH = frameH * scale
            let drawX = cellX + (cellWidth - drawW) / 2
            let drawY = cellY + (cellHeight - drawH) / 2
            NSRect(x: cellX, y: cellY, width: cellWidth, height: cellHeight).fill()
            let frameImage = NSImage(cgImage: cgImage, size: NSSize(width: frameW, height: frameH))
            // Clip to cell
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: cellX, y: cellY, width: cellWidth, height: cellHeight)).addClip()
            frameImage.draw(in: NSRect(x: drawX, y: drawY, width: drawW, height: drawH))
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        compositeImage.unlockFocus()

        try Task.checkCancellation()
        try storePlayerStrip(
            compositeImage,
            cellTimes: result.times,
            for: video.filePath,
            frameCount: totalFrames
        )
        return compositeImage
    }

    /// Click → sample seconds for the IPF cell under the pointer.
    func playerStripClickSeconds(
        at location: CGPoint,
        size: CGSize,
        filePath: String,
        duration: Double,
        frameCount: Int
    ) -> Double {
        let index = Self.playerStripCellIndex(at: location, size: size, frameCount: frameCount)
        if let times = loadPlayerStripCellTimes(for: filePath, frameCount: frameCount),
           Self.isValidPlayerStripCellTimes(times, frameCount: frameCount)
        {
            return times[index]
        }
        return Self.playerStripEvenSplitSeconds(index: index, duration: duration, frameCount: frameCount)
    }

    // MARK: - Storyboard (Wall 2×3 larger collage)

    /// Load or build the Wall storyboard: one JPEG at `storyboardCompositeSize` with 2×3 frames,
    /// plus a sidecar of the six sample times used for those pixels (click-to-play contract).
    /// Prefers baking evenly spaced cells from an existing filmstrip when it has ≥6 frames; otherwise
    /// samples six frames evenly across the timeline (same gate/coalesce pattern as filmstrips).
    func generateStoryboard(for video: Video) async throws -> NSImage {
        let memKey = storyboardMemoryKey(for: video.filePath)
        if let cached = memoryCache.object(forKey: memKey),
           Self.isValidStoryboardImage(cached),
           loadStoryboardCellTimes(for: video.filePath) != nil
        {
            return cached
        }
        let cacheURL = storyboardURL(for: video.filePath)
        if FileManager.default.fileExists(atPath: cacheURL.path),
           let image = NSImage(contentsOf: cacheURL),
           Self.isValidStoryboardImage(image),
           loadStoryboardCellTimes(for: video.filePath) != nil
        {
            memoryCache.setObject(image, forKey: memKey)
            return image
        }

        if let duration = video.duration, duration > 0,
           let filmstrip = loadFilmstrip(for: video.filePath),
           let baked = bakeStoryboard(fromFilmstrip: filmstrip, duration: duration)
        {
            try storeStoryboard(baked.image, cellTimes: baked.cellTimes, for: video.filePath)
            return baked.image
        }

        return try await coalescedStoryboard(for: video)
    }

    private func storyboardInflightKey(filePath: String) -> String {
        // `t1` = cell-times sidecar contract (invalidates in-flight coalesces from older builds).
        "\(filePath)\u{1e}sb\u{1e}2x3\u{1e}960x360\u{1e}t1"
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

    /// Composite six filmstrip cells into the Storyboard View collage and return the sample times
    /// those cells were baked at (`(sourceIndex+1)/(N+1)×duration`).
    /// Requires at least 6 cells so the bake can track filmstrip even-timeline indices.
    func bakeStoryboard(
        fromFilmstrip filmstrip: NSImage,
        duration: Double
    ) -> (image: NSImage, cellTimes: [Double])? {
        guard duration.isFinite, duration > 0 else { return nil }
        guard let grid = Self.filmstripGrid(in: filmstrip) else { return nil }
        let totalFrames = grid.rows * grid.columns
        guard totalFrames >= Self.storyboardFrameCount else { return nil }

        let cell = Self.filmstripCellSize
        let destSize = Self.storyboardCompositeSize
        let destCellW = destSize.width / CGFloat(Self.storyboardColumns)
        let destCellH = destSize.height / CGFloat(Self.storyboardRows)

        let out = NSImage(size: destSize)
        out.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: destSize).fill()

        var cellTimes: [Double] = []
        cellTimes.reserveCapacity(Self.storyboardFrameCount)

        for storyboardIndex in 0..<Self.storyboardFrameCount {
            // Nearest filmstrip cell to the ideal even-split slot; seek uses that cell’s sample time.
            let sourceIndex = min(
                totalFrames - 1,
                max(0, Int((Double(storyboardIndex + 1) / Double(Self.storyboardFrameCount + 1)) * Double(totalFrames)))
            )
            cellTimes.append(
                Double(sourceIndex + 1) / Double(totalFrames + 1) * duration
            )
            let srcCol = sourceIndex % grid.columns
            let srcRow = sourceIndex / grid.columns
            let sourceRect = NSRect(
                x: CGFloat(srcCol) * cell.width,
                y: filmstrip.size.height - CGFloat(srcRow + 1) * cell.height,
                width: cell.width,
                height: cell.height
            )
            let destCol = storyboardIndex % Self.storyboardColumns
            let destRow = storyboardIndex / Self.storyboardColumns
            let destRect = NSRect(
                x: CGFloat(destCol) * destCellW,
                y: destSize.height - CGFloat(destRow + 1) * destCellH,
                width: destCellW,
                height: destCellH
            )
            filmstrip.draw(in: destRect, from: sourceRect, operation: .copy, fraction: 1.0)
        }
        out.unlockFocus()
        return (out, cellTimes)
    }

    private func buildStoryboard(for video: Video) async throws -> NSImage {
        let rows = Self.storyboardRows
        let columns = Self.storyboardColumns
        let totalFrames = Self.storyboardFrameCount
        let url = video.url

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ThumbnailError.fileNotFound
        }

        // Prefer an inspector filmstrip that appeared while we waited on the gate.
        if let duration = video.duration, duration > 0,
           let filmstrip = loadFilmstrip(for: video.filePath),
           let baked = bakeStoryboard(fromFilmstrip: filmstrip, duration: duration)
        {
            try storeStoryboard(baked.image, cellTimes: baked.cellTimes, for: video.filePath)
            return baked.image
        }

        let sampled: (frames: [CGImage], cellTimes: [Double]) = try await withTimeout(seconds: 30) {
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
            // Decode above cell size so the larger 960×360 collage stays sharp.
            generator.maximumSize = CGSize(width: 480, height: 480)
            // Precise frames so stored actualTimes match the pixels click-to-play will seek to.
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            var frames: [CGImage] = []
            var cellTimes: [Double] = []
            frames.reserveCapacity(totalFrames)
            cellTimes.reserveCapacity(totalFrames)
            for time in times {
                try Task.checkCancellation()
                if let (cgImage, actual) = try? await generator.image(at: time) {
                    frames.append(cgImage)
                    let actualSeconds = CMTimeGetSeconds(actual)
                    cellTimes.append(
                        actualSeconds.isFinite ? actualSeconds : CMTimeGetSeconds(time)
                    )
                }
            }
            return (frames, cellTimes)
        }

        guard sampled.frames.count == totalFrames,
              Self.isValidStoryboardCellTimes(sampled.cellTimes)
        else {
            throw ThumbnailError.generationFailed
        }

        let destSize = Self.storyboardCompositeSize
        let cellWidth = destSize.width / CGFloat(columns)
        let cellHeight = destSize.height / CGFloat(rows)

        let composite = NSImage(size: destSize)
        composite.lockFocus()
        NSColor.black.setFill()
        for (index, cgImage) in sampled.frames.enumerated() {
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

        try storeStoryboard(composite, cellTimes: sampled.cellTimes, for: video.filePath)
        return composite
    }

    private func storeStoryboard(_ image: NSImage, cellTimes: [Double], for filePath: String) throws {
        guard Self.isValidStoryboardCellTimes(cellTimes) else {
            throw ThumbnailError.encodingFailed
        }
        let cacheURL = storyboardURL(for: filePath)
        let timesURL = storyboardTimesURL(for: filePath)
        let memKey = storyboardMemoryKey(for: filePath)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        else {
            throw ThumbnailError.encodingFailed
        }
        let timesData = try Self.encodeStoryboardCellTimes(cellTimes)
        try Task.checkCancellation()
        try jpegData.write(to: cacheURL)
        try timesData.write(to: timesURL, options: .atomic)
        memoryCache.setObject(image, forKey: memKey)
        inflightLock.lock()
        storyboardCellTimesByPath[filePath] = cellTimes
        inflightLock.unlock()
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
        inflightLock.lock()
        storyboardCellTimesByPath.removeAll()
        playerStripCellTimesByPath.removeAll()
        inflightLock.unlock()

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

    /// Remaps a stored `thumbnailPath` onto the cache URL for `newFilePath`.
    /// Always appends a fresh `#version` so grid/list `.task(id:)` / `cacheVersion` reload
    /// after Repair Links (disk migrate alone does not remount cards while filtered rows lag).
    /// Returns `nil` when there was no stored path (do not invent one).
    func remappedThumbnailPath(_ existing: String?, newFilePath: String) -> String? {
        guard let existing, !existing.isEmpty else { return nil }
        let newBare = thumbnailURL(for: newFilePath).path
        return "\(newBare)#\(Date().timeIntervalSince1970)"
    }

    /// Batch thumb/filmstrip/detail cache remaps for Location Relink.
    /// Lists the cache directory once (not once per clip). Skips pairs where `from == to`.
    /// When the old poster exists, it **replaces** any file already at the new path-hash
    /// (custom posters must not lose to a pre-generated frame at the destination).
    ///
    /// Order matters: move **all** on-disk variants first, then warm `NSCache` from the new
    /// paths. Warming detail memory before the detail file is moved left auto-frames in cache
    /// until process restart (disk was already correct).
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
        // Pass 1 — move every cache file for each pair; clear memory; do not warm yet.
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
            moveOrReplaceCacheFile(
                from: storyboardURL(for: pair.from),
                to: storyboardURL(for: pair.to),
                fm: fm
            )
            moveOrReplaceCacheFile(
                from: storyboardTimesURL(for: pair.from),
                to: storyboardTimesURL(for: pair.to),
                fm: fm
            )
            for n in Self.playerStripMinFrames...Self.playerStripMaxFrames {
                moveOrReplaceCacheFile(
                    from: playerStripURL(for: pair.from, frameCount: n),
                    to: playerStripURL(for: pair.to, frameCount: n),
                    fm: fm
                )
                moveOrReplaceCacheFile(
                    from: playerStripTimesURL(for: pair.from, frameCount: n),
                    to: playerStripTimesURL(for: pair.to, frameCount: n),
                    fm: fm
                )
            }
            for edge in Self.detailPreviewLongEdgeChoices {
                moveOrReplaceCacheFile(
                    from: detailPreviewURL(for: pair.from, longEdge: edge),
                    to: detailPreviewURL(for: pair.to, longEdge: edge),
                    fm: fm
                )
            }
            moveOrReplaceCacheFile(
                from: legacyDetailPreviewURL(for: pair.from),
                to: legacyDetailPreviewURL(for: pair.to),
                fm: fm
            )

            let oldKey = pair.from as NSString
            let newKey = pair.to as NSString
            memoryCache.removeObject(forKey: oldKey)
            memoryCache.removeObject(forKey: newKey)
            memoryCache.removeObject(forKey: filmstripMemoryKey(for: pair.from))
            memoryCache.removeObject(forKey: filmstripMemoryKey(for: pair.to))
            memoryCache.removeObject(forKey: storyboardMemoryKey(for: pair.from))
            memoryCache.removeObject(forKey: storyboardMemoryKey(for: pair.to))
            for n in Self.playerStripMinFrames...Self.playerStripMaxFrames {
                memoryCache.removeObject(forKey: playerStripMemoryKey(for: pair.from, frameCount: n))
                memoryCache.removeObject(forKey: playerStripMemoryKey(for: pair.to, frameCount: n))
            }
            inflightLock.lock()
            storyboardCellTimesByPath.removeValue(forKey: pair.from)
            storyboardCellTimesByPath.removeValue(forKey: pair.to)
            let psKeys = playerStripCellTimesByPath.keys.filter {
                $0.hasPrefix(pair.from + "\u{1e}") || $0.hasPrefix(pair.to + "\u{1e}")
            }
            for key in psKeys {
                playerStripCellTimesByPath.removeValue(forKey: key)
            }
            inflightLock.unlock()
            memoryCache.removeObject(forKey: (pair.from + Self.detailPreviewCachePrefix) as NSString)
            memoryCache.removeObject(forKey: (pair.to + Self.detailPreviewCachePrefix) as NSString)
            for edge in Self.detailPreviewLongEdgeChoices {
                memoryCache.removeObject(forKey: detailPreviewMemoryKey(filePath: pair.from, longEdge: edge))
                memoryCache.removeObject(forKey: detailPreviewMemoryKey(filePath: pair.to, longEdge: edge))
            }

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
            for n in Self.playerStripMinFrames...Self.playerStripMaxFrames {
                let oldPsInflight = playerStripInflightKey(filePath: pair.from, frameCount: n)
                let newPsInflight = playerStripInflightKey(filePath: pair.to, frameCount: n)
                inflightPlayerStrips[oldPsInflight]?.cancel()
                inflightPlayerStrips[newPsInflight]?.cancel()
                inflightPlayerStrips.removeValue(forKey: oldPsInflight)
                inflightPlayerStrips.removeValue(forKey: newPsInflight)
            }
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

        // Pass 2 — leftover hash-prefixed files from the pre-move directory listing.
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

        // Pass 3 — warm memory only after every disk move finished.
        for pair in changed {
            if let image = NSImage(contentsOf: thumbnailURL(for: pair.to)) {
                memoryCache.setObject(image, forKey: pair.to as NSString)
            }
            if let image = NSImage(contentsOf: filmstripURL(for: pair.to)) {
                memoryCache.setObject(image, forKey: filmstripMemoryKey(for: pair.to))
            }
            if let image = NSImage(contentsOf: storyboardURL(for: pair.to)),
               Self.isValidStoryboardImage(image),
               loadStoryboardCellTimes(for: pair.to) != nil
            {
                memoryCache.setObject(image, forKey: storyboardMemoryKey(for: pair.to))
            }
            for n in Self.playerStripMinFrames...Self.playerStripMaxFrames {
                if let image = NSImage(contentsOf: playerStripURL(for: pair.to, frameCount: n)),
                   Self.isValidPlayerStripImage(image, frameCount: n),
                   loadPlayerStripCellTimes(for: pair.to, frameCount: n) != nil
                {
                    memoryCache.setObject(image, forKey: playerStripMemoryKey(for: pair.to, frameCount: n))
                }
            }
            for edge in Self.detailPreviewLongEdgeChoices {
                if let image = NSImage(contentsOf: detailPreviewURL(for: pair.to, longEdge: edge)) {
                    memoryCache.setObject(image, forKey: detailPreviewMemoryKey(filePath: pair.to, longEdge: edge))
                }
            }
        }
    }

    func clearCache() throws {
        managementLock.lock()
        defer { managementLock.unlock() }
        memoryCache.removeAllObjects()
        inflightLock.lock()
        storyboardCellTimesByPath.removeAll()
        playerStripCellTimesByPath.removeAll()
        inflightLock.unlock()
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
