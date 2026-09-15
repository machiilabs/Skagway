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
}
