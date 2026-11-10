@testable import muterCore
import XCTest

/// Real logs of `swift test` in SwiftProjectLint at commit 76fcfca9, a package with three test bundles (CoreTests,
/// CLITests and AppTests), each run by XCTest, which finds no tests, and then by Swift Testing. They are kept whole,
/// with only the machine's paths replaced by `/path/to/`.
/// - `testRunWithoutFailures_swiftTesting_threeBundles.log` is SwiftMutator's baseline run: the build first, with
///   colour codes and many compiler warnings, then every test passing. It exited with status 0.
/// - `testRunWithFailures_swiftTesting_threeBundles.log` is one mutant's run, without a build: the `>=` at
///   ModifierOrderVisitor.swift:71:27 replaced by `<=`, run with `--mutant`, so it didn't stop at its first failed test
///   and all three bundles ran. One test failed, and it exited with status 1.
final class ThreeBundleLogTests: XCTestCase {
    private let passingLogName = "testRunWithoutFailures_swiftTesting_threeBundles.log"
    private let failingLogName = "testRunWithFailures_swiftTesting_threeBundles.log"
    /// The line the real run recorded as the mutant's `firstFailedTestLine`.
    private let failedTestLine = "✘ Test mixedChainOnlyFlagsBadPairs() recorded an issue at "
        + "ModifierOrderVisitorTests.swift:239:9: Expectation failed: visitor.detectedIssues.count == 1"
    /// The test the real run recorded as the mutant's `killedBy`.
    private let failedTest = FailedTest(
        name: "mixedChainOnlyFlagsBadPairs()",
        location: "ModifierOrderVisitorTests.swift:239:9"
    )

    // MARK: - Outcome

    func test_thePassingLog_isPassed_notABuildError() {
        let log = loadLogFile(named: passingLogName)
        XCTAssertEqual(
            log.split(separator: "\n").filter { $0.hasPrefix("✔ Test run with ") && $0.contains(" passed after ") }
                .count,
            3,
            "the fixture isn't the whole log of three bundles"
        )

        // A build error outranks the exit status, so the build's warnings and colour codes don't read as one.
        XCTAssertEqual(TestSuiteOutcome.from(testLog: log, terminationStatus: 0), .passed)
        // Stopped at the time limit, nothing in it shows the mutant killed.
        XCTAssertEqual(
            TestSuiteOutcome.from(testLog: log, terminationStatus: 9, timeoutExecution: .timeout),
            .timeout
        )
    }

    func test_theFailingLog_isFailed() {
        let log = loadLogFile(named: failingLogName)

        XCTAssertEqual(TestSuiteOutcome.from(testLog: log, terminationStatus: 1), .failed)
        XCTAssertEqual(
            TestSuiteOutcome.from(testLog: log, terminationStatus: 9, timeoutExecution: .timeout),
            .failed
        )
    }

    // MARK: - Failed tests

    func test_thePassingLog_showsNoFailedTestOrCrash() {
        let log = loadLogFile(named: passingLogName)

        XCTAssertEqual(FailedTestLine.failedTests(inLog: log), FailedTests(tests: [], count: 0, firstLine: nil))
        // As a baseline, it leaves failed-test lines reliable, so mutants' runs can stop at their first one.
        XCTAssertNil(FailedTestLine.first(inLog: log))
        XCTAssertNil(CrashLine.first(inLog: log))
    }

    func test_theFailingLog_showsTheOneTestThatFailed_asTheRealRunRecordedIt() {
        let log = loadLogFile(named: failingLogName)
        let expected = FailedTests(tests: [failedTest], count: 1, firstLine: failedTestLine)

        XCTAssertEqual(FailedTestLine.failedTests(inLog: log), expected)
        XCTAssertEqual(FailedTestLine.first(inLog: log), failedTestLine)
        XCTAssertEqual(MutantResult.failedTests(of: TestRun(outcome: .failed, testLog: log, exitStatus: 1)), expected)
        XCTAssertNil(CrashLine.first(inLog: log))
    }

    /// Lines a test prints, the slow-test notes of SwiftProjectLint's own test helper, and the summaries of a run and
    /// of the targets that failed, none of which is a failed test's line.
    func test_theFailingLog_namesNoOtherLineAsAFailedTest() {
        let lines = loadLogFile(named: failingLogName).split(separator: "\n")
        let distractors = [
            "⚠️  SLOW TEST: testArchitectureVisitorFatView took 0:00:06 (threshold: 0:00:05)",
            "   Path: '/path/to/nested/file.swift' -> 0 issues",
            "WARNING: PatternRegistry is nil. Returning empty pattern categories.",
            "✘ Test run with 4294 tests in 500 suites failed after 12.028 seconds with 1 issue.",
            "Note: Some test targets reported failures:",
            "  - CoreTests (Swift Testing)",
        ]
        for distractor in distractors {
            XCTAssertTrue(lines.contains { $0 == distractor }, "the fixture has no line \(distractor.debugDescription)")
            XCTAssertFalse(FailedTestLine.matches(distractor), distractor)
            XCTAssertNil(FailedTestLine.failedTest(in: distractor), distractor)
            XCTAssertFalse(CrashLine.matches(distractor), distractor)
        }

        XCTAssertEqual(lines.filter { FailedTestLine.matches($0) }, [Substring(failedTestLine)])
    }

    /// Had the run stopped at its failed test, its log would end soon after that line, with SwiftMutator's note. The
    /// note repeats that line, so none of the note's lines may read as a failed test's, or the run would seem to show
    /// that test failing twice.
    func test_theFailingLogStoppedAtItsFailedTest_showsOnlyThatLineAsAFailedTest() throws {
        let log = loadLogFile(named: failingLogName)
        let endOfLine = try XCTUnwrap(log.range(of: failedTestLine + "\n")).upperBound
        let killedLog = String(log[..<endOfLine])
        let note = MutationTestingDelegate.noteForRunStopped(at: failedTestLine, after: killedLog)
        let stoppedLog = killedLog + note
        XCTAssertTrue(note.contains(failedTestLine), "the note no longer repeats the line, so this checks nothing")

        XCTAssertEqual(
            stoppedLog.split(separator: "\n").filter { FailedTestLine.matches($0) },
            [Substring(failedTestLine)]
        )
    }

    // MARK: - Helpers

    private typealias FailedTest = FailedTestLine.FailedTest
    private typealias FailedTests = FailedTestLine.FailedTests

    private func loadLogFile(named name: String) -> String {
        let path = "\(fixturesDirectory)/TestLogsForParsing/\(name)"
        guard let data = FileManager.default.contents(atPath: path) else {
            XCTFail("Unable to load the log file \(path)")
            return ""
        }
        return String(lossyUTF8: data)
    }
}
