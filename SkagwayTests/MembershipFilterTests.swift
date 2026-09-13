import GRDB
import XCTest
@testable import Skagway

final class MembershipFilterTests: XCTestCase {
    private func makeRepo() throws -> CollectionRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("skagway-membership-test-\(UUID().uuidString).machii")
        try DatabaseMigration.createEmptyDatabase(at: url.path)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        return CollectionRepository(dbPool: pool)
    }
    private func membershipCondition(
        _ target: MembershipTarget,
        comparison: RuleComparison = .isMemberOf
    ) -> FilterCondition {
        FilterCondition(
            field: .builtin(.membership),
            comparison: comparison,
            value: target.storageToken
        )
    }

    private func context(
        duplicateVideoIds: Set<String> = [],
        missingVideoIds: Set<String> = [],
        topRatedMinRating: Int = 4,
        albumMembers: [Int64: [Int64]] = [:]
    ) -> LibraryFilterContext {
        LibraryFilterContext.from(
            duplicateVideoIds: duplicateVideoIds,
            missingVideoIds: missingVideoIds,
            recentlyAddedDays: 7,
            recentlyPlayedDays: 30,
            topRatedMinRating: topRatedMinRating,
            recentlyConvertedDates: [:],
            recentlyAppliedPaths: [],
            lastAddedPaths: [],
            thumbnailsSettled: true,
            cachedAlbumVideoIds: albumMembers
        )
    }

    func testTopRatedSmartLibraryMembership() throws {
        let video = TestVideo.make(path: "/a.mp4", rating: 5)
        let group = FilterGroup(mode: .all, nodes: [
            .condition(membershipCondition(.smartLibrary(.topRated))),
        ])
        let matcher = FilterMatcher(
            group: group,
            customFields: [:],
            libraryContext: context(topRatedMinRating: 4),
            collectionRepo: try makeRepo()
        )
        XCTAssertTrue(matcher.matches(video, tags: [], customValues: [:]))
    }

    func testAlbumMembership() throws {
        let video = TestVideo.make(path: "/a.mp4", databaseId: 42)
        let group = FilterGroup(mode: .all, nodes: [
            .condition(membershipCondition(.album(7))),
        ])
        let matcher = FilterMatcher(
            group: group,
            customFields: [:],
            libraryContext: context(albumMembers: [7: [42]]),
            collectionRepo: try makeRepo()
        )
        XCTAssertTrue(matcher.matches(video, tags: [], customValues: [:]))
    }

    func testMembershipSummaryUsesHumanLabels() {
        let group = FilterGroup(mode: .all, nodes: [
            .condition(membershipCondition(.smartLibrary(.corrupt))),
        ])
        let summary = FilterSummaryFormatter.filterGroupSummary(group, customFields: [:])
        XCTAssertEqual(summary, "Membership is member of Corrupt")
    }

    func testIsNotMemberOfNegatesMatch() throws {
        let video = TestVideo.make(path: "/dup.mp4")
        let group = FilterGroup(mode: .all, nodes: [
            .condition(membershipCondition(.smartLibrary(.duplicates), comparison: .isNotMemberOf)),
        ])
        let matcher = FilterMatcher(
            group: group,
            customFields: [:],
            libraryContext: context(duplicateVideoIds: [video.id]),
            collectionRepo: try makeRepo()
        )
        XCTAssertFalse(matcher.matches(video, tags: [], customValues: [:]))
    }

    func testLegacyCollectionMembershipTokenIsInvalid() {
        XCTAssertNil(MembershipTarget(storageToken: "collection:9"))
    }
}
