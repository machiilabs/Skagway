import Foundation

/// The image a browser view shows for each video.
enum WallAssetKind: String, Equatable {
    /// List rows: scan poster (`{hash}.jpg`).
    case poster
    /// Grid cards: poster plus the 720 still (`{hash}_detail_720.jpg`).
    case gridPreview
    /// Storyboard cards: 2×3 collage plus its cell-times sidecar.
    case storyboard

    init(viewMode: ViewMode) {
        switch viewMode {
        case .grid: self = .gridPreview
        case .list: self = .poster
        case .storyboard: self = .storyboard
        }
    }
}

/// Fill order: the current view outward from what is on screen, then the rest of the library.
enum WallBackfillOrder {
    /// From `centerIndex`, two steps down for every step up (people mostly scroll down).
    /// Library paths already in the view are not repeated.
    static func order(viewPaths: [String], centerIndex: Int, libraryPaths: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(viewPaths.count + libraryPaths.count)
        var seen = Set<String>()
        seen.reserveCapacity(viewPaths.count + libraryPaths.count)
        func append(_ path: String) {
            if seen.insert(path).inserted { out.append(path) }
        }

        let n = viewPaths.count
        if n > 0 {
            let center = min(max(centerIndex, 0), n - 1)
            var down = center
            var up = center - 1
            var step = 0
            while down < n || up >= 0 {
                let preferDown = step % 3 != 2
                if (preferDown && down < n) || up < 0 {
                    append(viewPaths[down])
                    down += 1
                } else {
                    append(viewPaths[up])
                    up -= 1
                }
                step += 1
            }
        }
        for path in libraryPaths {
            append(path)
        }
        return out
    }
}

/// What must be true before idle fill does any work.
struct WallBackfillConditions: Equatable {
    var enabled: Bool
    var isScanning: Bool
    var isPlaying: Bool
    var isMoving: Bool
    var isLowPower: Bool
    var isThermalSerious: Bool
    /// `ProcessInfo.systemUptime` of the last scroll or other user activity that should pause fill.
    var lastActivityUptime: TimeInterval
}

enum WallBackfillIdle {
    /// Quiet time after scrolling, playback, or a scan before fill resumes.
    static let quietSeconds: TimeInterval = 3

    static func isIdle(_ c: WallBackfillConditions, now: TimeInterval) -> Bool {
        c.enabled
            && !c.isScanning
            && !c.isPlaying
            && !c.isMoving
            && !c.isLowPower
            && !c.isThermalSerious
            && now - c.lastActivityUptime >= quietSeconds
    }
}

/// Builds the missing wall images one video at a time while the app is idle, so scrolling far
/// down finds them already made. Never touches Inspector or scrubber filmstrips.
@MainActor
final class WallAssetBackfill {
    struct Snapshot {
        var kind: WallAssetKind
        var viewPaths: [String]
        var centerIndex: Int
        var libraryPaths: [String]
    }

    /// How far the on-screen center may drift before the order is re-centered.
    static let recenterDistance = 24
    private static let checkBatchSize = 128
    private static let pausePoll: Duration = .seconds(1)
    private static let betweenJobs: Duration = .milliseconds(150)
    /// One video never holds up the rest. Past this, it is skipped for the session.
    static let jobDeadlineSeconds: Double = 90

    private let service: ThumbnailService
    var snapshot: () -> Snapshot? = { nil }
    var currentCenterIndex: () -> Int = { 0 }
    var conditions: () -> WallBackfillConditions
    var video: (String) -> Video? = { _ in nil }
    /// A poster was made for a video whose row has no `thumbnailPath` yet.
    var didMakePoster: (Video, URL) -> Void = { _, _ in }

    private var order: [String] = []
    private var orderKind: WallAssetKind?
    private var orderCenter = 0
    private var cursor = 0
    private var needsRebuild = true
    private var lastActivity: TimeInterval = 0
    private var finished: [WallAssetKind: Set<String>] = [:]
    private var failed: [WallAssetKind: Set<String>] = [:]
    private var task: Task<Void, Never>?

