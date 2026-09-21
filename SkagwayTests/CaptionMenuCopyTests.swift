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
}
