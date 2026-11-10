@testable import muterCore
import SnapshotTesting
import TestingExtensions
import XCTest

final class AcceptanceTests: XCTestCase {
    private let messages = (
        mutationScoreOfTestSuite: "Mutation Score of Test Suite: 30%",
        mutationScoresHeader: """
        --------------------
        Mutation Test Scores
        --------------------
        """,
        appliedMutationOperatorsHeader: """
        --------------------------
        Applied Mutation Operators
        --------------------------
        """
    )

    /// These tests read what `runAcceptanceTests.sh` wrote into `samples/`. That script recreates the folder
    /// before it writes anything, so a missing folder means it hasn't been run, not that it failed: skip, so
    /// a plain `swift test` can pass. A run that failed partway leaves the folder, and these tests then fail.
    private func skipWithoutSamples() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "\(rootTestDirectory)/samples"),
            "No samples: run `make acceptance-test` to generate them and run these tests"
        )
    }

    func test_runCommand() throws {
        try skipWithoutSamples()
        let output = try muterOutput
        let logFiles = try muterLogFiles

        XCTAssertTrue(output.contains("Copying your project to a temporary directory for testing"))

        XCTAssertTrue(output.contains("In total, SwiftMutator discovered 4 Swift files"))
        // With --verbose, how many mutants each file has is listed.
        XCTAssertTrue(try numberOfDiscoveredFileLists(in: output) >= 1)

        XCTAssertTrue(output.contains("_mutated"))

        XCTAssertTrue(output.contains("In total, SwiftMutator introduced 9 mutants in 4 files."))

        // Standard output is a file, so a line in place of the bar: once when the baseline passes, with no mutant
        // tested, and once as each of the 9 mutants finishes. Nothing moves the cursor, and nothing is coloured.
        XCTAssertEqual(try numberOfProgressUpdates(in: output), 10)
        XCTAssertEqual(try numberOfDurationEstimates(in: output), 10)
        XCTAssertFalse(output.contains("\u{1B}"))

        XCTAssertTrue(output.contains(messages.mutationScoresHeader))
        XCTAssertTrue(output.contains(messages.mutationScoreOfTestSuite))

        XCTAssertTrue(output.contains(messages.appliedMutationOperatorsHeader))

        // Each mutant's name ends with the hash of its file's path in the project, `ExampleApp/<file>`. Only the
        // survivors keep a log: Module.swift's mutants are killed by a test their results lines name, which stands in
        // for their logs. The configuration sets no time limit, so the limit comes from a timed test run, which keeps a
        // log of its own.
        let expectedLogFiles = [
            "baseline run.log",
            "timed test run.log",
            "ChangeLogicalConnector @ Module2.swift-2-17 3f9a9afeaa09cfa4.log",
            "FlipBooleanLiteral @ AppDelegate.swift-9-16 a37026e7c9359c5a.log",
            "FlipBooleanLiteral @ Module2.swift-2-12 3f9a9afeaa09cfa4.log",
            "FlipBooleanLiteral @ Module2.swift-2-20 3f9a9afeaa09cfa4.log",
            "ReplaceBooleanValue @ Module2.swift-2-12 3f9a9afeaa09cfa4.log",
            "ReplaceBooleanValue @ Module2.swift-2-25 3f9a9afeaa09cfa4.log",
            "RemoveSideEffects @ ViewController.swift-5-28 4d7bb557ed045e7d.log",
        ]

        let numberOfEmptyLogFiles = try expectedLogFiles
            .map(contentsOfLogFile(named:))
            .count { $0.isEmpty }

        // The run's results file and its summary are kept beside its logs.
        XCTAssertEqual(
            logFiles.sorted(),
            (expectedLogFiles + ["results.jsonl", "summary.json"]).sorted()
        ) // Sort these so it's easier to reason about any erroneous failures
        XCTAssertEqual(numberOfEmptyLogFiles, 0)
        XCTAssertFalse(try contentsOfLogFile(named: "results.jsonl").isEmpty)
        XCTAssertFalse(try contentsOfLogFile(named: "summary.json").isEmpty)
    }

    func test_runWithTestPlanCommand() throws {
        try skipWithoutSamples()
        let output = try mutersOutputWithTestPlan

        XCTAssertTrue(output.contains("SwiftMutator mutation test plan loaded"))
    }

    func test_withCoverage() throws {
        try skipWithoutSamples()
        let output = try muterWithCoverageOutput

        XCTAssertTrue(output.contains("Code Coverage of your project:"))
    }

    func test_xcodeFormat() throws {
        try skipWithoutSamples()
        let output = try muterXcodeOutput

        XCTAssertEqual(try numberOfXcodeFormattedMessages(in: output), 2)
        // Without --verbose, no file's mutant count is listed.
        XCTAssertEqual(try numberOfDiscoveredFileLists(in: output), 0)
    }

    func test_filesToMutate() throws {
        try skipWithoutSamples()
        let output = try muterFilesToMutateOutput

        // `a == b`'s two constants, which ReplaceBooleanValue leaves the value to.
        XCTAssertTrue(output.contains("In total, SwiftMutator discovered 2 mutants in 1 files"))
    }

    func test_muterDoesntDiscoverAnyMutationOperators() throws {
        try skipWithoutSamples()
        let output = try muterEmptyStateOutput

        XCTAssertTrue(output.contains("SwiftMutator wasn't able to discover any code it could mutation test."))
        XCTAssertFalse(output.contains(messages.mutationScoresHeader))
        XCTAssertFalse(output.contains(messages.mutationScoreOfTestSuite))
        XCTAssertFalse(output.contains(messages.appliedMutationOperatorsHeader))
    }

    // ProjectWithFailures has a test that always fails, so the run stops at its baseline. Its own failure has to be in
    // the log: a project that doesn't build stops the run too, as this one did, unnoticed, once Xcode dropped its
    // deployment target.
    func test_failingBaseline() throws {
        try skipWithoutSamples()
        let output = try muterAbortedTestingOutput

        XCTAssertTrue(
            output.contains(
                "SwiftMutator noticed that your test suite initially failed to compile or produced a test failure."
            )
        )
        XCTAssertTrue(output.contains("testAlwaysFails] : failed - it's important that this fails"), output)
        XCTAssertFalse(output.contains(messages.mutationScoresHeader))
        XCTAssertFalse(output.contains(messages.mutationScoreOfTestSuite))
        XCTAssertFalse(output.contains(messages.appliedMutationOperatorsHeader))
    }

    func test_initCommandOniOSProject() throws {
        try skipWithoutSamples()
        let decodedConfiguration = try MuterConfiguration(from: createdIOSConfiguration)
        XCTAssertEqual(decodedConfiguration.testCommandExecutable, "/usr/bin/xcodebuild")
        XCTAssertTrue(decodedConfiguration.testCommandArguments.contains("-destination"))
        XCTAssertTrue(
            decodedConfiguration.testCommandArguments
                .contains { $0.contains("platform=iOS Simulator,name=iPhone") }
        )
    }

    func test_initCommandOnMacOSProject() throws {
        try skipWithoutSamples()
        let decodedConfiguration = try MuterConfiguration(from: createdMacOSConfiguration)
        XCTAssertEqual(decodedConfiguration.testCommandExecutable, "/usr/bin/xcodebuild")
        XCTAssertTrue(decodedConfiguration.testCommandArguments.contains("-destination"))
        XCTAssertTrue(
            decodedConfiguration.testCommandArguments.contains { $0.contains("platform=macOS,arch=arm64") }
        )
    }

    // The plan names its copy relative to the project, so the two can move together.
    func test_mutationTestPlan() throws {
        try skipWithoutSamples()
        let decodedTestPlan = try JSONDecoder().decode(TestPlanFile.self, from: createdTestPlan)
        XCTAssertEqual(decodedTestPlan.formatVersion, TestPlanCoding.formatVersion)
        XCTAssertEqual(decodedTestPlan.mutatedProject, "../ExampleApp_mutated.noindex")
        XCTAssertEqual(decodedTestPlan.projectCoverage, 23)
        XCTAssertEqual(decodedTestPlan.mappings.count, 1)
        XCTAssertFalse(decodedTestPlan.mappings.contains { $0.filePath.hasPrefix("/") })
    }

    func test_mutationTestTimeout() throws {
        try skipWithoutSamples()
        let output = try muterWithTimeoutOutput
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let columns = { (line: String) in line.split(separator: " ").joined(separator: " ") }

        // Each mutant's row names it by its path in the project, its line and its column. How long it ran depends on
        // the machine, so each row is checked up to its result. The `if value >= 0` gets three mutants, which all time
        // out, as the test sleeps for longer than the limit whatever `foo` does: RelationalOperatorReplacement's
        // `true`, where the condition starts, which NegateConditional leaves the condition to, and its swap to `==`
        // and RelationalBoundary's `>`, at the operator.
        let header = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("File ") && $0.contains("Mutation Test Result") })
        XCTAssertEqual(
            columns(lines[header]),
            "File Applied Mutation Operator Mutation Test Result Duration"
        )
        let rows = lines.dropFirst(header + 2).prefix { !$0.isEmpty }
        XCTAssertEqual(rows.count, 3, output)
        let mutants = [
            "2:8 RelationalOperatorReplacement", "2:14 RelationalBoundary", "2:14 RelationalOperatorReplacement",
        ]
        for (row, mutant) in zip(rows, mutants) {
            XCTAssertTrue(
                columns(row).hasPrefix("Sources/ProjectWithTimeout/ProjectWithTimeout.swift:\(mutant) time out "),
                row
            )
        }
    }

    func test_all_operatos() throws {
        try skipWithoutSamples()
        try AssertSnapshot(muterOperatorAllOutput)
    }

    func test_helpCommand() throws {
        try skipWithoutSamples()
        try AssertSnapshot(muterHelpOutput)
    }

    func test_helpCommandInit() throws {
        try skipWithoutSamples()
        try AssertSnapshot(muterInitHelpOutput)
    }

    func test_helpCommandRun() throws {
        try skipWithoutSamples()
        try AssertSnapshot(muterRunHelpOutput)
    }

    func test_helpCommandOperator() throws {
        try skipWithoutSamples()
        try AssertSnapshot(muterOperatorHelpOutput)
    }

    func test_helpCommandReport() throws {
        try skipWithoutSamples()
        try AssertSnapshot(muterReportHelpOutput)
    }
}
