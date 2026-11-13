@testable import muterCore
import TestingExtensions

/// What the logger says of the survivors a run tests again with the property tests alone.
final class LoggerPropertySurvivorRerunTests: MuterTestCase {
    private let sut = Logger()

    func test_theReruns_sayHowManyHowOftenAndAtOnce_andWhatTheyCameTo() {
        sut.propertySurvivorRerunsStarted(PropertySurvivorReruns(count: 12, runs: 10, workers: 4, leftOut: 3))
        sut.propertySurvivorRerunsStarted(PropertySurvivorReruns(count: 2, runs: 5, workers: 1, leftOut: 1))
        sut.propertySurvivorRerunsStarted(PropertySurvivorReruns(count: 1, runs: 1, workers: 1, leftOut: 0))
        var tally = PropertySurvivorRerunTally(PropertySurvivorReruns(count: 3, runs: 10, workers: 1, leftOut: 0))
        tally.add(.init(outcome: .failed, run: 4, runs: 10, killingTests: nil))
        tally.add(.init(outcome: .passed, run: 10, runs: 10, killingTests: nil))
        sut.propertySurvivorRerunsFinished(tally)
        tally.add(.init(outcome: .timeout, run: 2, runs: 10, killingTests: nil))
        sut.propertySurvivorRerunsFinished(tally)

        XCTAssertEqual(printer.linesPassed, [
            "🧪 Running the property tests again for 12 survivors whose code ran, up to 10 times each, 4 at a time. "
                + "3 more are over propertySurvivorRerunLimit.",
            "🧪 Running the property tests again for 2 survivors whose code ran, up to 5 times each, one at a time. "
                + "1 more is over propertySurvivorRerunLimit.",
            "🧪 Running the property tests again for 1 survivor whose code ran, once.",
            "🧪 Ran the property tests again for 2 survivors: a property test failed on a later run for 1, and every "
                + "one of 10 runs passed for 1. They stay survivors in the score.",
            "🧪 Ran the property tests again for 3 survivors: a property test failed on a later run for 1, and every "
                + "one of 10 runs passed for 1; 1 timed out or didn't build, which settles nothing. They stay "
                + "survivors in the score.",
        ])
    }

    func test_reruns_thatMeanNothing_areSkipped_sayingWhy() {
        sut.propertySurvivorRerunsSkipped(reason: "a reason", log: "p.log")
        sut.propertySurvivorRerunsSkipped(reason: "a reason", log: nil)

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ No survivor was tested again with the property tests alone: a reason. Its log is p.log.",
            "⚠️ No survivor was tested again with the property tests alone: a reason.",
        ])
    }
}
