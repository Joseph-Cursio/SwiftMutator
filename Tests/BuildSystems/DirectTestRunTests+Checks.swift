@testable import muterCore
import XCTest

extension DirectTestRunTests {
    func test_whyNot_acceptsARunOfTheBaselinesTestsInEachBundle_inAnyOrder() {
        let baseline = """
            Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
            ✔ Test run with 4294 tests in 500 suites passed after 11.641 seconds.
            ✔ Test run with 1 test in 1 suite passed after 0.040 seconds.
            """
        let direct = """
            ✔ Test run with 1 test in 1 suite passed after 0.040 seconds.
            ✔ Test run with 4294 tests in 500 suites passed after 11.889 seconds.
            """

        XCTAssertNil(DirectTestRun.whyNot(baselineLog: baseline, outcome: .passed, log: direct))
        XCTAssertNotNil(DirectTestRun.whyNot(baselineLog: baseline, outcome: .failed, log: direct))
        XCTAssertEqual(
            DirectTestRun.whyNot(baselineLog: baseline, outcome: .passed, log: "✔ Test run with 4295 tests "),
            "running the test bundles directly ran 4295 Swift Testing tests, where `swift test` ran 1, 4294"
        )
        XCTAssertEqual(
            DirectTestRun.whyNot(baselineLog: "Executed 0 tests, with 0 failures", outcome: .passed, log: ""),
            "the baseline ran no Swift Testing test"
        )
    }

    func test_ranXCTestTests_countsOnlyARunOfSome() {
        XCTAssertFalse(DirectTestRun.ranXCTestTests(in: "Executed 0 tests, with 0 failures (0 unexpected)"))
        XCTAssertTrue(DirectTestRun.ranXCTestTests(in: "Executed 1 test, with 1 failure (0 unexpected)"))
        XCTAssertFalse(DirectTestRun.ranXCTestTests(in: "✔ Test run with 12 tests in 3 suites passed"))
    }
}
