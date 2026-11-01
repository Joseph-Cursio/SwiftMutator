@testable import muterCore
import XCTest

final class ReuseChangesTests: XCTestCase {
    /// The earlier run's session's files, unless a test says otherwise.
    private static let recorded = [
        "Sources/Sum.swift": "ab12",
        "Tests/SumTests/SumTests.swift": "0001",
        "Tests/SumTests/ProductTests.swift": "0002",
        "Tests/SumTests/Helpers.swift": "0003",
        "README.md": "0004",
    ]
    /// The test files' text, unless a test says otherwise.
    private static let sources = [
        "Tests/SumTests/SumTests.swift": "import Testing\n@Test func addsTwoNumbers() { #expect(add(1, 1) == 2) }",
        "Tests/SumTests/ProductTests.swift": "import Testing\n@Test func multiplies() {}",
        "Tests/SumTests/Helpers.swift": "func expectSum(_ a: Int) { #expect(a > 0) }",
    ]

    func test_isTestFile_takesSwiftFilesInTestFolders_andTestsFilesThatImportATestLibrary() {
        // A folder named Tests, or ending in Tests as an Xcode test target's does, holds tests and their helpers.
        let readSource = { (path: String) -> String? in
            path.contains("Imports") ? "@testable import Sum\nimport XCTest\n" : "import Foundation\n"
        }
        for path in [
            "Tests/SumTests/SumTests.swift",
            "Tests/SumTests/Helpers.swift",
            "MyAppTests/Mocks/MockClient.swift",
            "Packages/Core/Tests/CoreTests/Helpers.swift",
            "Tests/Fixtures/SamplePackage/Package.swift",
            "Sources/App/ImportsTests.swift",
        ] {
            XCTAssertTrue(ReuseChanges.isTestFile(path, readSource: readSource), path)
        }
        // Fixtures and resources, which a test can't name, manifests outside a test folder, and production code named
        // like a test, which other code calls.
        for path in [
            "Tests/SumTests/Fixtures/input.json",
            "Tests/App.xcodeproj/project.pbxproj",
            "Sources/Sum.swift",
            "Package.swift",
            "README.md",
            "Sources/Rules/MissingTests.swift",
            "TestsHelpers/Mock.swift",
        ] {
            XCTAssertFalse(ReuseChanges.isTestFile(path, readSource: readSource), path)
        }
    }

    func test_init_splitsTestFilesFromOthers_andGlobsWaiveOnlyTheOthers() {
        // A glob that matches everything still can't let a test file's change through: that's what decides which
        // results a reuse keeps. A local package's own tests aren't built by the project, so their changes are left out.
        let changes = reuse(
            to: Self.recorded.merging([
                "Tests/SumTests/SumTests.swift": "ffff",
                "README.md": "ffff",
                "Sources/New.swift": "0005",
                "../Shared/Tests/SharedTests/SharedTests.swift": "0006",
            ]) { $1 },
            waiving: ["README.md"]
        )

        XCTAssertEqual(changes.testFiles, [.init(path: "Tests/SumTests/SumTests.swift", kind: .changed)])
        XCTAssertEqual(changes.waived, ["README.md"])
        XCTAssertEqual(changes.otherFiles, [.init(path: "Sources/New.swift", kind: .added)])

        let everything = reuse(to: Self.recorded.merging(["Tests/SumTests/SumTests.swift": "ffff"]) { $1 }, waiving: ["*"])
        XCTAssertEqual(everything.testFiles.count, 1)
        XCTAssertEqual(everything.waived, [])
        XCTAssertTrue(everything.otherFiles.isEmpty)
    }

    func test_init_readsTheTestFiles_onlyWhenSomeChanged() {
        var read: [String] = []
        let readSource = { (path: String) -> String? in
            read.append(path)
            return Self.sources[path]
        }

        _ = ReuseChanges(
            from: tree(Self.recorded),
            to: tree(Self.recorded.merging(["README.md": "ffff"]) { $1 }),
            waiving: [],
            readSource: readSource
        )
        XCTAssertEqual(read, [])

        let changes = ReuseChanges(
            from: tree(Self.recorded),
            to: tree(Self.recorded.merging(["Tests/SumTests/ProductTests.swift": "ffff"]) { $1 }),
            waiving: [],
            readSource: readSource
        )
        XCTAssertEqual(Set(changes.testSources.keys), Set(Self.sources.keys))
    }

