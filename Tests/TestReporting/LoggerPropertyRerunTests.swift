@testable import muterCore
import TestingExtensions

/// What the logger says of the kills a run tests again with the property tests alone.
final class LoggerPropertyRerunTests: MuterTestCase {
    private let sut = Logger()

    func test_theReruns_sayHowManyAtOnce_andWhatTheyCameTo() {
        sut.propertyRerunsStarted(PropertyReruns(count: 12, workers: 4))
        sut.propertyRerunsStarted(PropertyReruns(count: 3, workers: 1))
        sut.propertyRerunsStarted(PropertyReruns(count: 1, workers: 1))
        var tally = PropertyRerunTally(PropertyReruns(count: 3, workers: 1))
        tally.add(.init(outcome: .failed, killingTests: nil))
        tally.add(.init(outcome: .passed, killingTests: nil))
        sut.propertyRerunsFinished(tally)
        tally.add(.init(outcome: .timeout, killingTests: nil))
        sut.propertyRerunsFinished(tally)

        XCTAssertEqual(printer.linesPassed, [
            "🧪 Running the property tests again for 12 kills only examples were recorded making, 4 at a time.",
            "🧪 Running the property tests again for 3 kills only examples were recorded making, one at a time.",
            "🧪 Running the property tests again for 1 kill only examples were recorded making.",
            "🧪 Ran the property tests again for 2 kills: a property test failed too for 1, and every one passed for 1.",
            "🧪 Ran the property tests again for 3 kills: a property test failed too for 1, and every one passed for 1; "
                + "1 timed out or didn't build, which settles nothing.",
        ])
    }

    func test_reruns_thatMeanNothing_areSkipped_sayingWhy() {
        let reason = "the tests propertyTestFilter selects didn't pass with no mutant on"
        sut.propertyRerunsSkipped(reason: reason, log: "p.log")
        sut.propertyRerunsSkipped(reason: "a reason", log: nil)

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ No kill was tested again with the property tests alone: the tests propertyTestFilter selects didn't "
                + "pass with no mutant on. The reports count what the runs recorded, so the count by both may be low. "
                + "Its log is p.log.",
            "⚠️ No kill was tested again with the property tests alone: a reason. The reports count what the runs "
                + "recorded, so the count by both may be low.",
        ])
    }
}
