import XCTest
@testable import Skagway

final class LocationRelinkTests: XCTestCase {

    func testNormalizeRootStripsTrailingSlash() {
        XCTAssertEqual(LocationRelink.normalizeRoot("/Volumes/Media/Videos/"), "/Volumes/Media/Videos")
        XCTAssertEqual(LocationRelink.normalizeRoot("/"), "/")
    }

    func testIsUnderRequiresBoundary() {
        XCTAssertTrue(LocationRelink.isUnder(root: "/Videos", path: "/Videos/a.mp4"))
        XCTAssertTrue(LocationRelink.isUnder(root: "/Videos", path: "/Videos"))
        XCTAssertFalse(LocationRelink.isUnder(root: "/Videos", path: "/Videos-backup/a.mp4"))
    }

    func testRelativeAndJoinRoundTrip() {
        let rel = LocationRelink.relativePath(under: "/Volumes/A/Lib", fullPath: "/Volumes/A/Lib/Shows/x.mp4")
        XCTAssertEqual(rel, "Shows/x.mp4")
        XCTAssertEqual(
            LocationRelink.join(root: "/Volumes/B/Lib", relative: rel!),
            "/Volumes/B/Lib/Shows/x.mp4"
        )
    }

    func testInferSharedMissingRootFromCommonPrefix() {
        let root = LocationRelink.inferSharedMissingRoot(
            missingPaths: [
                "/Volumes/Old/Media/a/1.mp4",
                "/Volumes/Old/Media/b/2.mp4"
            ]
        )
        XCTAssertEqual(root, "/Volumes/Old/Media")
    }

    func testInferSharedMissingRootPrefersDataSource() {
        let root = LocationRelink.inferSharedMissingRoot(
            missingPaths: [
                "/Volumes/Old/Media/a/1.mp4",
                "/Volumes/Old/Media/b/2.mp4"
            ],
            dataSourceRoots: ["/Volumes/Old/Media"]
        )
        // Data source folder itself is missing on this machine → preferred.
        // If `/Volumes/Old/Media` exists in the test environment, fallback still yields same prefix.
        XCTAssertEqual(root, "/Volumes/Old/Media")
    }

    func testPreviewCountsReconnectAttentionMissing() {
        let videos: [(Int64?, String, Int64)] = [
            (1, "/old/Lib/ok.mp4", 100),
            (2, "/old/Lib/size.mp4", 200),
            (3, "/old/Lib/gone.mp4", 50)
        ]
        let exists: Set<String> = ["/new/Lib/ok.mp4", "/new/Lib/size.mp4"]
        let sizes: [String: Int64] = [
            "/new/Lib/ok.mp4": 100,
            "/new/Lib/size.mp4": 999
        ]
        let preview = LocationRelink.buildPreview(
            videos: videos,
            oldRoot: "/old/Lib",
            newRoot: "/new/Lib",
            existingLibraryPaths: Set(videos.map(\.1)),
            fileExists: { exists.contains($0) },
            fileSize: { sizes[$0] }
        )
        XCTAssertEqual(preview.reconnectCount, 1)
        XCTAssertEqual(preview.needsAttentionCount, 1)
        XCTAssertEqual(preview.stillMissingCount, 1)

        let apply = LocationRelink.mappingsToApply(preview: preview, includeNeedsAttention: false)
        XCTAssertEqual(apply.map(\.newPath), ["/new/Lib/ok.mp4"])

        let applyAll = LocationRelink.mappingsToApply(preview: preview, includeNeedsAttention: true)
        XCTAssertEqual(Set(applyAll.map(\.newPath)), Set(["/new/Lib/ok.mp4", "/new/Lib/size.mp4"]))
    }

    func testPreviewFlagsLibraryPathCollision() {
        let videos: [(Int64?, String, Int64)] = [
            (1, "/old/Lib/a.mp4", 10)
        ]
        let preview = LocationRelink.buildPreview(
            videos: videos,
            oldRoot: "/old/Lib",
            newRoot: "/new/Lib",
            existingLibraryPaths: ["/old/Lib/a.mp4", "/new/Lib/a.mp4"],
            fileExists: { $0 == "/new/Lib/a.mp4" },
            fileSize: { _ in 10 }
        )
        XCTAssertEqual(preview.needsAttentionCount, 1)
        if case .needsAttention(let reason) = preview.candidates[0].kind {
            XCTAssertTrue(reason.lowercased().contains("already"))
        } else {
            XCTFail("expected needsAttention")
        }
    }

    func testRemapFolderPath() {
        XCTAssertEqual(
            LocationRelink.remapFolderPath("/old/Lib/Sub", oldRoot: "/old/Lib", newRoot: "/new/Lib"),
            "/new/Lib/Sub"
        )
        XCTAssertNil(
            LocationRelink.remapFolderPath("/elsewhere", oldRoot: "/old/Lib", newRoot: "/new/Lib")
        )
    }

