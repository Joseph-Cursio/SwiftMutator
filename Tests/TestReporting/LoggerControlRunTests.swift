import Foundation
@testable import muterCore
import TestingExtensions

/// What the logger says of the control runs, with no mutant on, among the mutants.
final class LoggerControlRunTests: MuterTestCase {
    private let sut = Logger()

    // A control run that passed is no news; one that didn't names its first failed test, or says it named none.
    func test_aControlRunThatDidNotPass_saysSo_andOneThatPassed_saysNothing() {
        sut.controlRunFinished(ControlRunFinished(record: control(.passed, failing: nil, count: nil), count: 3))
        sut.controlRunFinished(ControlRunFinished(
            record: control(.failed, failing: [.init(name: "timing()", location: "TimingTests.swift:9:5")], count: 3),
            count: 3
        ))
        sut.controlRunFinished(ControlRunFinished(record: control(.timeout, failing: [], count: 0), count: 3))
        sut.controlRunFinished(ControlRunFinished(record: control(.runtimeError, failing: nil, count: nil), count: 1))

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ Control run 2 of 3, with no mutant on, failed: timing() at TimingTests.swift:9:5 (+2). A test that "
                + "fails with no mutant on is flaky, and the reports count a kill only such tests failed for as "
                + "suspect. Its log is control run 2.log.",
            "⚠️ Control run 2 of 3, with no mutant on, timed out, naming no failed test. Its log is control run 2.log.",
            "⚠️ Control run 2 of 1, with no mutant on, crashed, naming no failed test. Its log is control run 2.log.",
        ])
    }

    private func control(
        _ outcome: TestSuiteOutcome,
        failing tests: [FailedTestLine.FailedTest]?,
        count: Int?
    ) -> ControlRunResult {
        .make(number: 2, afterMutants: 150, outcome: outcome, worker: 1, failedTests: tests, failedTestCount: count)
    }
}
