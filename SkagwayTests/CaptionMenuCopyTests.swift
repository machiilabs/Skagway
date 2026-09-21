import XCTest
@testable import Skagway

final class CaptionMenuCopyTests: XCTestCase {
    func testGenericMediaGroupNamesAreRejected() {
        XCTAssertTrue(CaptionMenuCopy.isGenericMediaGroupName("Media group 1"))
        XCTAssertTrue(CaptionMenuCopy.isGenericMediaGroupName("Media Group"))
        XCTAssertTrue(CaptionMenuCopy.isGenericMediaGroupName("media group 12"))
        XCTAssertFalse(CaptionMenuCopy.isGenericMediaGroupName("English"))
        XCTAssertFalse(CaptionMenuCopy.isGenericMediaGroupName("English SDH"))
        XCTAssertFalse(CaptionMenuCopy.isGenericMediaGroupName("Media"))
    }

    func testResolvedTitlePrefersRealDisplayName() {
        XCTAssertEqual(
            CaptionMenuCopy.resolvedTitle(displayName: "English SDH", languageName: "French", isSDH: true),
            "English SDH"
        )
    }

    func testResolvedTitleFallsBackToLanguageAndSDH() {
        XCTAssertEqual(
            CaptionMenuCopy.resolvedTitle(displayName: "Media group 1", languageName: "English", isSDH: true),
            "English SDH"
        )
        XCTAssertEqual(
            CaptionMenuCopy.resolvedTitle(displayName: "Media group 1", languageName: "English", isSDH: false),
            "English"
        )
        XCTAssertEqual(
            CaptionMenuCopy.resolvedTitle(displayName: "Media group 1", languageName: nil, isSDH: true),
            "SDH"
        )
        XCTAssertEqual(
            CaptionMenuCopy.resolvedTitle(displayName: "Media group 1", languageName: nil, isSDH: false),
            "Captions"
        )
    }

    func testLanguageNameUsesLocaleLanguageCode() {
        let name = CaptionMenuCopy.languageName(locale: Locale(identifier: "en"), extendedLanguageTag: nil)
        XCTAssertEqual(name, Locale.current.localizedString(forLanguageCode: "en"))
    }

    func testStableIDIncludesIndexLanguageAndFlags() {
        let english = CaptionMenuCopy.stableID(
            index: 0,
            displayName: "English",
            languageTag: "en",
            isSDH: false,
            isForced: false
        )
        let englishSDH = CaptionMenuCopy.stableID(
            index: 0,
            displayName: "English",
            languageTag: "en",
            isSDH: true,
            isForced: false
        )
        let secondTrack = CaptionMenuCopy.stableID(
            index: 1,
            displayName: "English",
            languageTag: "en",
            isSDH: false,
            isForced: false
        )
        XCTAssertEqual(english, "0|en|English||")
        XCTAssertEqual(englishSDH, "0|en|English|sdh|")
        XCTAssertNotEqual(english, englishSDH)
        XCTAssertNotEqual(english, secondTrack)
    }

    func testStableIDTreatsNilLanguageTagAsEmptyAndMarksForced() {
        XCTAssertEqual(
            CaptionMenuCopy.stableID(
                index: 2,
                displayName: "Captions",
                languageTag: nil,
                isSDH: false,
                isForced: true
            ),
            "2||Captions||forced"
        )
    }
}
