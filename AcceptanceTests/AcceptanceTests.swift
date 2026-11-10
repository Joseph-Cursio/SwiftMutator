@testable import muterCore
import SnapshotTesting
import TestingExtensions
import XCTest

private enum AcceptanceTestsError: Error {
    case reason(String)
}

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
    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "\(rootTestDirectory)/samples"),
            "No samples: run `make acceptance-test` to generate them and run these tests"
        )
    }

    func test_runCommand() throws {
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
        let output = try mutersOutputWithTestPlan

        XCTAssertTrue(output.contains("SwiftMutator mutation test plan loaded"))
    }

    func test_withCoverage() throws {
        let output = try muterWithCoverageOutput

        XCTAssertTrue(output.contains("Code Coverage of your project:"))
    }

    func test_xcodeFormat() throws {
        let output = try muterXcodeOutput

        XCTAssertEqual(try numberOfXcodeFormattedMessages(in: output), 2)
        // Without --verbose, no file's mutant count is listed.
        XCTAssertEqual(try numberOfDiscoveredFileLists(in: output), 0)
    }

    func test_filesToMutate() throws {
        let output = try muterFilesToMutateOutput

        // `a == b`'s two constants, which ReplaceBooleanValue leaves the value to.
        XCTAssertTrue(output.contains("In total, SwiftMutator discovered 2 mutants in 1 files"))
    }

    func test_muterDoesntDiscoverAnyMutationOperators() throws {
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
        let decodedConfiguration = try MuterConfiguration(from: createdIOSConfiguration)
        XCTAssertEqual(decodedConfiguration.testCommandExecutable, "/usr/bin/xcodebuild")
        XCTAssertTrue(decodedConfiguration.testCommandArguments.contains("-destination"))
        XCTAssertTrue(
            decodedConfiguration.testCommandArguments
                .contains { $0.contains("platform=iOS Simulator,name=iPhone") }
        )
    }

    func test_initCommandOnMacOSProject() throws {
        let decodedConfiguration = try MuterConfiguration(from: createdMacOSConfiguration)
        XCTAssertEqual(decodedConfiguration.testCommandExecutable, "/usr/bin/xcodebuild")
        XCTAssertTrue(decodedConfiguration.testCommandArguments.contains("-destination"))
        XCTAssertTrue(
            decodedConfiguration.testCommandArguments.contains { $0.contains("platform=macOS,arch=arm64") }
        )
    }

    // The plan names its copy relative to the project, so the two can move together.
    func test_mutationTestPlan() throws {
        let decodedTestPlan = try JSONDecoder().decode(TestPlanFile.self, from: createdTestPlan)
        XCTAssertEqual(decodedTestPlan.formatVersion, TestPlanCoding.formatVersion)
        XCTAssertEqual(decodedTestPlan.mutatedProject, "../ExampleApp_mutated.noindex")
        XCTAssertEqual(decodedTestPlan.projectCoverage, 23)
        XCTAssertEqual(decodedTestPlan.mappings.count, 1)
        XCTAssertFalse(decodedTestPlan.mappings.contains { $0.filePath.hasPrefix("/") })
    }

    func test_mutationTestTimeout() throws {
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
        try AssertSnapshot(muterOperatorAllOutput)
    }

    func test_helpCommand() throws {
        try AssertSnapshot(muterHelpOutput)
    }

    func test_helpCommandInit() throws {
        try AssertSnapshot(muterInitHelpOutput)
    }

    func test_helpCommandRun() throws {
        try AssertSnapshot(muterRunHelpOutput)
    }

    func test_helpCommandOperator() throws {
        try AssertSnapshot(muterOperatorHelpOutput)
    }

    func test_helpCommandReport() throws {
        try AssertSnapshot(muterReportHelpOutput)
    }
}

extension AcceptanceTests {
    var rootTestDirectory: String {
        String(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .withoutScheme()
        )
    }

