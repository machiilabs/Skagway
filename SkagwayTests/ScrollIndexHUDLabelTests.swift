import XCTest
@testable import Skagway

final class ScrollIndexHUDLabelTests: XCTestCase {
    func testIndexIsO1FractionLookup() {
        XCTAssertNil(ScrollIndexHUDLabel.index(fraction: 0.5, count: 0))
        XCTAssertEqual(ScrollIndexHUDLabel.index(fraction: 0.9, count: 1), 0)
        XCTAssertEqual(ScrollIndexHUDLabel.index(fraction: 0, count: 11), 0)
        XCTAssertEqual(ScrollIndexHUDLabel.index(fraction: 1, count: 11), 10)
        XCTAssertEqual(ScrollIndexHUDLabel.index(fraction: 0.5, count: 11), 5)
        XCTAssertEqual(ScrollIndexHUDLabel.index(fraction: -1, count: 8), 0)
        XCTAssertEqual(ScrollIndexHUDLabel.index(fraction: 2, count: 8), 7)
    }

    func testTitleUsesFirstLetter() {
        let video = TestVideo.make(path: "/Movies/alpha.mp4", title: "glacier")
        XCTAssertEqual(
            ScrollIndexHUDLabel.text(sort: .title, video: video, index: 0, count: 1),
            "G"
        )
        XCTAssertEqual(ScrollIndexHUDLabel.titleLetter("12 Angry Men"), "0–9")
        XCTAssertEqual(ScrollIndexHUDLabel.titleLetter("…ellipsis"), "#")
        XCTAssertEqual(ScrollIndexHUDLabel.titleLetter("  "), "•")
    }

    func testDurationBucketsMatchQuickFilterPresets() {
        XCTAssertEqual(ScrollIndexHUDLabel.durationBucket(30), "< 1 min")
        XCTAssertEqual(ScrollIndexHUDLabel.durationBucket(60), "1–5 min")
        XCTAssertEqual(ScrollIndexHUDLabel.durationBucket(4 * 60), "1–5 min")
        XCTAssertEqual(ScrollIndexHUDLabel.durationBucket(5 * 60), "5–30 min")
        XCTAssertEqual(ScrollIndexHUDLabel.durationBucket(29 * 60), "5–30 min")
        XCTAssertEqual(ScrollIndexHUDLabel.durationBucket(30 * 60), "> 30 min")
        XCTAssertEqual(ScrollIndexHUDLabel.durationBucket(nil), "—")
    }

    func testRatingAndAlbumAndFolder() {
        let unrated = TestVideo.make(path: "/Volumes/Media/Alaska/clip.mp4", rating: 0)
        XCTAssertEqual(
            ScrollIndexHUDLabel.text(sort: .rating, video: unrated, index: 0, count: 10),
            "Unrated"
        )
        var rated = unrated
        rated.rating = 4
        XCTAssertEqual(
            ScrollIndexHUDLabel.text(sort: .rating, video: rated, index: 0, count: 10),
            "★★★★"
        )
        XCTAssertEqual(
            ScrollIndexHUDLabel.text(sort: .albumOrder, video: unrated, index: 11, count: 40),
            "#12 of 40"
        )
        XCTAssertEqual(
            ScrollIndexHUDLabel.text(sort: .parentFolder, video: unrated, index: 0, count: 1),
            "Alaska"
        )
    }

    func testDateFollowsAbbreviatedDay() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let video = TestVideo.make(path: "/a.mp4", dateAdded: date)
        XCTAssertEqual(
            ScrollIndexHUDLabel.text(sort: .dateAdded, video: video, index: 0, count: 1),
            date.formatted(date: .abbreviated, time: .omitted)
        )
    }

    func testSortResolutionFollowsCurrentSort() {
        XCTAssertEqual(
            ScrollIndexHUDLabel.sort(
                isRandomOrder: true,
                isShowingAlbumOrder: false,
                hasCustomSort: false,
                keyPath: \Video.displayTitle
            ),
            .random
        )
        XCTAssertEqual(
            ScrollIndexHUDLabel.sort(
                isRandomOrder: false,
                isShowingAlbumOrder: true,
                hasCustomSort: false,
                keyPath: \Video.dateAdded
            ),
            .albumOrder
        )
        XCTAssertEqual(
            ScrollIndexHUDLabel.sort(
                isRandomOrder: false,
                isShowingAlbumOrder: false,
                hasCustomSort: true,
                keyPath: \Video.dateAdded
            ),
            .custom
        )
        XCTAssertEqual(
            ScrollIndexHUDLabel.sort(
                isRandomOrder: false,
                isShowingAlbumOrder: false,
                hasCustomSort: false,
                keyPath: \Video.displayTitle
            ),
            .title
        )
        XCTAssertEqual(
            ScrollIndexHUDLabel.sort(
                isRandomOrder: false,
                isShowingAlbumOrder: false,
                hasCustomSort: false,
                keyPath: \Video.sortableDuration
            ),
            .duration
        )
        XCTAssertEqual(
            ScrollIndexHUDLabel.sort(
                isRandomOrder: false,
                isShowingAlbumOrder: false,
                hasCustomSort: false,
                keyPath: \Video.filePath
            ),
            .parentFolder
        )
    }
}
