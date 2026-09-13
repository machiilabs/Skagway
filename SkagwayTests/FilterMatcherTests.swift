import XCTest
@testable import Skagway

final class FilterMatcherTests: XCTestCase {
    private let vacation = Tag(id: 1, name: "Vacation")
    private let favorite = Tag(id: 2, name: "Favorite")

    private lazy var fourStarVacation = TestVideo.make(path: "/vac.mp4", rating: 4)
    private lazy var twoStarVacation = TestVideo.make(path: "/vac2.mp4", rating: 2)
    private lazy var fourStarPlain = TestVideo.make(path: "/plain.mp4", rating: 4)
    private lazy var favoriteOnly = TestVideo.make(path: "/fav.mp4", rating: 1)

    private func matcher(_ group: FilterGroup, customFields: [UUID: CustomMetadataFieldDefinition] = [:]) -> FilterMatcher {
        FilterMatcher(group: group, customFields: customFields)
    }

    private func notesField() -> (UUID, CustomMetadataFieldDefinition) {
        let id = UUID()
        return (id, CustomMetadataFieldDefinition(id: id, name: "Notes", valueType: .text))
    }

    private func ratingAtLeast(_ n: Int) -> FilterCondition {
        FilterCondition(field: .builtin(.rating), comparison: .greaterThanOrEqual, value: String(n))
    }

    private func tagEquals(_ name: String) -> FilterCondition {
        FilterCondition(field: .builtin(.tag), comparison: .equals, value: name)
    }

    func testEmptyGroupMatchesNothing() {
        let m = matcher(FilterGroup(mode: .all, nodes: []))
        XCTAssertFalse(m.matches(fourStarPlain, tags: [], customValues: [:]))
    }

    func testAllRequiresEveryCondition() {
        let group = FilterGroup(mode: .all, nodes: [
            .condition(tagEquals("Vacation")),
            .condition(ratingAtLeast(4)),
        ])
        let m = matcher(group)
        XCTAssertTrue(m.matches(fourStarVacation, tags: [vacation], customValues: [:]))
        XCTAssertFalse(m.matches(twoStarVacation, tags: [vacation], customValues: [:]))
        XCTAssertFalse(m.matches(fourStarPlain, tags: [], customValues: [:]))
    }

    func testAnyMatchesEitherCondition() {
        let group = FilterGroup(mode: .any, nodes: [
            .condition(tagEquals("Vacation")),
            .condition(tagEquals("Favorite")),
        ])
        let m = matcher(group)
        XCTAssertTrue(m.matches(fourStarVacation, tags: [vacation], customValues: [:]))
        XCTAssertTrue(m.matches(favoriteOnly, tags: [favorite], customValues: [:]))
        XCTAssertFalse(m.matches(fourStarPlain, tags: [], customValues: [:]))
    }

    func testTwoLevelOrOfAndGroups() {
        // (Tag=Vacation AND Rating≥4) OR Tag=Favorite
        let collection = VideoCollection(id: 1, name: "Mixed", dateCreated: Date(), matchMode: .any)
        let g1 = CollectionRuleGroup(id: 10, collectionId: 1, orderIndex: 0, matchMode: .all)
        let g2 = CollectionRuleGroup(id: 20, collectionId: 1, orderIndex: 1, matchMode: .all)
        let rules: [Int64: [CollectionRule]] = [
            10: [
                CollectionRule(collectionId: 1, groupId: 10, attribute: .builtin(.tag), comparison: .equals, value: "Vacation"),
                CollectionRule(collectionId: 1, groupId: 10, attribute: .builtin(.rating), comparison: .greaterThanOrEqual, value: "4"),
            ],
            20: [
                CollectionRule(collectionId: 1, groupId: 20, attribute: .builtin(.tag), comparison: .equals, value: "Favorite"),
            ],
        ]
        let tree = CollectionRepository.filterGroup(for: collection, groups: [g2, g1], rulesByGroup: rules)
        XCTAssertEqual(tree.mode, .any)
        XCTAssertEqual(tree.nodes.count, 2)

        let m = matcher(tree)
        XCTAssertTrue(m.matches(fourStarVacation, tags: [vacation], customValues: [:]))
        XCTAssertFalse(m.matches(twoStarVacation, tags: [vacation], customValues: [:]))
        XCTAssertTrue(m.matches(favoriteOnly, tags: [favorite], customValues: [:]))
        XCTAssertFalse(m.matches(fourStarPlain, tags: [], customValues: [:]))
    }

    func testNameMatchesTitleOrFileName() {
        let titled = TestVideo.make(path: "/disk-name.mp4", fileName: "disk-name.mp4", title: "Holiday Reel")
        let group = FilterGroup(mode: .all, nodes: [
            .condition(FilterCondition(field: .builtin(.name), comparison: .contains, value: "Holiday")),
        ])
        XCTAssertTrue(matcher(group).matches(titled, tags: [], customValues: [:]))
    }

    func testUnknownCustomFieldNeverMatches() {
        let missing = UUID()
        let group = FilterGroup(mode: .all, nodes: [
            .condition(FilterCondition(field: .custom(missing), comparison: .equals, value: "x")),
        ])
        XCTAssertFalse(matcher(group).matches(fourStarPlain, tags: [], customValues: [missing: "x"]))
    }

    func testCustomFieldIsEmpty() {
        let (fieldId, def) = notesField()
        let group = FilterGroup(mode: .all, nodes: [
            .condition(FilterCondition(field: .custom(fieldId), comparison: .isEmpty, value: "")),
        ])
        let m = matcher(group, customFields: [fieldId: def])
        XCTAssertTrue(m.matches(fourStarPlain, tags: [], customValues: [:]))
        XCTAssertTrue(m.matches(fourStarPlain, tags: [], customValues: [fieldId: ""]))
        XCTAssertTrue(m.matches(fourStarPlain, tags: [], customValues: [fieldId: "   "]))
        XCTAssertFalse(m.matches(fourStarPlain, tags: [], customValues: [fieldId: "Has notes"]))
    }

    func testCustomFieldIsNotEmpty() {
        let (fieldId, def) = notesField()
        let group = FilterGroup(mode: .all, nodes: [
            .condition(FilterCondition(field: .custom(fieldId), comparison: .isNotEmpty, value: "")),
        ])
        let m = matcher(group, customFields: [fieldId: def])
        XCTAssertFalse(m.matches(fourStarPlain, tags: [], customValues: [:]))
        XCTAssertFalse(m.matches(fourStarPlain, tags: [], customValues: [fieldId: ""]))
        XCTAssertTrue(m.matches(fourStarPlain, tags: [], customValues: [fieldId: "Has notes"]))
    }
}
