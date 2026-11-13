@testable import muterCore
import XCTest

/// Runs the built `swift-mutator` on a two-file project whose test command is a shell script, as
/// `ResumeAcceptanceTests` does: makes a test plan with `mutate-without-running`, and tests it with
/// `run-without-mutating`, after changes to the project or to the plan's copy, from another folder, and across a stop
/// with a real SIGINT and the command its summary printed, run by a shell as it would be pasted. Every process a test
/// starts is killed however the test ends, every wait is bounded, and every file a test writes is in a temporary
/// folder.
final class TestPlanAcceptanceTests: XCTestCase {
    /// The project, and the processes a test starts on it.
    private let harness = TestPlanHarness()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try harness.create()
    }

    override func tearDownWithError() throws {
        harness.cleanUp()
        try super.tearDownWithError()
    }

    func test_aPlanMadeTwice_hasTheSameBytes_andItsRunTestsEveryMutant() throws {
        let first = try harness.waitForEnd(of: harness.launch(harness.makePlan))
        XCTAssertEqual(first.status, 0, first.output)
        let firstPlan = try Data(contentsOf: harness.plan)

        let second = try harness.waitForEnd(of: harness.launch(harness.makePlan))

        XCTAssertEqual(second.status, 0, second.output)
        XCTAssertEqual(try Data(contentsOf: harness.plan), firstPlan, "the second plan's bytes differ")

        let tested = try harness.waitForEnd(of: harness.launch(harness.testPlan))

        XCTAssertEqual(tested.status, 0, tested.output)
        XCTAssertEqual(harness.ranLines().filter { $0 != "baseline" }.count, 4, "\(harness.ranLines())")
        let lines = try harness.records(in: harness.onlyResultsFile())
        XCTAssertEqual(lines.map { $0["kind"] as? String }, ["header", "mutant", "mutant", "mutant", "mutant", "end"])
        XCTAssertEqual(lines.first?["usingTestPlan"] as? Bool, true)
        XCTAssertNotNil(lines.first?["testPlan"], "the header records the plan")
    }

    func test_aChangedMutatedSource_isRefusedWith7_andPlanIgnoringLetsItThrough() throws {
        try harness.makeThePlan()
        try harness.write(
            "func isSmall(_ values: [Int]) -> Bool { values.contains { $0 != 12 } }\n",
            to: "Sources/Lib/Bounds.swift"
        )

        let refused = try harness.waitForEnd(of: harness.launch(harness.testPlan))

        XCTAssertEqual(refused.status, 7, refused.output)
        XCTAssertTrue(refused.output.contains("--plan-ignoring 'Sources/Lib/Bounds.swift'"), refused.output)
        XCTAssertTrue(refused.output.contains("Nothing was tested."), refused.output)
        XCTAssertEqual(harness.ranLines(), [], "something was tested")

        let waived = try harness.waitForEnd(
            of: harness.launch(harness.testPlan + ["--plan-ignoring", "Sources/Lib/Bounds.swift"])
        )

        XCTAssertEqual(waived.status, 0, waived.output)
        XCTAssertEqual(harness.ranLines().filter { $0 != "baseline" }.count, 4, "\(harness.ranLines())")
    }

    func test_aFixByHandInTheCopy_isSaid_andTestedAsItIs() throws {
        try harness.makeThePlan()
        let fixed = try harness.fixByHand("Sources/Lib/Bounds.swift")

        let tested = try harness.waitForEnd(of: harness.launch(harness.testPlan))

        XCTAssertEqual(tested.status, 0, tested.output)
        XCTAssertTrue(
            tested.output.contains(
                "✏️ 1 file of the plan's copy differs from what `swift-mutator mutate-without-running` wrote, and is "
                    + "tested as it is now: Sources/Lib/Bounds.swift"
            ),
            tested.output
        )
        let lines = try harness.records(in: harness.onlyResultsFile())
        let projectEntry = try XCTUnwrap(lines.first?["project"] as? [String: Any])
        XCTAssertEqual((projectEntry["files"] as? [String: String])?["Sources/Lib/Bounds.swift"], fixed)
        let boundsHashes = lines
            .filter { ($0["path"] as? String) == "Sources/Lib/Bounds.swift" }
            .compactMap { $0["fileSHA256"] as? String }
        XCTAssertEqual(boundsHashes, [fixed, fixed])
    }

    func test_aStoppedRun_isContinuedByTheCommandItsSummaryPrinted() throws {
        try harness.makeThePlan()
        try "".write(to: harness.hangMarker, atomically: true, encoding: .utf8)
        let first = try harness.launch(harness.testPlan)
        try harness.waitUntilHanging(first)
        kill(-first.process.processIdentifier, SIGINT)
        XCTAssertTrue(harness.waitUntil(within: 15) { !first.process.isRunning }, "SwiftMutator didn't stop")
        let resultsFile = try harness.onlyResultsFile()
        XCTAssertEqual(try harness.kinds(in: resultsFile), ["header", "mutant", "mutant", "end"])
        let errors = harness.contents(of: first.standardError)
        let printed = errors.components(separatedBy: "\n").compactMap { line in
            line.range(of: "▶️ Continue: ").map { String(line[$0.upperBound...]) }
        }
        XCTAssertEqual(printed.count, 1, errors)
        let continueCommand = try XCTUnwrap(printed.first, errors)
        let words = try wordsAShellReads(in: continueCommand)
        XCTAssertEqual(Array(words.dropLast()), ["swift-mutator"] + harness.testPlan + ["--resume"], continueCommand)
        let ranBefore = harness.ranLines()
        try FileManager.default.removeItem(at: harness.hangMarker)

        let resumed = try harness.waitForEnd(of: harness.launch(commandLine: continueCommand))

        XCTAssertEqual(resumed.status, 0, resumed.output)
        let lines = try harness.records(in: resultsFile)
        XCTAssertEqual(
            lines.map { $0["kind"] as? String },
            ["header", "mutant", "mutant", "end", "header", "mutant", "mutant", "end"]
        )
        XCTAssertEqual(lines[4]["mutantsReused"] as? Int, 2)
        let tested = Array(harness.ranLines().dropFirst(ranBefore.count))
        XCTAssertEqual(tested.first, "baseline")
        XCTAssertEqual(tested.count, 3, "\(tested)")
        XCTAssertTrue(tested.dropFirst().allSatisfy { $0.hasPrefix("Checks_") }, "\(tested)")
    }

    func test_aCopyEditedBetweenSessions_refusesTheResumeWith5_andResumeIgnoringRetestsOnlyThatFile() throws {
        try harness.makeThePlan()
        let first = try harness.waitForEnd(of: harness.launch(harness.testPlan))
        XCTAssertEqual(first.status, 0, first.output)
        let resultsFile = try harness.onlyResultsFile()
        try harness.fixByHand("Sources/Lib/Bounds.swift")
        let resume = harness.testPlan + ["--resume", resultsFile.path]

        let refused = try harness.waitForEnd(of: harness.launch(resume))

        XCTAssertEqual(refused.status, 5, refused.output)
        XCTAssertTrue(
            refused.output.contains(
                // Named by its path from the folder the command ran in, which may differ by a symbolic link.
                "/project_mutated.noindex, changed since the run's last session"
            ),
            refused.output
        )
        XCTAssertTrue(refused.output.contains("--resume-ignoring 'Sources/Lib/Bounds.swift'"), refused.output)
        XCTAssertEqual(try harness.kinds(in: resultsFile).count, 6, "the refusal wrote a line")
        let ranBefore = harness.ranLines()

        let waived = try harness.waitForEnd(
            of: harness.launch(resume + ["--resume-ignoring", "Sources/Lib/Bounds.swift"])
        )

        XCTAssertEqual(waived.status, 0, waived.output)
        let tested = Array(harness.ranLines().dropFirst(ranBefore.count))
        XCTAssertEqual(tested.count, 3, "\(tested)")
        XCTAssertTrue(tested.dropFirst().allSatisfy { $0.hasPrefix("Bounds_") }, "\(tested)")
        let header = try XCTUnwrap(harness.records(in: resultsFile).dropFirst(6).first)
        XCTAssertEqual(header["mutantsReused"] as? Int, 2)
        XCTAssertEqual(header["waived"] as? [String], ["Sources/Lib/Bounds.swift"])
    }

    func test_aRunFromAnotherFolder_isRefusedWith7() throws {
        try harness.makeThePlan()
        let elsewhere = harness.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try TestPlanHarness.configuration.write(
            to: elsewhere.appendingPathComponent("muter.conf.yml"),
            atomically: true,
            encoding: .utf8
        )

        let refused = try harness.waitForEnd(
            of: harness.launch(["run-without-mutating", "--skip-update-check", harness.plan.path], in: elsewhere)
        )

        XCTAssertEqual(refused.status, 7, refused.output)
        XCTAssertTrue(refused.output.contains("none of the 2 files it mutates"), refused.output)
        XCTAssertEqual(harness.ranLines(), [], "something was tested")
    }

    func test_aRunFromAnotherFolderWithoutAConfiguration_stopsOnItWith255_andWithTheProjectsIsRefusedWith7() throws {
        try harness.makeThePlan()
        let sources = harness.project.appendingPathComponent("Sources", isDirectory: true)

        let stopped = try harness.waitForEnd(
            of: harness.launch(["run-without-mutating", "--skip-update-check", harness.plan.path], in: sources)
        )

        XCTAssertEqual(stopped.status, 255, stopped.output)
        XCTAssertTrue(stopped.output.contains("Could not find muter.conf at path "), stopped.output)
        XCTAssertTrue(stopped.output.contains("/Sources/muter.conf.yml"), stopped.output)
        XCTAssertFalse(stopped.output.contains("none of the 2 files it mutates"), stopped.output)
        XCTAssertEqual(harness.ranLines(), [], "something was tested")

        let configurationPath = harness.project.appendingPathComponent("muter.conf.yml").path
        let refused = try harness.waitForEnd(
            of: harness.launch(
                [
                    "run-without-mutating", "--skip-update-check", "--configuration", configurationPath,
                    harness.plan.path,
                ],
                in: sources
            )
        )

        XCTAssertEqual(refused.status, 7, refused.output)
        XCTAssertTrue(refused.output.contains("none of the 2 files it mutates"), refused.output)
        XCTAssertEqual(harness.ranLines(), [], "something was tested")
    }

    func test_aPlanMadeAgainOfTheSameSources_isResumed_andOneOfChangedSourcesIsRefusedWith5() throws {
        try harness.makeThePlan()
        let firstPlan = try Data(contentsOf: harness.plan)
        let first = try harness.waitForEnd(of: harness.launch(harness.testPlan))
        XCTAssertEqual(first.status, 0, first.output)
        let resultsFile = try harness.onlyResultsFile()
        let resume = harness.testPlan + ["--resume", resultsFile.path]
        try harness.makeThePlan()
        XCTAssertEqual(try Data(contentsOf: harness.plan), firstPlan, "the plan made again differs")
        let ranBefore = harness.ranLines()

        let resumed = try harness.waitForEnd(of: harness.launch(resume))

        XCTAssertEqual(resumed.status, 0, resumed.output)
        let mutantsTested = harness.ranLines().dropFirst(ranBefore.count).filter { $0 != "baseline" }
        XCTAssertEqual(mutantsTested, [], "a mutant was tested")
        let header = try XCTUnwrap(harness.records(in: resultsFile).dropFirst(6).first)
        XCTAssertEqual(header["mutantsReused"] as? Int, 4)

        try harness.write(
            "func isSmall(_ values: [Int]) -> Bool { values.contains { $0 != 12 } }\n",
            to: "Sources/Lib/Bounds.swift"
        )
        try harness.makeThePlan()
        let lines = try harness.kinds(in: resultsFile).count

        let refused = try harness.waitForEnd(of: harness.launch(resume))

        XCTAssertEqual(refused.status, 5, refused.output)
        XCTAssertTrue(refused.output.contains("testPlan.sha256"), refused.output)
        XCTAssertEqual(try harness.kinds(in: resultsFile).count, lines, "the refusal wrote a line")
    }

    func test_oneMutantOfThePlan_printsItsChangeLogAndVerdict_andRunMutantLeavesThePlansCopyAlone() throws {
        try harness.makeThePlan()
        let fixed = try harness.fixByHand("Sources/Lib/Bounds.swift")
        let checks = harness.copy.appendingPathComponent("Sources/Lib/Checks.swift")
        let checksBefore = try Data(contentsOf: checks)

        // As a progress line names it.
        let tested = try harness.waitForEnd(of: harness.launch(harness.testPlan + ["--mutant", "Checks.swift:1:65"]))

        XCTAssertEqual(tested.status, 0, tested.output)
        let printed = tested.standardOutput
        assertTheOneMutantBlock(in: printed)
        let tests = harness.ranLines()
        XCTAssertEqual(tests.count, 2, "\(tests)")
        XCTAssertEqual(tests.first, "baseline")
        let mutant = try XCTUnwrap(tests.last)
        XCTAssertTrue(mutant.hasPrefix("Checks_"), mutant)
        XCTAssertEqual(try Data(contentsOf: checks), checksBefore, "the plan's copy was rewritten")

        // The command it printed runs the tests in the copy with the mutant on, which fail.
        let printedCommand = try XCTUnwrap(
            printed.components(separatedBy: "To run its tests with it on:\n  ").last?
                .components(separatedBy: "\n💾").first
        )
        let switchedOn = try harness.waitForEnd(
            of: harness.launch(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", printedCommand],
                in: harness.root
            )
        )
        XCTAssertEqual(switchedOn.status, 1, switchedOn.output)
        XCTAssertEqual(harness.ranLines().last, mutant)

        // `--mutant` looks among every operator, whatever the configuration leaves out, so it names this one.
        let alone = try harness.waitForEnd(
            of: harness.launch(
                ["run", "--skip-update-check", "--mutant", "Bounds.swift:2 RelationalOperatorReplacement"]
            )
        )

        XCTAssertEqual(alone.status, 0, alone.output)
        XCTAssertTrue(alone.standardOutput.contains("Verdict: survived, in "), alone.output)
        XCTAssertTrue(
            alone.standardOutput.contains("Mutated project kept, with the mutant switched off: ")
                && alone.standardOutput.contains("/project_mutant.noindex\n"),
            alone.output
        )
        let boundsInTheCopy = harness.copy.appendingPathComponent("Sources/Lib/Bounds.swift")
        XCTAssertEqual(
            try FileDigest.sha256(of: Data(contentsOf: boundsInTheCopy)),
            fixed,
            "run --mutant removed the plan's copy, or the fix in it"
        )
    }
}
