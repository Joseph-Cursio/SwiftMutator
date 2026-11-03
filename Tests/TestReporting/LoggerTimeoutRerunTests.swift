import Foundation
@testable import muterCore
import Rainbow
import TestingExtensions

/// What the logger says of the timeouts a run tests again once the others are tested.
final class LoggerTimeoutRerunTests: MuterTestCase {
    private let sut = Logger()

    // How many, how many at once, the limit and the worst case: every rerun stopped at the limit.
    func test_theRerunsStart_sayingHowManyAtOnceUnderWhatLimit_andHowLongAtMost() {
        sut.timeoutRerunsStarted(TimeoutReruns(count: 3, workers: 1, limitSeconds: 72))
        sut.timeoutRerunsStarted(TimeoutReruns(count: 5, workers: 2, limitSeconds: 40.25))
        sut.timeoutRerunsStarted(TimeoutReruns(count: 1, workers: 1, limitSeconds: 20))

        XCTAssertEqual(printer.linesPassed, [
            "🔁 Running 3 timeouts again, one at a time, under the same 72 s limit: at most 4 min.",
            "🔁 Running 5 timeouts again, 2 at a time, under the same 40.3 s limit: at most 3 min.",
            "🔁 Running 1 timeout again, under the same 20 s limit: at most 1 min.",
        ])
    }

    func test_eachRerun_saysWhatItCameTo() {
        let point = MutationPoint.make(filePath: "/tmp/project/Module.swift", position: 3)
        let snapshot = MutationOperator.Snapshot.make(before: "==", after: "!=", description: "changed == to !=")
        for (number, outcome) in [TestSuiteOutcome.failed, .passed, .timeout].enumerated() {
            sut.timeoutRerunFinished(
                TimeoutRerun(
                    rerun: .make(testSuiteOutcome: outcome, point: point, snapshot: snapshot),
                    log: .make(mutationPoint: point),
                    seconds: 41.23,
                    number: number + 1,
                    count: 3
                )
            )
        }

        XCTAssertEqual(printer.linesPassed, [
            "🔁 1 of 3 killed at Module.swift:3:3 (changed == to !=), in 41.2 s",
            "🔁 2 of 3 survived at Module.swift:3:3 (changed == to !=), in 41.2 s",
            "🔁 3 of 3 timed out again at Module.swift:3:3 (changed == to !=), in 41.2 s",
        ])
    }

    // A mutant's run that ran again because the simulator didn't launch the first, which isn't a timeout's rerun.
    func test_aRunRepeatedAfterALaunchFailure_saysWhereWhyAndWhichLog() {
        let point = MutationPoint.make(filePath: "/tmp/project/Module.swift", position: 3)
        let snapshot = MutationOperator.Snapshot.make(before: "==", after: "!=", description: "changed == to !=")

        sut.runRepeatedAfterLaunchFailure(RepeatedRun(
            mutant: .make(testSuiteOutcome: .failed, point: point, snapshot: snapshot),
            worker: 0,
            line: "Simulator device failed to launch com.example.App.",
            log: .make(mutationPoint: point, keptFileName: "ROR @ Module.swift-3-3 1234 (launch failed).log")
        ))

        XCTAssertEqual(printer.linesPassed, [
            "🔁 The simulator didn't launch the tests for Module.swift:3:3 (changed == to !=), so they ran again. "
                + "The first run's log, ROR @ Module.swift-3-3 1234 (launch failed).log, says: "
                + "Simulator device failed to launch com.example.App.",
        ])
    }

    func test_theRerunsEnd_sayingHowManyChanged_andWhatTheyCameTo() {
        var tally = TimeoutRerunTally(TimeoutReruns(count: 4, workers: 1, limitSeconds: 72))
        for outcome: TestSuiteOutcome in [.timeout, .runtimeError, .timeout, .buildError] {
            tally.add(outcome)
        }
        var none = TimeoutRerunTally(TimeoutReruns(count: 1, workers: 1, limitSeconds: 72))
        none.add(.timeout)

        sut.timeoutRerunsFinished(tally)
        sut.timeoutRerunsFinished(none)

        XCTAssertEqual(printer.linesPassed, [
            "🔁 Ran 4 timeouts again, and 2 changed: 1 killed, 1 build error, 2 timed out again.",
            "🔁 Ran 1 timeout again, and none changed: 1 timed out again.",
        ])
    }

    // The progress counted each mutant's first run, so the reruns leave it as it was: every mutant tested.
    func test_withoutATerminal_theRerunsPrintNoProgressLine() {
        current.standardOutIsATerminal = false
        sut.resumePlanned(.make(reused: 0, toTest: 2, retestedBecause: [.notRecorded: 2]))
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 2)
        )
        for outcome: TestSuiteOutcome in [.timeout, .failed] {
            sut.newMutationTestOutcomeAvailable(mutation: .make(testSuiteOutcome: outcome))
        }
        let printedBefore = printer.linesPassed.count

        sut.timeoutRerunsStarted(TimeoutReruns(count: 1, workers: 1, limitSeconds: 20))
        sut.timeoutRerunFinished(
            TimeoutRerun(rerun: .make(testSuiteOutcome: .failed), log: .make(), seconds: 3, number: 1, count: 1)
        )
        var tally = TimeoutRerunTally(TimeoutReruns(count: 1, workers: 1, limitSeconds: 20))
        tally.add(.failed)
        sut.timeoutRerunsFinished(tally)

        let lines = Array(printer.linesPassed.dropFirst(printedBefore))
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("🔁 ") }, "\(lines)")
        XCTAssertTrue(printer.linesPassed[printedBefore - 1].contains("] 2 of 2 (100%) | "))
    }

    func test_aResume_namesTheTimeoutsNotRunAgain_andThoseUnderAShorterLimit() {
        sut.resumePlanned(.make(reused: 3, toTest: 2, retestedBecause: [.timeoutNotRerun: 1, .notRecorded: 1]))
        sut.resumePlanned(.make(reused: 3, toTest: 2, retestedBecause: [.timeoutNotRerun: 2]))
        sut.resumePlanned(.make(reused: 3, toTest: 2, retestedBecause: [.timeoutUnderShorterLimit: 1, .notRecorded: 1]))

        XCTAssertEqual(printer.linesPassed, [
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 3 results still hold, "
                + "so 2 mutants are left to test (1 never tested, 1 timeout not run again at lower load).",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 3 results still hold, "
                + "so 2 mutants are left to test (2 timeouts not run again at lower load).",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 3 results still hold, "
                + "so 2 mutants are left to test (1 never tested, 1 timeout under a shorter limit).",
        ])
    }
}