    func test_aKillHolds_whenItsTestsFileIsUnchanged_declaresIt_andNoChangedTestNamesIt() {
        let changes = changedTest("Tests/SumTests/ProductTests.swift", now: "@Test func multipliesBetter() {}")

        XCTAssertTrue(changes.killHolds(kill(by: ("addsTwoNumbers()", "SumTests.swift:2:32"))))
    }

    func test_aKillDoesntHold_whenItsTestsFileChanged() {
        let changes = changedTest("Tests/SumTests/SumTests.swift", now: "@Test func addsTwoNumbers() {}")

        XCTAssertFalse(changes.killHolds(kill(by: ("addsTwoNumbers()", "SumTests.swift:2:32"))))
    }

    func test_aKillDoesntHold_whenItsIssuesFileDoesntDeclareIt() {
        // Its issues were recorded in a helper: the test itself may have been deleted, renamed or changed elsewhere.
        let changes = changedTest("Tests/SumTests/ProductTests.swift", now: "@Test func multiplies() { expectSum(2) }")

        XCTAssertFalse(changes.killHolds(kill(by: ("multipliesTwice()", "Helpers.swift:1:28"))))
    }

    func test_aKillDoesntHold_whenAChangedTestFileNamesItsTest_asAWholeName() {
        // Swift Testing's names can repeat across suites. A longer name that only contains it doesn't count.
        let named = changedTest("Tests/SumTests/ProductTests.swift", now: "@Test func addsTwoNumbers() {}")
        let longer = changedTest("Tests/SumTests/ProductTests.swift", now: "@Test func addsTwoNumbersTwice() {}")

        XCTAssertFalse(named.killHolds(kill(by: ("addsTwoNumbers()", "SumTests.swift:2:32"))))
        XCTAssertTrue(longer.killHolds(kill(by: ("addsTwoNumbers()", "SumTests.swift:2:32"))))
    }

    func test_aKillDoesntHold_whenItsTestsFileNamesAChangedTestFilesType() {
        // A helper type, named as its file is, that the test uses.
        let sources = Self.sources.merging([
            "Tests/SumTests/SumTests.swift": "@Test func addsTwoNumbers() { #expect(SumMock().sum == 2) }",
            "Tests/SumTests/SumMock.swift": "struct SumMock { var sum = 2 }",
        ]) { $1 }
        let changes = ReuseChanges(
            from: tree(Self.recorded.merging(["Tests/SumTests/SumMock.swift": "0007"]) { $1 }),
            to: tree(Self.recorded.merging(["Tests/SumTests/SumMock.swift": "ffff"]) { $1 }),
            waiving: [],
            readSource: { sources[$0] }
        )

        XCTAssertFalse(changes.killHolds(kill(by: ("addsTwoNumbers()", "SumTests.swift:1:33"))))
    }

    func test_aKillHolds_whenAnyOneOfItsNamedTestsHolds_evenOnceATestFileIsRemoved() {
        // Every named test really failed, so one that is unchanged, and still declared, fails again.
        var current = Self.recorded
        current["Tests/SumTests/ProductTests.swift"] = nil
        let changes = reuse(to: current)

        XCTAssertTrue(changes.killHolds(kill(
            by: ("multiplies()", "ProductTests.swift:2:7"),
            ("addsTwoNumbers()", "SumTests.swift:2:32")
        )))
        XCTAssertFalse(changes.killHolds(kill(by: ("multiplies()", "ProductTests.swift:2:7"))))
    }

    func test_aKillDoesntHold_whenItsTestsFileIsntOneUnchangedFileInBothTrees() {
        // Matched by name alone, as Swift Testing records a location's file: a name that isn't there, as a file a
        // build plugin generates, or that two files have, as two targets' `SumTests.swift`, proves nothing.
        let twice = Self.recorded.merging(["Tests/OtherTests/SumTests.swift": "0005"]) { $1 }
        let changedTest = ["Tests/SumTests/ProductTests.swift": "ffff"]
        let cases: [(recorded: [String: String], current: [String: String], file: String)] = [
            (Self.recorded, Self.recorded.merging(changedTest) { $1 }, "Generated.swift"),
            (twice, twice.merging(changedTest) { $1 }, "SumTests.swift"),
            (Self.recorded, twice.merging(changedTest) { $1 }, "SumTests.swift"),
        ]
        for (recorded, current, file) in cases {
            let changes = ReuseChanges(
                from: tree(recorded),
                to: tree(current),
                waiving: [],
                readSource: { Self.sources[$0] ?? "@Test func addsTwoNumbers() {}" }
            )

            XCTAssertFalse(changes.killHolds(kill(by: ("addsTwoNumbers()", "\(file):2:32"))), file)
        }
    }

