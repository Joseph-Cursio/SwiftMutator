import Foundation

enum TestSuiteOutcome: String, Codable, CaseIterable {
    /// Mutant survived
    case passed
    /// Mutant killed
    case failed
    case buildError
    case runtimeError
    case noCoverage
    case timeout

    var asMutationTestOutcome: String {
        switch self {
        case .passed:
            return "mutant survived"
        case .failed:
            return "mutant killed (test failure)"
        case .buildError:
            return "build error"
        case .runtimeError:
            return "mutant killed (runtime error)"
        case .noCoverage:
            return "skipped (no coverage)"
        case .timeout:
            return "time out"
        }
    }
}

extension TestSuiteOutcome {
    /// `failedTestLinesAreReliable` is false once a passing baseline has printed a line `FailedTestLine`
    /// matches; see `MuterConfiguration.failedTestLinesAreReliable`.
    static func from(
        testLog: String,
        terminationStatus: Int32,
        timeoutExecution: TestingExecutionResult? = nil,
        failedTestLinesAreReliable: Bool = true
    ) -> TestSuiteOutcome {
        // Stopped because a test failed (stopAtFirstFailure): the mutant is killed, whatever the log shows. The
        // log ends where the run was killed, with no summary for testFailureRegEx, and the exit status is our SIGKILL.
        if timeoutExecution == .stoppedAtFirstFailure {
            return .failed
        }

        if timeoutExecution == .timeout {
            return outcomeOfStoppedRun(testLog, failedTestLinesAreReliable: failedTestLinesAreReliable)
        }

        if logContainsBuildError(testLog) {
            return .buildError
        } else if logContainsTestFailure(testLog) {
            return .failed
        } else if !terminationStatusIsSuccess(terminationStatus) {
            return .runtimeError
        }

        return .passed
    }

    /// A run stopped at the time limit has no exit status of its own, so only what its log already
    /// shows can say the mutant was killed: a failure summary, XCTest's line for a failed test, or
    /// Swift Testing's line for an issue as it is recorded. A run stopped before that test ended shows
    /// nothing else. That last line counts only while such lines are reliable: a passing baseline that
    /// printed one has tests that print text shaped like it. A crash is common here: after one,
    /// xcodebuild collects diagnostics and relaunches the runner for each remaining test, which can take
    /// several times as long as the baseline run the limit is derived from.
    private static func outcomeOfStoppedRun(_ testLog: String, failedTestLinesAreReliable: Bool) -> TestSuiteOutcome {
        let showsFailedTestLine = failedTestLinesAreReliable && FailedTestLine.first(inLog: testLog) != nil
        if logContainsTestFailure(testLog) || logContainsFailedTestCase(testLog) || showsFailedTestLine {
            return .failed
        } else if logContainsCrash(testLog) {
            return .runtimeError
        }

        return .timeout
    }

    /// XCTest's line for a failed test. A stopped run may end before the suite summary
    /// `logContainsTestFailure` looks for, so a stopped run's log is also checked for this.
    private static func logContainsFailedTestCase(_ testLog: String) -> Bool {
        let entireTestLog = NSRange(testLog.startIndex..., in: testLog)
        return failedTestCaseRegEx.numberOfMatches(in: testLog, options: [], range: entireTestLog) > 0
    }

    private static var failedTestCaseRegEx: NSRegularExpression {
        NSRegularExpression.regexWithPattern(#"Test Case '[^']*' failed \("#)
    }

    /// The Swift runtime's message for a trap (`file.swift:12: Fatal error: …`), or SwiftPM's report
    /// of a test process killed by a signal (`exited with unexpected signal code 5`; older versions
    /// say `Exited with signal code 4`). Signal 9 is left out: stopping a run sends SIGKILL to the
    /// test processes before `swift test` itself, which can report that as a signal exit. Used only
    /// for stopped runs: a finished run's exit status is better evidence, and a `Fatal error` line
    /// alone with exit status 0 still counts as passed.
    private static func logContainsCrash(_ testLog: String) -> Bool {
        let entireTestLog = NSRange(testLog.startIndex..., in: testLog)
        return crashRegEx.numberOfMatches(in: testLog, options: [], range: entireTestLog) > 0
    }

    private static var crashRegEx: NSRegularExpression {
        NSRegularExpression.regexWithPattern(
            #"(^|: )Fatal error: |[Ee]xited with (unexpected )?signal code (?!9\b)[0-9]+"#,
            .anchorsMatchLines
        )
    }

    private static func logContainsTestFailure(_ testLog: String) -> Bool {
        let entireTestLog = NSRange(testLog.startIndex..., in: testLog)
        let numberOfFailureMessages = testFailureRegEx.numberOfMatches(in: testLog, options: [], range: entireTestLog)
        return numberOfFailureMessages > 0 ||
            testLog.contains(testFailedMessage(from: .xcodebuild)) ||
            testLog.contains(testFailedMessage(from: .buck))
    }

    private static func testFailedMessage(from testingBuildSystem: TestingBuildSystem) -> String {
        switch testingBuildSystem {
        case .xcodebuild: return "** TEST FAILED **"
        case .buck: return "TESTS FAILED: "
        case .swift: return " failures "
        }
    }

    private static var testFailureRegEx: NSRegularExpression {
        NSRegularExpression.regexWithPattern(#"test\(s\)? failed|with ([1-9][0-9]*) (failure|issue)|with ([1-9][0-9]*) tests? failed"#)
    }

    private static func terminationStatusIsSuccess(_ terminationStatus: Int32) -> Bool {
        terminationStatus == 0
    }

    private static func logContainsBuildError(_ testLog: String) -> Bool {
        testLog.contains("xcodebuild: error:") ||
            testLog.contains("error: terminated") ||
            testLog.contains("failed with a nonzero exit code") ||
            testLog.contains("Testing cancelled because the build failed") ||
            testLog.contains("Command failed with exit code 1.")
    }
}

private enum TestingBuildSystem {
    case xcodebuild
    case buck
    case swift
}
