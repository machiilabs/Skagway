import XCTest
@testable import Skagway

final class CollectionSummaryTests: XCTestCase {
    private func tagEquals(_ name: String) -> FilterCondition {
        FilterCondition(field: .builtin(.tag), comparison: .equals, value: name)
    }

    private func ratingAtLeast(_ n: Int) -> FilterCondition {
        FilterCondition(field: .builtin(.rating), comparison: .greaterThanOrEqual, value: String(n))
    }

    func testFullSynopsisForFewConditions() {
        let group = FilterGroup(mode: .all, nodes: [
            .condition(tagEquals("Vacation")),
            .condition(ratingAtLeast(4)),
        ])
        let summary = FilterSummaryFormatter.filterGroupSummary(group, customFields: [:], maxConditions: 3)
        XCTAssertEqual(summary, "Tag equals Vacation · Rating is at least 4")
    }

    func testCappedSynopsisAppendsMoreCount() {
        let group = FilterGroup(mode: .all, nodes: [
            .condition(tagEquals("A")),
            .condition(tagEquals("B")),
            .condition(tagEquals("C")),
            .condition(ratingAtLeast(3)),
            .condition(ratingAtLeast(5)),
        ])
        let summary = FilterSummaryFormatter.filterGroupSummary(group, customFields: [:], maxConditions: 3)
        XCTAssertEqual(
            summary,
            "Tag equals A · Tag equals B · Tag equals C (+2 more)"
        )
    }

    func testEmptyGroupReturnsNil() {
        XCTAssertNil(FilterSummaryFormatter.filterGroupSummary(FilterGroup(), customFields: [:], maxConditions: 3))
    }

    func testAdvancedFilterSummaryPreservesNestedStructure() {
        let group = FilterGroup(mode: .any, nodes: [
            .group(FilterGroup(mode: .all, nodes: [
                .condition(tagEquals("Vacation")),
                .condition(ratingAtLeast(4)),
            ])),
        ])
        let summary = FilterSummaryFormatter.filterGroupSummary(group, customFields: [:])
        XCTAssertEqual(summary, "Tag equals Vacation AND Rating is at least 4")
    }

    func testPillLabelShowsFirstRuleWithEllipsisWhenMultiple() {
        let group = FilterGroup(mode: .all, nodes: [
            .condition(ratingAtLeast(4)),
            .condition(tagEquals("Vacation")),
        ])
        let label = FilterSummaryFormatter.labeledCollectionPillText(
            collectionName: "Popular",
            group: group,
            customFields: [:]
        )
        XCTAssertEqual(label, "Popular: Rating is at least 4 ...")
    }

    func testPillLabelShowsSingleRuleWithoutEllipsis() {
        let group = FilterGroup(mode: .all, nodes: [
            .condition(ratingAtLeast(4)),
        ])
        let label = FilterSummaryFormatter.labeledCollectionPillText(
            collectionName: "Popular",
            group: group,
            customFields: [:]
        )
        XCTAssertEqual(label, "Popular: Rating is at least 4")
    }
}
