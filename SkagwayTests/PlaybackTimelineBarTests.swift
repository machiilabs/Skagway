import XCTest
@testable import Skagway

final class PlaybackTimelineBarTests: XCTestCase {
    func testBarHeightWithoutFilmstripIsScrubPlusTransport() {
        XCTAssertEqual(PlaybackTimelineBar.baseBarHeight, 56)
        XCTAssertEqual(
            PlaybackTimelineBar.barHeight(showFilmstrip: false, thinFilmstrip: false),
            PlaybackTimelineBar.baseBarHeight
        )
        XCTAssertEqual(
            PlaybackTimelineBar.barHeight(showFilmstrip: false, thinFilmstrip: true),
            PlaybackTimelineBar.baseBarHeight
        )
    }

    func testBarHeightAddsNormalOrThinFilmstrip() {
        XCTAssertEqual(
            PlaybackTimelineBar.barHeight(showFilmstrip: true, thinFilmstrip: false),
            PlaybackTimelineBar.baseBarHeight + PlaybackTimelineBar.filmstripStripHeight
        )
        XCTAssertEqual(
            PlaybackTimelineBar.barHeight(showFilmstrip: true, thinFilmstrip: true),
            PlaybackTimelineBar.baseBarHeight + PlaybackTimelineBar.filmstripStripHeightThin
        )
        XCTAssertEqual(PlaybackTimelineBar.filmstripStripHeight, 54)
        XCTAssertEqual(PlaybackTimelineBar.filmstripStripHeightThin, 36)
        XCTAssertEqual(PlaybackTimelineBar.barHeight, PlaybackTimelineBar.baseBarHeight + 54)
    }
}