    func testCollectOldRootCandidatesIncludesDataSourceAndNestedFolders() {
        let candidates = LocationRelink.collectOldRootCandidates(
            videoPaths: [
                "/Volumes/Old/Media/Shows/S1/ep1.mp4",
                "/Volumes/Old/Media/Shows/S1/ep2.mp4",
                "/Volumes/Old/Media/Movies/a.mp4"
            ],
            dataSourceRoots: ["/Volumes/Old/Media"]
        )
        let paths = Set(candidates.map(\.path))
        XCTAssertTrue(paths.contains("/Volumes/Old/Media"))
        XCTAssertTrue(paths.contains("/Volumes/Old/Media/Shows"))
        XCTAssertTrue(paths.contains("/Volumes/Old/Media/Shows/S1"))
        XCTAssertTrue(paths.contains("/Volumes/Old/Media/Movies"))

        let media = candidates.first { $0.path == "/Volumes/Old/Media" }
        XCTAssertEqual(media?.videoCount, 3)
        XCTAssertTrue(media?.sources.contains(.dataSource) == true)

        let s1 = candidates.first { $0.path == "/Volumes/Old/Media/Shows/S1" }
        XCTAssertEqual(s1?.videoCount, 2)

        // Component-wise A–Z (not naive full-string — that puts "Media 2" before "Media/…").
        let ordered = candidates.map(\.path)
        XCTAssertEqual(
            ordered,
            ordered.sorted { LocationRelink.comparePathComponentWise($0, $1) == .orderedAscending }
        )
    }

    func testCollectOldRootCandidatesSortedAlphabetically() {
        let candidates = LocationRelink.collectOldRootCandidates(
            videoPaths: [
                "/Volumes/Z/Lib/a.mp4",
                "/Volumes/A/Lib/b.mp4",
                "/Volumes/M/Lib/c.mp4"
            ],
            dataSourceRoots: ["/Volumes/Z/Lib", "/Volumes/A/Lib", "/Volumes/M/Lib"]
        )
        let roots = candidates.map(\.path).filter {
            $0 == "/Volumes/A/Lib" || $0 == "/Volumes/M/Lib" || $0 == "/Volumes/Z/Lib"
        }
        XCTAssertEqual(roots, ["/Volumes/A/Lib", "/Volumes/M/Lib", "/Volumes/Z/Lib"])
    }

    func testComparePathComponentWiseMediaBeforeMedia2() {
        // Required cases — component-wise, NOT full-string localizedCaseInsensitiveCompare.
        XCTAssertEqual(
            LocationRelink.comparePathComponentWise("/Volumes/Media", "/Volumes/Media 2"),
            .orderedAscending
        )
        XCTAssertEqual(
            LocationRelink.comparePathComponentWise("/Volumes/Media/Shows", "/Volumes/Media 2"),
            .orderedAscending
        )
        XCTAssertEqual(
            LocationRelink.comparePathComponentWise("/Volumes/Media 2", "/Volumes/Media 2/Clips"),
            .orderedAscending
        )
        // Extra: shorter equal-prefix before longer; spaced sibling after tree.
        XCTAssertEqual(
            LocationRelink.comparePathComponentWise("/Volumes/Media", "/Volumes/Media/Shows"),
            .orderedAscending
        )
        XCTAssertEqual(
            LocationRelink.comparePathComponentWise("/Volumes/Media 2", "/Volumes/Media/Shows"),
            .orderedDescending
        )
    }

    func testCollectOldRootCandidatesOrdersMediaBeforeMedia2() {
        let candidates = LocationRelink.collectOldRootCandidates(
            videoPaths: [
                "/Volumes/Media/Shows/a.mp4",
                "/Volumes/Media 2/Extra/b.mp4"
            ],
            dataSourceRoots: ["/Volumes/Media", "/Volumes/Media 2"]
        )
        let paths = candidates.map(\.path)
        let mediaIdx = paths.firstIndex(of: "/Volumes/Media")
        let mediaShowsIdx = paths.firstIndex(of: "/Volumes/Media/Shows")
        let media2Idx = paths.firstIndex(of: "/Volumes/Media 2")
        XCTAssertNotNil(mediaIdx)
        XCTAssertNotNil(mediaShowsIdx)
        XCTAssertNotNil(media2Idx)
        XCTAssertLessThan(mediaIdx!, media2Idx!)
        XCTAssertLessThan(mediaShowsIdx!, media2Idx!)
    }

    func testCollectOldRootCandidatesWithoutDataSourceUsesParents() {
        let candidates = LocationRelink.collectOldRootCandidates(
            videoPaths: ["/Users/sam/Films/Action/a.mp4", "/Users/sam/Films/Drama/b.mp4"],
            dataSourceRoots: []
        )
        let paths = Set(candidates.map(\.path))
        XCTAssertTrue(paths.contains("/Users/sam/Films"))
        XCTAssertTrue(paths.contains("/Users/sam/Films/Action"))
        XCTAssertFalse(paths.contains("/Users/sam")) // too broad
    }

    func testIsSelectableOldRootRejectsShallowPaths() {
        XCTAssertFalse(LocationRelink.isSelectableOldRoot("/"))
        XCTAssertFalse(LocationRelink.isSelectableOldRoot("/Volumes"))
        XCTAssertFalse(LocationRelink.isSelectableOldRoot("/Users/sam"))
        XCTAssertTrue(LocationRelink.isSelectableOldRoot("/Volumes/Disk"))
        XCTAssertTrue(LocationRelink.isSelectableOldRoot("/Users/sam/Films"))
    }
}
