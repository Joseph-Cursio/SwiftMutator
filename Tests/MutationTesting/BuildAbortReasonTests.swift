@testable import muterCore
import XCTest

/// The messages of the aborts that stop a run before its first mutant: a failed baseline's tests, a failed build, and a
/// step stopped at `buildTimeout`.
final class BuildAbortReasonTests: XCTestCase {
    private let swiftTestingFailure = "✘ Test sum() recorded an issue at CalcTests.swift:12:5: Expectation failed"
    private let xcTestFailure = "Test Case '-[CalcTests.CalcTests testAdd]' failed (0.002 seconds)."

    // The tests a failed baseline shows failing come before its whole log, which can bury them.
    func test_aFailedBaseline_namesItsFailedTests_beforeTheLog() {
        let log = "Building...\n\(swiftTestingFailure)\n\(xcTestFailure)\n✘ Test run with 3 tests failed.\n"
        let description = MutationTestingAbortReason.baselineTestFailed(log: log, mutatedFilePaths: []).description

        let list = "These 2 tests failed:\n  sum() at CalcTests.swift:12:5\n  -[CalcTests.CalcTests testAdd]\n"
        let listed = try? XCTUnwrap(description.range(of: list), description)
        let logged = try? XCTUnwrap(description.range(of: "Here's the log your test command produced"), description)
        XCTAssertLessThan(listed?.lowerBound ?? description.endIndex, logged?.lowerBound ?? description.startIndex)
    }

    func test_aFailedClonesBaseline_namesItsFailedTestsToo() {
        let description = MutationTestingAbortReason.workerBaselineTestFailed(
            worker: 2, directory: "/project_mutated_worker2", log: "\(swiftTestingFailure)\n"
        ).description

        XCTAssertTrue(description.contains("This test failed:\n  sum() at CalcTests.swift:12:5\n"), description)
    }

    // At most 20, then how many more: the log follows.
    func test_aBaselineWithManyFailedTests_namesTwenty_andSaysHowManyMore() {
        let log = (1...23).map { "Test Case '-[CalcTests.CalcTests test\($0)]' failed (0.001 seconds)." }
            .joined(separator: "\n")

        let list = MutationTestingAbortReason.failedTestsList(in: log)

        XCTAssertEqual(list?.split(separator: "\n").count, 22)
        XCTAssertEqual(list?.hasPrefix("These 23 tests failed:\n"), true, list ?? "")
        XCTAssertEqual(list?.hasSuffix("\n  -[CalcTests.CalcTests test20]\n  and 3 more"), true, list ?? "")
    }

    func test_aLogWithNoFailedTest_listsNone() {
        XCTAssertNil(MutationTestingAbortReason.failedTestsList(in: "error: no such module 'Calc'\n"))
        let description = MutationTestingAbortReason.baselineTestFailed(log: "error: x", mutatedFilePaths: [])
            .description
        XCTAssertFalse(description.contains("failed:\n"), description)
    }

    // A step stopped at its limit says which, the limit and where its log is, then where it was: its last lines.
    func test_aStepPastTheBuildTimeout_namesItself_theLimit_theLog_andItsLastLines() {
        let output = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n\(xcTestFailure)\n"
        let description = MutationTestingAbortReason.buildTimeoutReached(
            step: .baseline, seconds: 600, output: output, log: "/logs/baseline run.log"
        ).description

        XCTAssertTrue(
            description.hasPrefix("SwiftMutator stopped the baseline run, which builds your project"), description
        )
        XCTAssertTrue(description.contains("after 600 s, the limit buildTimeout or --build-timeout sets"), description)
        XCTAssertTrue(description.contains("This test failed:\n  -[CalcTests.CalcTests testAdd]"), description)
        XCTAssertTrue(description.contains("Its log is in /logs/baseline run.log."), description)
        XCTAssertTrue(description.contains("The last lines it printed:\n\nline 12\n"), description)
        XCTAssertFalse(description.contains("line 11\n"), description)
        XCTAssertTrue(description.contains("raise buildTimeout"), description)
    }

    func test_eachStepPastTheBuildTimeout_isNamed() {
        let build = MutationTestingAbortReason.buildTimeoutReached(
            step: .buildForTesting, seconds: 1_800, output: "", log: nil
        ).description
        let clone = MutationTestingAbortReason.buildTimeoutReached(
            step: .workerBaseline(worker: 3, directory: "/p_worker3"), seconds: 90.5, output: "", log: nil
        ).description

        XCTAssertTrue(build.contains("stopped xcodebuild's build for testing after 1800 s"), build)
        XCTAssertTrue(build.contains("It kept no log. It printed nothing."), build)
        XCTAssertTrue(clone.contains("the copy it made for parallel worker 3, at /p_worker3, after 90.5 s"), clone)
    }

    // Each exits as a failed baseline does, and a clone's end line names its worker.
    func test_theBuildAborts_exitAsAFailedBaseline() {
        let clone = MutationTestingAbortReason.buildTimeoutReached(
            step: .workerBaseline(worker: 3, directory: "/p_worker3"), seconds: 60, output: "", log: nil
        )

        XCTAssertEqual(clone.exitStatus, .baselineFailed)
        XCTAssertEqual(
            MutationTestingAbortReason.buildForTestingFailed(description: "", log: nil).exitStatus, .baselineFailed
        )
        XCTAssertEqual(
            ResultsEnd.detail(for: MuterError.mutationTestingAborted(reason: clone)),
            "buildTimeoutReached(worker: 3)"
        )
        XCTAssertEqual(
            ResultsEnd.detail(for: MuterError.mutationTestingAborted(reason: .buildTimeoutReached(
                step: .baseline, seconds: 60, output: "", log: nil
            ))),
            "buildTimeoutReached"
        )
    }

    func test_aFailedBuild_namesItsLog() {
        let description = MutationTestingAbortReason.buildForTestingFailed(
            description: "xcodebuild build-for-testing failed with exit code 65:\nerror: x",
            log: "/logs/failed build 1.log"
        ).description

        XCTAssertTrue(description.hasPrefix("xcodebuild build-for-testing failed with exit code 65:\nerror: x"))
        XCTAssertTrue(description.contains("The build's log is in /logs/failed build 1.log."), description)
        XCTAssertTrue(description.contains("tested no mutant"), description)
    }
}
