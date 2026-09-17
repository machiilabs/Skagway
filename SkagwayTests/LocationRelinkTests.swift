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

        // Component-wise A–Z via comparePathsByComponents (not full-string path compare).
        let ordered = candidates.map(\.path)
        XCTAssertEqual(
            ordered,
            ordered.sorted { LocationRelink.comparePathsByComponents($0, $1) == .orderedAscending }
        )
    }

    func testComparePathsByComponentsMediaTreeBeforeMedia2() {
        // Passes with comparePathsByComponents; fails if sorted by full-path localizedCaseInsensitiveCompare
        // (space in "Media 2" sorts before '/' in "Media/…").
        XCTAssertEqual(
            LocationRelink.comparePathsByComponents("/Volumes/Media", "/Volumes/Media 2"),
            .orderedAscending
        )
        XCTAssertEqual(
            LocationRelink.comparePathsByComponents("/Volumes/Media/Shows", "/Volumes/Media 2"),
            .orderedAscending
        )
        XCTAssertEqual(
            LocationRelink.comparePathsByComponents("/Volumes/Media 2", "/Volumes/Media 2/Clips"),
            .orderedAscending
        )
        // Old full-string order wrongly ranks Media 2 before Media/Shows.
        XCTAssertEqual(
            "/Volumes/Media 2".localizedCaseInsensitiveCompare("/Volumes/Media/Shows"),
            .orderedAscending
        )
    }

    func testCollectOldRootCandidatesSortedAlphabetically() {
        let candidates = LocationRelink.collectOldRootCandidates(
            videoPaths: [
                "/Volumes/Media 2/Clips/x.mp4",
                "/Volumes/Media/Shows/a.mp4",
                "/Volumes/Media 2/Extra/b.mp4"
            ],
            dataSourceRoots: ["/Volumes/Media", "/Volumes/Media 2"]
        )
        let paths = candidates.map(\.path)
        let mediaIdx = paths.firstIndex(of: "/Volumes/Media")
        let mediaShowsIdx = paths.firstIndex(of: "/Volumes/Media/Shows")
        let media2Idx = paths.firstIndex(of: "/Volumes/Media 2")
        let media2ClipsIdx = paths.firstIndex(of: "/Volumes/Media 2/Clips")
        XCTAssertNotNil(mediaIdx)
        XCTAssertNotNil(mediaShowsIdx)
        XCTAssertNotNil(media2Idx)
        XCTAssertNotNil(media2ClipsIdx)
        XCTAssertLessThan(mediaIdx!, media2Idx!)
        XCTAssertLessThan(mediaShowsIdx!, media2Idx!)
        XCTAssertLessThan(media2Idx!, media2ClipsIdx!)
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

    func testRootsFromLocatedFolderUsesOrphanParentAndChosenFolder() {
        let ok = LocationRelink.rootsFromLocatedFolder(
            orphanPath: "/Volumes/Old/Shows/S1/ep1.mp4",
            locatedFolder: "/Volumes/New/Archive/Shows/S1"
        )
        switch ok {
        case .success(let roots):
            XCTAssertEqual(roots.oldRoot, "/Volumes/Old/Shows/S1")
            XCTAssertEqual(roots.newRoot, "/Volumes/New/Archive/Shows/S1")
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }

        let empty = LocationRelink.rootsFromLocatedFolder(orphanPath: "", locatedFolder: "/new")
        if case .failure(.emptyPath) = empty {
            // ok
        } else {
            XCTFail("expected emptyPath")
        }
    }

    func testFindMissingFolderRemapMatchesSiblingsByRelativeBasename() {
        // Orphan parent → chosen folder: siblings keep their own basenames under newRoot.
        let videos: [(Int64?, String, Int64)] = [
            (1, "/old/Lib/a.mp4", 10),
            (2, "/old/Lib/b.mp4", 20),
            (3, "/old/Lib/nested/c.mp4", 30)
        ]
        let roots = LocationRelink.rootsFromLocatedFolder(
            orphanPath: "/old/Lib/a.mp4",
            locatedFolder: "/new/Lib"
        )
        guard case .success(let pair) = roots else {
            XCTFail("roots"); return
        }
        XCTAssertEqual(pair.oldRoot, "/old/Lib")
        XCTAssertEqual(pair.newRoot, "/new/Lib")

        let preview = LocationRelink.buildPreview(
            videos: videos,
            oldRoot: pair.oldRoot,
            newRoot: pair.newRoot,
            existingLibraryPaths: Set(videos.map(\.1)),
            fileExists: { _ in true },
            fileSize: { path in
                switch path {
                case "/new/Lib/a.mp4": return 10
                case "/new/Lib/b.mp4": return 20
                case "/new/Lib/nested/c.mp4": return 30
                default: return nil
                }
            }
        )
        let applied = LocationRelink.mappingsToApply(preview: preview, includeNeedsAttention: true)
        XCTAssertEqual(Set(applied.map(\.newPath)), Set([
            "/new/Lib/a.mp4",
            "/new/Lib/b.mp4",
            "/new/Lib/nested/c.mp4"
        ]))
        XCTAssertFalse(applied.allSatisfy { $0.newPath == "/new/Lib/a.mp4" })
    }

    // MARK: - Banner situation + copy

    func testClassifyParentGoneWhenParentMissing() {
        let situation = LocationRelink.classifyMissingSituation(
            missingPaths: [
                "/Volumes/Gone/Media/a.mp4",
                "/Volumes/Gone/Media/b.mp4"
            ],
            fileExists: { _ in false }
        )
        if case .parentGone(let name) = situation {
            XCTAssertEqual(name, "Media")
        } else {
            XCTFail("expected parentGone, got \(situation)")
        }
        let copy = LocationRelink.bannerCopy(for: situation)
        XCTAssertEqual(copy.title, "Folder moved or missing")
        XCTAssertTrue(copy.body.contains("Media"))
        XCTAssertEqual(copy.cta, "Reconnect…")
        XCTAssertEqual(copy.icon, "folder.badge.questionmark")
    }

    func testClassifyParentPresentWhenParentExists() {
        let parent = "/Volumes/Live/Shows"
        let situation = LocationRelink.classifyMissingSituation(
            missingPaths: [
                "\(parent)/a.mp4",
                "\(parent)/b.mp4"
            ],
            focusPath: "\(parent)/a.mp4",
            fileExists: { $0 == parent || $0.hasPrefix("/Volumes/Live") }
        )
        if case .parentPresent(let count) = situation {
            XCTAssertEqual(count, 2)
        } else {
            XCTFail("expected parentPresent, got \(situation)")
        }
        let copy = LocationRelink.bannerCopy(for: situation)
        XCTAssertEqual(copy.title, "Some clips are missing")
        XCTAssertTrue(copy.body.hasPrefix("2 clips are gone"))
        XCTAssertEqual(copy.cta, "Reconnect…")
        XCTAssertEqual(copy.icon, "doc.badge.ellipsis")

        let single = LocationRelink.bannerCopy(for: .parentPresent(missingCount: 1))
        XCTAssertTrue(single.body.hasPrefix("1 clip is gone"))
        XCTAssertFalse(single.body.contains("1 clips"))
    }

    func testClassifyScatteredAcrossDistinctParents() {
        let situation = LocationRelink.classifyMissingSituation(
            missingPaths: [
                "/Volumes/A/One/a.mp4",
                "/Volumes/B/Two/b.mp4"
            ],
            fileExists: { _ in false }
        )
        XCTAssertEqual(situation, .scattered)
        let copy = LocationRelink.bannerCopy(for: situation)
        XCTAssertEqual(copy.title, "Clips moved to different places")
        XCTAssertEqual(copy.cta, "Reconnect…")
        XCTAssertEqual(copy.icon, "folder.badge.gearshape")
    }

    func testBannerCopyPrefersBOverAWhenParentExistsWithoutSharedRoot() {
        // Single parent that exists → parentPresent even if inferSharedMissingRoot is thin.
        let parent = "/Users/sam/Films/Action"
        let situation = LocationRelink.classifyMissingSituation(
            missingPaths: ["\(parent)/only.mp4"],
            fileExists: { $0 == parent }
        )
        if case .parentPresent = situation {
            // ok
        } else {
            XCTFail("expected parentPresent, got \(situation)")
        }
    }

    // MARK: - Evidence Destinations multi-dest

    func testMultiDestBasenameMatchAcrossTwoFolders() {
        let videos: [(Int64?, String, Int64)] = [
            (1, "/old/Lib/drone.mp4", 100),
            (2, "/old/Other/wedding.mp4", 200),
            (3, "/old/Lib/gone.mp4", 50)
        ]
        let destA = LocationRelink.DestinationIndex(
            root: "/Volumes/Media2/Drone",
            byBasename: [
                "drone.mp4": [
                    LocationRelink.IndexedFile(
                        path: "/Volumes/Media2/Drone/drone.mp4",
                        basename: "drone.mp4",
                        size: 100
                    )
                ]
            ]
        )
        let destB = LocationRelink.DestinationIndex(
            root: "/Volumes/Archive/Weddings",
            byBasename: [
                "wedding.mp4": [
                    LocationRelink.IndexedFile(
                        path: "/Volumes/Archive/Weddings/wedding.mp4",
                        basename: "wedding.mp4",
                        size: 200
                    )
                ]
            ]
        )
        let preview = LocationRelink.buildSessionPreview(
            videos: videos,
            wholeFolder: nil,
            destinationIndexes: [destA, destB],
            existingLibraryPaths: Set(videos.map(\.1)),
            fileExists: { _ in true },
            fileSize: { path in
                switch path {
                case "/Volumes/Media2/Drone/drone.mp4": return 100
                case "/Volumes/Archive/Weddings/wedding.mp4": return 200
                default: return nil
                }
            }
        )
        XCTAssertEqual(preview.reconnectCount, 2)
        XCTAssertEqual(preview.stillMissingCount, 1)
        XCTAssertFalse(preview.hasWholeFolderRemap)
        let applied = LocationRelink.mappingsToApply(preview: preview, includeNeedsAttention: false)
        XCTAssertEqual(Set(applied.map(\.newPath)), Set([
            "/Volumes/Media2/Drone/drone.mp4",
            "/Volumes/Archive/Weddings/wedding.mp4"
        ]))

        let grouped = LocationRelink.groupEvidenceCandidates(preview.candidates)
        XCTAssertEqual(grouped.unmatched.count, 1)
        XCTAssertEqual(grouped.byDestination.count, 2)
    }

    func testMultiDestAmbiguousBasenameNeedsAttention() {
        let videos: [(Int64?, String, Int64)] = [
            (1, "/old/clip_001.mp4", 100)
        ]
        let dest = LocationRelink.DestinationIndex(
            root: "/Volumes/Pool",
            byBasename: [
                "clip_001.mp4": [
                    LocationRelink.IndexedFile(
                        path: "/Volumes/Pool/A/clip_001.mp4",
                        basename: "clip_001.mp4",
                        size: 100
                    ),
                    LocationRelink.IndexedFile(
                        path: "/Volumes/Pool/B/clip_001.mp4",
                        basename: "clip_001.mp4",
                        size: 999
                    )
                ]
            ]
        )
        let preview = LocationRelink.buildSessionPreview(
            videos: videos,
            wholeFolder: nil,
            destinationIndexes: [dest],
            existingLibraryPaths: Set(videos.map(\.1))
        )
        XCTAssertEqual(preview.needsAttentionCount, 1)
        XCTAssertEqual(preview.reconnectCount, 0)
        if case .needsAttention(let reason) = preview.candidates[0].kind {
            XCTAssertTrue(reason.contains("2 matches"))
        } else {
            XCTFail("expected needsAttention")
        }
    }

    func testNestedDestinationsDoNotDuplicateIdenticalPaths() {
        // C nested under B: same file indexed under both destinations must stay Ready (1 unique path).
        let nestedPath = "/Volumes/Media2/B/C/saigon.mp4"
        let videos: [(Int64?, String, Int64)] = [
            (1, "/old/Lib/saigon.mp4", 100),
            (2, "/old/Lib/other.mp4", 200)
        ]
        let destC = LocationRelink.DestinationIndex(
            root: "/Volumes/Media2/B/C",
            byBasename: [
                "saigon.mp4": [
                    LocationRelink.IndexedFile(path: nestedPath, basename: "saigon.mp4", size: 100)
                ]
            ]
        )
        let destB = LocationRelink.DestinationIndex(
            root: "/Volumes/Media2/B",
            byBasename: [
                "saigon.mp4": [
                    LocationRelink.IndexedFile(path: nestedPath, basename: "saigon.mp4", size: 100)
                ],
                "other.mp4": [
                    LocationRelink.IndexedFile(
                        path: "/Volumes/Media2/B/other.mp4",
                        basename: "other.mp4",
                        size: 200
                    )
                ]
            ]
        )
        let preview = LocationRelink.buildSessionPreview(
            videos: videos,
            wholeFolder: nil,
            destinationIndexes: [destC, destB],
            existingLibraryPaths: Set(videos.map(\.1))
        )
        XCTAssertEqual(preview.reconnectCount, 2)
        XCTAssertEqual(preview.needsAttentionCount, 0)
        let saigon = preview.candidates.first { $0.oldPath.hasSuffix("saigon.mp4") }
        XCTAssertEqual(saigon?.kind, .reconnect)
        XCTAssertEqual(LocationRelink.normalizeRoot(saigon?.newPath ?? ""), nestedPath)
        if case .evidenceDestination(let root) = saigon?.matchSource {
            // Prefer nested C for grouping when path is identical.
            XCTAssertEqual(root, "/Volumes/Media2/B/C")
        } else {
            XCTFail("expected evidenceDestination matchSource")
        }
    }

    func testUniqueEvidenceHitsDedupesIdenticalPathsAcrossDestinations() {
        let path = "/Volumes/Media2/B/C/clip.mp4"
        let hits: [(destination: String, file: LocationRelink.IndexedFile)] = [
            (
                "/Volumes/Media2/B/C",
                LocationRelink.IndexedFile(path: path, basename: "clip.mp4", size: 1)
            ),
            (
                "/Volumes/Media2/B",
                LocationRelink.IndexedFile(path: path + "/", basename: "clip.mp4", size: 1)
            ),
            (
                "/Volumes/Media2/B",
                LocationRelink.IndexedFile(path: path, basename: "clip.mp4", size: 1)
            )
        ]
        let unique = LocationRelink.uniqueEvidenceHits(hits)
        XCTAssertEqual(unique.count, 1)
        XCTAssertEqual(unique[0].destination, "/Volumes/Media2/B/C")
        XCTAssertEqual(LocationRelink.normalizeRoot(unique[0].file.path), path)
    }

    func testSessionPreviewWholeFolderThenDestinationsForLeftovers() {
        let videos: [(Int64?, String, Int64)] = [
            (1, "/old/Lib/keep/a.mp4", 10),
            (2, "/old/Lib/keep/b.mp4", 20),
            (3, "/old/Elsewhere/c.mp4", 30)
        ]
        let dest = LocationRelink.DestinationIndex(
            root: "/new/Extra",
            byBasename: [
                "c.mp4": [
                    LocationRelink.IndexedFile(path: "/new/Extra/c.mp4", basename: "c.mp4", size: 30)
                ]
            ]
        )
        let preview = LocationRelink.buildSessionPreview(
            videos: videos,
            wholeFolder: (oldRoot: "/old/Lib", newRoot: "/new/Lib"),
            destinationIndexes: [dest],
            existingLibraryPaths: Set(videos.map(\.1)),
            fileExists: { path in
                path == "/new/Lib/keep/a.mp4"
                    || path == "/new/Lib/keep/b.mp4"
                    || path == "/new/Extra/c.mp4"
            },
            fileSize: { path in
                switch path {
                case "/new/Lib/keep/a.mp4": return 10
                case "/new/Lib/keep/b.mp4": return 20
                case "/new/Extra/c.mp4": return 30
                default: return nil
                }
            }
        )
        XCTAssertTrue(preview.hasWholeFolderRemap)
        XCTAssertEqual(preview.reconnectCount, 3)
        let applied = Set(LocationRelink.mappingsToApply(preview: preview, includeNeedsAttention: true).map(\.newPath))
        XCTAssertEqual(applied, Set([
            "/new/Lib/keep/a.mp4",
            "/new/Lib/keep/b.mp4",
            "/new/Extra/c.mp4"
        ]))
    }

    func testReconnectModeSuggestedFromSituation() {
        XCTAssertEqual(
            LocationRelink.ReconnectMode.suggested(for: .parentGone(folderName: "X")),
            .destinations
        )
        XCTAssertEqual(
            LocationRelink.ReconnectMode.suggested(for: .parentPresent(missingCount: 3)),
            .destinations
        )
        XCTAssertEqual(
            LocationRelink.ReconnectMode.suggested(for: .scattered),
            .destinations
        )
    }
}
