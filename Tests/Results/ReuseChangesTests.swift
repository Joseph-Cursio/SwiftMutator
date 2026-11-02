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
        "Tests/SumTests/Helpers.swift": "import Testing\nfunc expectSum(_ a: Int) { #expect(a > 0) }",
    ]

    func test_isTestFile_takesSwiftFilesThatImportATestLibrary_inTestFoldersOrNamedTests() {
        // A folder named Tests, or ending in Tests as an Xcode test target's does, holds tests and their helpers.
        let readSource = { (path: String) -> String? in
            path.contains("Fixture") || path.contains("Plain")
                ? "import Foundation\n"
                : "@testable import Sum\nimport XCTest\n"
        }
        for path in [
            "Tests/SumTests/SumTests.swift",
            "Tests/SumTests/Helpers.swift",
            "MyAppTests/Mocks/MockClient.swift",
            "Packages/Core/Tests/CoreTests/Helpers.swift",
            "Sources/App/ImportsTests.swift",
        ] {
            XCTAssertTrue(ReuseChanges.isTestFile(path, readSource: readSource), path)
        }
        // Fixtures and resources, Swift ones included, and helpers that import no test library, which a test can't
        // name; files outside test folders, but for those named like a test that are one.
        for path in [
            "Tests/SumTests/Fixtures/input.json",
            "Tests/SumTests/Fixtures/Example.swift",
            "Tests/SumTests/PlainHelpers.swift",
            "Tests/App.xcodeproj/project.pbxproj",
            "Sources/Sum.swift",
            "Package.swift",
            "README.md",
            "Sources/Rules/PlainTests.swift",
            "TestsHelpers/Mock.swift",
        ] {
            XCTAssertFalse(ReuseChanges.isTestFile(path, readSource: readSource), path)
        }
        XCTAssertFalse(ReuseChanges.isTestFile("Tests/SumTests/SumTests.swift", readSource: { _ in nil }), "unreadable")
    }

    func test_init_splitsTestFilesFromOthers_andGlobsWaiveOnlyTheOthers() {
        // A glob that matches everything still can't let a test file's change through: that's what decides which
        // results a reuse keeps. A local package's own tests aren't built by the project, so their changes are left
        // out.
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

        let everything = reuse(
            to: Self.recorded.merging(["Tests/SumTests/SumTests.swift": "ffff"]) { $1 },
            waiving: ["*"]
        )
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
        // A helper type, named as its file is, that the test uses, or that a `Type+Helpers.swift` file extends.
        for helper in ["SumMock.swift", "SumMock+Values.swift"] {
            let path = "Tests/SumTests/\(helper)"
            let sources = Self.sources.merging([
                "Tests/SumTests/SumTests.swift": "import Testing\n"
                    + "@Test func addsTwoNumbers() { #expect(SumMock().sum == 2) }",
                path: "import Testing\nstruct SumMock { var sum = 2 }",
            ]) { $1 }
            let changes = ReuseChanges(
                from: tree(Self.recorded.merging([path: "0007"]) { $1 }),
                to: tree(Self.recorded.merging([path: "ffff"]) { $1 }),
                waiving: [],
                readSource: { sources[$0] }
            )

            XCTAssertFalse(changes.killHolds(kill(by: ("addsTwoNumbers()", "SumTests.swift:2:33"))), helper)
        }
    }

    func test_aKillHolds_whenAnyOneOfItsNamedTestsHolds() {
        // Every named test really failed, so one that is unchanged, and still declared, fails again.
        let changes = changedTest("Tests/SumTests/ProductTests.swift", now: "@Test func multiplies() { #expect(true) }")

        XCTAssertTrue(changes.killHolds(kill(
            by: ("multiplies()", "ProductTests.swift:2:7"),
            ("addsTwoNumbers()", "SumTests.swift:2:32")
        )))
        XCTAssertFalse(changes.killHolds(kill(by: ("multiplies()", "ProductTests.swift:2:7"))))
    }

    // Its text is gone, so nothing shows whether it was a test or a fixture: every result is tested again, and no
    // glob lets it through.
    func test_aRemovedSwiftFileThatMayHaveBeenATest_isAnotherFile_thatNoGlobLetsThrough() {
        var current = Self.recorded
        current["Tests/SumTests/ProductTests.swift"] = nil

        let changes = reuse(to: current, waiving: ["*"])

        XCTAssertEqual(changes.otherFiles, [.init(path: "Tests/SumTests/ProductTests.swift", kind: .removed)])
        XCTAssertEqual(changes.testFiles, [])
        XCTAssertEqual(changes.waived, [])
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
                readSource: { Self.sources[$0] ?? "import Testing\n@Test func addsTwoNumbers() {}" }
            )

            XCTAssertFalse(changes.killHolds(kill(by: ("addsTwoNumbers()", "\(file):2:32"))), file)
        }
    }

    func test_displayNamesAndSuites_areFoundAsTheirDeclarationsHaveThem() {
        let sources = Self.sources.merging([
            "Tests/SumTests/SumTests.swift": """
            import Testing
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

    // Nothing shows it is a test, so it is another file.
    func test_anUnreadableChangedTestFile_isAnotherFile() {
        let changes = ReuseChanges(
            from: tree(Self.recorded),
            to: tree(Self.recorded.merging(["Tests/SumTests/ProductTests.swift": "ffff"]) { $1 }),
            waiving: [],
            readSource: { $0 == "Tests/SumTests/ProductTests.swift" ? nil : Self.sources[$0] }
        )

        XCTAssertEqual(changes.otherFiles, [.init(path: "Tests/SumTests/ProductTests.swift", kind: .changed)])
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

    /// The changes of a reuse after the test file at `path` changed to `text`, which imports Testing.
    func changedTest(_ path: String, now text: String) -> ReuseChanges {
        let sources = Self.sources.merging([path: "import Testing\n" + text]) { $1 }
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