    var muterOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_output.txt")
        }
    }

    var mutersOutputWithTestPlan: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_output_with_test_plan.txt")
        }
    }

    var muterXcodeOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_xcode_output.txt")
        }
    }

    var muterFilesToMutateOutput: String {
        get throws {
            try contentsOfFileAsString(
                "\(rootTestDirectory)/samples/muters_files_to_mutate_output.txt"
            )
        }
    }

    var muterWithCoverageOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_with_coverage_output.txt")
        }
    }

    var muterWithTimeoutOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_timeout_output.txt")
        }
    }

    var muterEmptyStateOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_empty_state_output.txt")
        }
    }

    var muterAbortedTestingOutput: String {
        get throws {
            try contentsOfFileAsString(
                "\(rootTestDirectory)/samples/muters_aborted_testing_output.txt"
            )
        }
    }

    var muterHelpOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_help_output.txt")
        }
    }

    var muterInitHelpOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_init_help_output.txt")
        }
    }

    var muterRunHelpOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_run_help_output.txt")
        }
    }

    var muterOperatorHelpOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_operator_help_output.txt")
        }
    }

    var muterReportHelpOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_report_help_output.txt")
        }
    }

    var muterOperatorAllOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_operator_all_output.txt")
        }
    }

    var muterLogFiles: [String] {
        get throws {
            try contentsOfDirectory(muterLogsRootPath)
                .map { muterLogsRootPath + "/" + $0 }
                .flatMap(contentsOfDirectory)
        }
    }

    var createdIOSConfiguration: Data {
        get throws {
            try contentsOfFileAsData("\(rootTestDirectory)/samples/created_iOS_config.yml")
        }
    }

    var createdMacOSConfiguration: Data {
        get throws {
            try contentsOfFileAsData("\(rootTestDirectory)/samples/created_macOS_config.yml")
        }
    }

    var createdTestPlan: Data {
        get throws {
            try contentsOfFileAsData("\(rootTestDirectory)/samples/created_muter-mappings.json")
        }
    }

    var muterLogsRootPath: String { "\(rootTestDirectory)/samples/muter_logs/" }
}

extension AcceptanceTests {
    func contentsOfLogFile(named fileName: String) throws -> String {
        try contentsOfDirectory(muterLogsRootPath)
            .first
            .map { muterLogsRootPath + $0 + "/" + fileName }
            .map(contentsOfFileAsString)!
    }

    func contentsOfDirectory(_ path: String) throws -> [String] {
        try FileManager
            .default
            .contentsOfDirectory(atPath: path)
            .exclude { $0.starts(with: ".") } // this filters out hidden files/folders
    }

    func contentsOfFileAsString(_ path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path),
              let output = String(data: data, encoding: .utf8)
        else {
            throw AcceptanceTestsError.reason("File not found at \(path)")
        }

        return output
    }

    func contentsOfFileAsData(_ path: String) throws -> Data {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw AcceptanceTestsError.reason("Unable to find a valid output file from a prior run of SwiftMutator at \(path)")
        }
        return data
    }
}

extension AcceptanceTests {
    func numberOfDiscoveredFileLists(in output: String) throws -> Int {
        try applyRegex("[a-zA-Z]+.swift \\([0-9]+ mutants\\)", to: output)
    }

    func numberOfXcodeFormattedMessages(in output: String) throws -> Int {
        try applyRegex(
            "[\\/[:alnum:]\\/]+[a-zA-Z]+.swift\\:[0-9]+:[0-9]+\\: warning: [a-zA-Z ]+: [a-zA-Z[:punct:] ]+/?",
            to: output
        )
    }

    func numberOfProgressUpdates(in output: String) throws -> Int {
        try applyRegex(
            "^\\[[0-9]{2}:[0-9]{2}:[0-9]{2}\\] [0-9]+ of [0-9]+ \\([0-9]+%\\)",
            to: output
        )
    }

    func numberOfDurationEstimates(in output: String) throws -> Int {
        try applyRegex(
            " [0-9]+ (min|h) left",
            to: output
        )
    }

    func applyRegex(_ regex: String, to output: String) throws -> Int {
        let filePathRegex = try NSRegularExpression(pattern: regex, options: .anchorsMatchLines)
        let entireString = NSRange(location: 0, length: output.count)
        return filePathRegex.numberOfMatches(
            in: output,
            options: .withoutAnchoringBounds,
            range: entireString
        )
    }
}
