@testable import muterCore
import XCTest

extension ProjectTreeTests {
    func test_changes_nameChangedAddedAndRemoved_ignoringBothSessionsExclusions() {
        let recorded = tree(
            ["Same.swift": "1", "Changed.swift": "2", "Removed.txt": "3", "new-report.txt": "an earlier file"],
            excluding: ["old-report.txt"]
        )
        let now = tree(
            ["Same.swift": "1", "Changed.swift": "9", "Added.txt": "4", "old-report.txt": "now a project file"],
            excluding: ["new-report.txt"]
        )

        XCTAssertEqual(now.changes(since: recorded), [
            .init(path: "Added.txt", kind: .added),
            .init(path: "Changed.swift", kind: .changed),
            .init(path: "Removed.txt", kind: .removed),
        ])
        XCTAssertEqual(now.changes(since: now), [])
    }

    // A delta holds only what changed, and makes the tree it was taken to, listing and exclusions included.
    func test_aDelta_holdsOnlyWhatChanged_andMakesTheTreeAgain() {
        let recorded = tree(["Same.swift": "1", "Changed.swift": "2", "Removed.txt": "3"], excluding: ["a.txt"])
        let now = ProjectTree(
            listedBy: .walk,
            files: ["Same.swift": "1", "Changed.swift": "9", "Added.txt": "4"],
            excluded: ["b.txt"],
            treeSHA256: ProjectTree.treeHash(of: ["Same.swift": "1", "Changed.swift": "9", "Added.txt": "4"])
        )

        let delta = ProjectTreeDelta(from: recorded, to: now)

        XCTAssertEqual(delta.baseTreeSHA256, recorded.treeSHA256)
        XCTAssertEqual(delta.files, ["Changed.swift": "9", "Added.txt": "4"])
        XCTAssertEqual(delta.removed, ["Removed.txt"])
        XCTAssertEqual(recorded.applying(delta), now)
        XCTAssertEqual(ProjectTreeDelta(from: now, to: now).files, [:])
        XCTAssertEqual(now.applying(ProjectTreeDelta(from: now, to: now)), now)
    }

    // A delta applies only to the tree it was taken from, and only when it makes the tree it records.
    func test_aDelta_appliesToNoOtherTree_andNotWhenItDoesNotMakeItsTree() {
        let recorded = tree(["Sum.swift": "1"], excluding: [])
        let now = tree(["Sum.swift": "2"], excluding: [])
        let delta = ProjectTreeDelta(from: recorded, to: now)
        let wrongResult = ProjectTreeDelta(
            baseTreeSHA256: delta.baseTreeSHA256,
            listedBy: delta.listedBy,
            excluded: delta.excluded,
            files: ["Sum.swift": "3"],
            removed: [],
            treeSHA256: delta.treeSHA256
        )

        XCTAssertNil(now.applying(delta))
        XCTAssertNil(recorded.applying(wrongResult))
    }

    func test_partition_starMatchesSlash_andDotSlashIsDropped() {
        let changes: [ProjectTree.FileChange] = [
            .init(path: "Docs/rules/rule.md", kind: .changed),
            .init(path: "README.md", kind: .changed),
            .init(path: "notes.txt", kind: .added),
            .init(path: "Sources/Sum.swift", kind: .removed),
        ]

        let split = changes.partition(by: ["Docs/*", "./README.md", "./*.txt"])

        XCTAssertEqual(split.waived.map(\.path), ["Docs/rules/rule.md", "README.md", "notes.txt"])
        XCTAssertEqual(split.unwaived.map(\.path), ["Sources/Sum.swift"])
        XCTAssertEqual(changes.partition(by: ["*.md"]).waived.map(\.path), ["Docs/rules/rule.md", "README.md"])
        XCTAssertEqual(changes.partition(by: []).unwaived, changes)
    }
}