    func test_displayNamesAndSuites_areFoundAsTheirDeclarationsHaveThem() {
        let sources = Self.sources.merging([
            "Tests/SumTests/SumTests.swift": """
            @Suite("Sums") struct SumTests {
                @Test("Adds two numbers") func adds() {}
                @Test(arguments: [1]) func add(_ a: Int) {}
            }
            """,
        ]) { $1 }
        let changes = ReuseChanges(
            from: tree(Self.recorded),
            to: tree(Self.recorded.merging(["Tests/SumTests/ProductTests.swift": "ffff"]) { $1 }),
            waiving: [],
            readSource: { sources[$0] }
        )

        for name in ["\"Adds two numbers\"", "add(_:)", "Suite \"Sums\"", "Suite SumTests"] {
            XCTAssertTrue(changes.killHolds(kill(by: (name, "SumTests.swift:2:5"))), name)
        }
        XCTAssertFalse(changes.killHolds(kill(by: ("\"Subtracts\"", "SumTests.swift:2:5"))))
    }

    func test_aKillWithoutNamedTestsWithFiles_doesntHold() {
        // XCTest's names carry no file, a crash may name none, and an unreliable session records no list.
        let changes = changedTest("Tests/SumTests/ProductTests.swift", now: "")

        XCTAssertFalse(changes.killHolds(kill(by: ("-[SumTests.SumTests testAdds]", nil))))
        XCTAssertFalse(changes.killHolds(MutantResult.make(outcome: .runtimeError, killedBy: [])))
        XCTAssertFalse(changes.killHolds(MutantResult.make(outcome: .failed, killedBy: nil)))
    }

    func test_anUnreadableChangedTestFile_namesEveryTest() {
        let changes = ReuseChanges(
            from: tree(Self.recorded),
            to: tree(Self.recorded.merging(["Tests/SumTests/ProductTests.swift": "ffff"]) { $1 }),
            waiving: [],
            readSource: { $0 == "Tests/SumTests/ProductTests.swift" ? nil : Self.sources[$0] }
        )

        XCTAssertFalse(changes.killHolds(kill(by: ("addsTwoNumbers()", "SumTests.swift:2:32"))))
    }

    func test_isEmpty_onlyWithNoChangeAtAll_letThroughOrNot() {
        XCTAssertTrue(reuse(to: Self.recorded).isEmpty)
        XCTAssertFalse(reuse(to: Self.recorded.merging(["README.md": "ffff"]) { $1 }, waiving: ["README.md"]).isEmpty)
    }
}

private extension ReuseChangesTests {
    func tree(_ files: [String: String]) -> ProjectTree {
        ProjectTree(listedBy: .git, files: files, excluded: [], treeSHA256: ProjectTree.treeHash(of: files))
    }

    /// The changes from `recorded`'s tree to one holding `current`, with `sources` as the test files' text.
    func reuse(to current: [String: String], waiving globs: [String] = []) -> ReuseChanges {
        ReuseChanges(from: tree(Self.recorded), to: tree(current), waiving: globs, readSource: { Self.sources[$0] })
    }

    /// The changes of a reuse after the test file at `path` changed to `text`.
    func changedTest(_ path: String, now text: String) -> ReuseChanges {
        let sources = Self.sources.merging([path: text]) { $1 }
        return ReuseChanges(
            from: tree(Self.recorded),
            to: tree(Self.recorded.merging([path: "ffff"]) { $1 }),
            waiving: [],
            readSource: { sources[$0] }
        )
    }

    /// A kill recorded with the named tests failing, each at its location.
    func kill(by tests: (name: String, location: String?)...) -> MutantResult {
        MutantResult.make(outcome: .failed, killedBy: tests.map { .init(name: $0.name, location: $0.location) })
    }
}