    init(service: ThumbnailService, conditions: @escaping () -> WallBackfillConditions) {
        self.service = service
        self.conditions = conditions
    }

    /// View, filter, sort, or library contents changed. Cheap: the order is rebuilt between jobs.
    func invalidate() {
        needsRebuild = true
        start()
    }

    /// Playback ended, a scan finished, etc. Fill waits out the quiet period, then resumes.
    func noteActivity() {
        lastActivity = ProcessInfo.processInfo.systemUptime
        start()
    }

    /// New library (or its cache was cleared): forget what was checked this session.
    func reset() {
        finished.removeAll()
        failed.removeAll()
        invalidate()
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        // App Nap would stretch the pause and between-job sleeps while the window is hidden or
        // the display is off. Idle system sleep is still allowed.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Preparing previews while idle"
        )
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            task = nil
        }
        while !Task.isCancelled {
            var c = conditions()
            guard c.enabled else { return }
            c.lastActivityUptime = max(c.lastActivityUptime, lastActivity)
            guard WallBackfillIdle.isIdle(c, now: ProcessInfo.processInfo.systemUptime) else {
                try? await Task.sleep(for: Self.pausePoll)
                continue
            }

            if !needsRebuild, abs(currentCenterIndex() - orderCenter) > Self.recenterDistance {
                needsRebuild = true
            }
            if needsRebuild {
                guard rebuild() else { return }
            }

            guard let kind = orderKind else { return }
            switch await nextMissing(kind: kind) {
            case .exhausted:
                return
            case .changed:
                continue
            case .missing(let path):
                await fill(path, kind: kind)
                try? await Task.sleep(for: Self.betweenJobs)
            }
        }
    }

    private func rebuild() -> Bool {
        guard let s = snapshot() else { return false }
        order = WallBackfillOrder.order(
            viewPaths: s.viewPaths,
            centerIndex: s.centerIndex,
            libraryPaths: s.libraryPaths
        )
        orderKind = s.kind
        orderCenter = s.centerIndex
        cursor = 0
        needsRebuild = false
        return true
    }

    private enum Next {
        case missing(String)
        case exhausted
        case changed
    }

    /// Walks the order in batches. Disk checks run off the main actor.
    private func nextMissing(kind: WallAssetKind) async -> Next {
        while cursor < order.count {
            let end = min(order.count, cursor + Self.checkBatchSize)
            let done = finished[kind, default: []]
            let bad = failed[kind, default: []]
            let batch = order[cursor..<end].filter { !done.contains($0) && !bad.contains($0) }
            let batchEnd = end
            let service = self.service
            let present: [Bool] = await Task.detached(priority: .utility) {
                batch.map { service.hasWallAsset(kind, for: $0) }
            }.value
            guard !Task.isCancelled else { return .exhausted }
            guard !needsRebuild, orderKind == kind else { return .changed }

            var firstMissing: String?
            for (path, isPresent) in zip(batch, present) {
                if isPresent {
                    finished[kind, default: []].insert(path)
                } else if firstMissing == nil {
                    firstMissing = path
                }
            }
            if let firstMissing {
                cursor = (order[cursor..<batchEnd].firstIndex(of: firstMissing) ?? batchEnd - 1) + 1
                return .missing(firstMissing)
            }
            cursor = batchEnd
        }
        return .exhausted
    }

    private func fill(_ path: String, kind: WallAssetKind) async {
        guard let video = video(path) else {
            failed[kind, default: []].insert(path)
            return
        }
        let reachable = await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: path)
        }.value
        guard reachable else {
            failed[kind, default: []].insert(path)
            return
        }
        do {
            let service = self.service
            let poster = try await withDeadline(seconds: Self.jobDeadlineSeconds) {
                try await service.fillWallAsset(kind, for: video)
            }
            finished[kind, default: []].insert(path)
            if let poster, video.thumbnailPath == nil {
                didMakePoster(video, poster)
            }
        } catch is CancellationError {
            return
        } catch {
            failed[kind, default: []].insert(path)
        }
    }
}
