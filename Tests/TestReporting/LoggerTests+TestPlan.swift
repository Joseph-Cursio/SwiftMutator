import Foundation
@testable import muterCore
import Rainbow
import TestingExtensions

extension LoggerTests {
    // What the plan holds, that its copy may be fixed by hand, the command that tests it, and that a later run removes
    // the copy with any fix in it.
    func test_testPlanFileCreated_saysWhatThePlanHolds_andHowToTestIt() {
        sut.testPlanFileCreated(
            TestPlanCreated(
                path: "/Users/a/My Project/muter-mappings.json",
                mutatedProject: "../My Project_mutated",
                mutants: 1,
                files: 1,
                operators: ["SwapTernary"]
            )
        )
        sut.testPlanFileCreated(
            TestPlanCreated(
                path: "/Users/a/Foo/muter-mappings.json",
                mutatedProject: "../Foo_mutated",
                mutants: 7,
                files: 2,
                operators: ["ChangeLogicalConnector", "RelationalOperatorReplacement", "SwapTernary"]
            )
        )

        let removed = "⚠️ A later `swift-mutator run` or `mutate-without-running` of this project removes that copy, "
            + "and any fix in it."
        XCTAssertEqual(printer.linesPassed, [
            "💾 Mutation test plan created: /Users/a/My Project/muter-mappings.json (1 mutant in 1 file, operator "
                + "SwapTernary)",
            "✏️ You can fix its copy, ../My Project_mutated, by hand before testing it.",
            "▶️ Test it: swift-mutator run-without-mutating '/Users/a/My Project/muter-mappings.json'",
            removed,
            "💾 Mutation test plan created: /Users/a/Foo/muter-mappings.json (7 mutants in 2 files, operators "
                + "ChangeLogicalConnector, RelationalOperatorReplacement and SwapTernary)",
            "✏️ You can fix its copy, ../Foo_mutated, by hand before testing it.",
            "▶️ Test it: swift-mutator run-without-mutating /Users/a/Foo/muter-mappings.json",
            removed,
        ])
    }

    // A plan in format 0 records no project files to check against.
    func test_testPlanSourcesUnchecked_saysHowToHaveThePlanChecked() {
        sut.testPlanSourcesUnchecked()

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ The test plan was made by a SwiftMutator from before plans recorded the project's files, so it isn't "
                + "checked against them. Make it again with `swift-mutator mutate-without-running` to have it checked.",
        ])
    }

    // Files the plan doesn't mutate, which the copy holds as they were: ten by name, and the rest counted.
    func test_testPlanSourcesDiffer_namesTheFiles_andSaysTheCopyHoldsThemAsTheyWere() {
        sut.testPlanSourcesDiffer([.init(path: "Package.resolved", kind: .changed)])
        sut.testPlanSourcesDiffer(
            [.init(path: "README.md", kind: .removed)]
                + (1 ... 11).map { .init(path: "Tests/Test\($0).swift", kind: .added) }
        )

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ 1 project file the plan doesn't mutate changed since `swift-mutator mutate-without-running` made it: "
                + "Package.resolved (changed). The plan's copy holds it as it was, so its mutants are tested with it "
                + "as it was. Make the plan again to test with it as it is now.",
            "⚠️ 12 project files the plan doesn't mutate changed since `swift-mutator mutate-without-running` made "
                + "it: README.md (removed), "
                + (1 ... 9).map { "Tests/Test\($0).swift (added)" }.joined(separator: ", ")
                + ", and 2 more. The plan's copy holds them as they were, so its mutants are tested with them as they "
                + "were. Make the plan again to test with them as they are now.",
        ])
    }

    // With `--mutant`, files with the plan's other mutants, which a run that tests them would refuse.
    func test_testPlanUntestedFilesChanged_namesTheFiles_andSaysARunOfThemIsRefused() {
        sut.testPlanUntestedFilesChanged([.init(path: "Sources/Max.swift", kind: .changed)])
        sut.testPlanUntestedFilesChanged(
            [.init(path: "Sources/Max.swift", kind: .removed), .init(path: "Sources/Min.swift", kind: .changed)]
        )

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ 1 file with the plan's other mutants, which this run doesn't test, changed since `swift-mutator "
                + "mutate-without-running` made it: Sources/Max.swift (changed). A run that tests those mutants "
                + "refuses the plan, unless --plan-ignoring lets the change through.",
            "⚠️ 2 files with the plan's other mutants, which this run doesn't test, changed since `swift-mutator "
                + "mutate-without-running` made it: Sources/Max.swift (removed), Sources/Min.swift (changed). A run "
                + "that tests those mutants refuses the plan, unless --plan-ignoring lets the changes through.",
        ])
    }

    func test_testPlanChangesWaived_namesTheFilesPlanIgnoringLetThrough() {
        sut.testPlanChangesWaived(["Sources/Sum.swift"])
        sut.testPlanChangesWaived(["Sources/Max.swift", "Sources/Sum.swift"])

        XCTAssertEqual(printer.linesPassed, [
            "ℹ️ The plan is tested although 1 file it mutates changed since it was made (--plan-ignoring): "
                + "Sources/Sum.swift. Its mutants are tested in the copy as it is.",
            "ℹ️ The plan is tested although 2 files it mutates changed since it was made (--plan-ignoring): "
                + "Sources/Max.swift, Sources/Sum.swift. Their mutants are tested in the copy as it is.",
        ])
    }

    // Files with mutants that a fix by hand changed in the plan's copy: ten by name, and the rest counted.
    func test_testPlanCopyEdited_namesTheFiles_andSaysTheyAreTestedAsTheyAre() {
        sut.testPlanCopyEdited(["Sources/Sum.swift"])
        sut.testPlanCopyEdited((1 ... 12).map { "Sources/File\($0).swift" })

        XCTAssertEqual(printer.linesPassed, [
            "✏️ 1 file of the plan's copy differs from what `swift-mutator mutate-without-running` wrote, and is "
                + "tested as it is now: Sources/Sum.swift",
            "✏️ 12 files of the plan's copy differ from what `swift-mutator mutate-without-running` wrote, and are "
                + "tested as they are now: "
                + (1 ... 10).map { "Sources/File\($0).swift" }.joined(separator: ", ")
                + ", and 2 more",
        ])
    }

    // A Package.resolved the copy's own build wrote, which the plan's project didn't have, doesn't refuse a resume.
    func test_testPlanCopyResolutionChanged_namesTheFiles_andSaysHowToTestWithThemAsTheyAre() {
        sut.testPlanCopyResolutionChanged([.init(path: "Package.resolved", kind: .added)])
        sut.testPlanCopyResolutionChanged([
            .init(path: "App.xcworkspace/xcshareddata/swiftpm/Package.resolved", kind: .changed),
            .init(path: "Package.resolved", kind: .changed),
        ])

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ 1 dependency resolution file of the plan's copy changed since the run's last session: "
                + "Package.resolved (added). The project the plan was made from had no such file, so the copy's own "
                + "build wrote it, and the results are reused. To test every mutant with the dependencies as they are "
                + "resolved now, start the run again without --resume.",
            "⚠️ 2 dependency resolution files of the plan's copy changed since the run's last session: "
                + "App.xcworkspace/xcshareddata/swiftpm/Package.resolved (changed), Package.resolved (changed). The "
                + "project the plan was made from had none of them, so the copy's own build wrote them, and the "
                + "results are reused. To test every mutant with the dependencies as they are resolved now, start "
                + "the run again without --resume.",
        ])
    }
}
