@testable import muterCore
import TestingExtensions

/// What the logger says of the kills a run tests again with the property tests skipped.
final class LoggerExampleRerunTests: MuterTestCase {
    private let sut = Logger()

    func test_theReruns_sayHowManyAtOnce_andWhatTheyCameTo() {
        sut.exampleRerunsStarted(ExampleReruns(count: 12, workers: 4))
        sut.exampleRerunsStarted(ExampleReruns(count: 1, workers: 1))
        var tally = ExampleRerunTally(ExampleReruns(count: 3, workers: 1))
        tally.add(.init(outcome: .failed, killingTests: nil), examplesFailed: true)
        tally.add(.init(outcome: .passed, killingTests: nil), examplesFailed: false)
        sut.exampleRerunsFinished(tally)
        tally.add(.init(outcome: .timeout, killingTests: nil), examplesFailed: false)
        sut.exampleRerunsFinished(tally)

        XCTAssertEqual(printer.linesPassed, [
            "🧪 Running every test but the property tests again for 12 kills only properties were recorded making, 4 "
                + "at a time.",
            "🧪 Running every test but the property tests again for 1 kill only properties were recorded making.",
            "🧪 Ran every test but the property tests again for 2 kills: an example failed too for 1, and every test "
                + "passed for 1.",
            "🧪 Ran every test but the property tests again for 3 kills: an example failed too for 1, and every test "
                + "passed for 1; 1 settled nothing, as they timed out, didn't build, crashed or only failed property "
                + "tests.",
        ])
    }

    func test_reruns_thatMeanNothing_areSkipped_sayingWhy() {
        sut.exampleRerunsSkipped(reason: "a reason", log: "e.log")

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ No kill was tested again with the property tests skipped: a reason. The reports count what the runs "
                + "recorded, so the count by both may be low. Its log is e.log.",
        ])
    }
}
