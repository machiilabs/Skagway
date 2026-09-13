import XCTest
@testable import Skagway

final class QuickFilterCompilerTests: XCTestCase {
    private func tag(_ id: Int64, _ name: String) -> Tag {
        Tag(id: id, name: name)
    }

    private func parentFolderEquals(_ name: String) -> FilterCondition {
        FilterCondition(field: .builtin(.parentFolder), comparison: .equals, value: name)
    }

    func testCollectionTagsAnyAndRatingOrHigher() {
        let collectionGroup = FilterGroup(mode: .all, nodes: [
            .group(FilterGroup(mode: .all, nodes: [
                .condition(parentFolderEquals("Demo")),
            ])),
        ])
        let input = QuickFilterCompiler.Input(
            sidebarFilter: .collection(VideoCollection(id: 1, name: "Demo", dateCreated: Date())),
            collectionGroup: collectionGroup,
            tags: [tag(1, "trees"), tag(2, "outdoor")],
            selectedTagIds: [1, 2],
            tagFilterMode: .any,
            selectedRatingStars: [4],
            ratingFilterOrHigher: true,
            minDurationSeconds: nil,
            maxDurationSeconds: nil,
            selectedQualityBuckets: [],
            topRatedMinRating: 4
        )

        guard let group = QuickFilterCompiler.compile(input) else {
            return XCTFail("Expected compiled group")
        }

        XCTAssertEqual(group.mode, .all)
        XCTAssertEqual(group.nodes.count, 3)

        guard case .condition(let folder) = group.nodes[0] else {
            return XCTFail("Expected parent folder condition")
        }
        XCTAssertEqual(folder.field, .builtin(.parentFolder))
        XCTAssertEqual(folder.value, "Demo")

        guard case .group(let tags) = group.nodes[1] else {
            return XCTFail("Expected tag group")
        }
        XCTAssertEqual(tags.mode, .any)
        XCTAssertEqual(tags.nodes.count, 2)

        guard case .condition(let rating) = group.nodes[2] else {
            return XCTFail("Expected rating condition")
        }
        XCTAssertEqual(rating.field, .builtin(.rating))
        XCTAssertEqual(rating.comparison, .greaterThanOrEqual)
        XCTAssertEqual(rating.value, "4")
    }

    func testTagsAllModeUsesAllGroup() {
        let input = QuickFilterCompiler.Input(
            sidebarFilter: .all,
            collectionGroup: nil,
            tags: [tag(1, "a"), tag(2, "b")],
            selectedTagIds: [1, 2],
            tagFilterMode: .all,
            selectedRatingStars: [],
            ratingFilterOrHigher: false,
            minDurationSeconds: nil,
            maxDurationSeconds: nil,
            selectedQualityBuckets: [],
            topRatedMinRating: 4
        )

        guard let group = QuickFilterCompiler.compile(input),
              case .group(let tags) = group.nodes.first else {
            return XCTFail("Expected tag group")
        }
        XCTAssertEqual(tags.mode, .all)
    }

    func testEmptyQuickFiltersReturnNil() {
        let input = QuickFilterCompiler.Input(
            sidebarFilter: .all,
            collectionGroup: nil,
            tags: [],
            selectedTagIds: [],
            tagFilterMode: .any,
            selectedRatingStars: [],
            ratingFilterOrHigher: false,
            minDurationSeconds: nil,
            maxDurationSeconds: nil,
            selectedQualityBuckets: [],
            topRatedMinRating: 4
        )
        XCTAssertNil(QuickFilterCompiler.compile(input))
    }

    func testSidebarSmartLibraryCompilesToMembership() {
        let input = QuickFilterCompiler.Input(
            sidebarFilter: .corrupt,
            collectionGroup: nil,
            tags: [],
            selectedTagIds: [],
            tagFilterMode: .any,
            selectedRatingStars: [],
            ratingFilterOrHigher: false,
            minDurationSeconds: nil,
            maxDurationSeconds: nil,
            selectedQualityBuckets: [],
            topRatedMinRating: 4
        )
        guard let group = QuickFilterCompiler.compile(input),
              case .condition(let condition) = group.nodes.first else {
            return XCTFail("Expected membership condition")
        }
        XCTAssertEqual(condition.value, "smartLibrary:corrupt")
    }
}
