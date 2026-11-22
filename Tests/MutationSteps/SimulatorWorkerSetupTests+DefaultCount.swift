@testable import muterCore
import XCTest

/// Whether a default count of xcodebuild workers keeps its simulators once the baseline has passed.
extension SimulatorWorkerSetupTests {
    // N workers test a mutant in S / N of the run's time; the destination pays a clone and a boot, more than 10 s, on
    // top of S / K over its K clones. S / N no more than 10 s plus S / K is surely faster.
    func test_theDefaultSimulators_areDropped_unlessTheBaselineShowsTheyShouldBeFaster() {
        func reason(_ clones: Int, _ seconds: Double, workers: Int = 2) -> String? {
            SimulatorWorkerSetup.reasonToDropTheDefaultSimulators(
                .init(clones: clones, testSeconds: seconds), workers: workers
            )
        }

        XCTAssertNil(reason(1, 600))
        XCTAssertNil(reason(2, 600))
        XCTAssertNil(reason(4, 20))
        XCTAssertNil(reason(3, 50), "25 s on the simulators, at least 26.7 s on the destination")
        XCTAssertNil(reason(3, 60))
        XCTAssertNotNil(reason(3, 60.5))
        XCTAssertNil(reason(4, 40))
        XCTAssertEqual(
            reason(4, 40.5),
            "the baseline's parallel testing spread 40.5 s of tests over 4 clones, which 2 workers testing one at a "
                + "time, each on a simulator of its own, could make slower; `--workers 2` tests on 2 simulators anyway"
        )
        XCTAssertNil(reason(3, 600, workers: 3))
        XCTAssertNil(reason(4, 120, workers: 3))
        XCTAssertNotNil(reason(4, 121, workers: 3))
    }

    // No clone line: the destination tested one test at a time, as each worker does, so several are faster.
    func test_theDefaultSimulators_areKept_whenTheBaselinePrintedNoCloneLine() {
        XCTAssertNil(SimulatorWorkerSetup.reasonToDropTheDefaultSimulators(nil, workers: 2))
    }

    // One worker keeps the lone worker's rule: one clone, or no more than 10 s of tests.
    func test_simulatorsAreFaster_forOneWorker_isTheLoneWorkersRule() {
        func faster(_ clones: Int, _ seconds: Double) -> Bool {
            SimulatorWorkerSetup.simulatorsAreFaster(given: .init(clones: clones, testSeconds: seconds), workers: 1)
        }

        XCTAssertTrue(faster(1, 60))
        XCTAssertTrue(faster(3, 9))
        XCTAssertTrue(faster(3, 10))
        XCTAssertFalse(faster(2, 11))
        XCTAssertFalse(faster(8, 400))
    }

    // Only a count SwiftMutator chose, whose runs on the destination would test in parallel, unless the key asked for
    // simulators whatever the baseline shows.
    func test_theDefaultSimulators_areCheckedAgainstTheBaseline_onlyWhenTheDestinationTestsInParallel() {
        func checks(
            workers: Int? = nil,
            key: ConfigurationSwitch = .unset,
            arguments: [String] = [],
            parallelizes: Bool = true
        ) -> Bool {
            let configuration = MuterConfiguration(
                executable: "/usr/bin/xcodebuild",
                arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17"] + arguments + ["test"],
                mutationTestWorkers: workers,
                oneWorkerSimulator: key
            )
            let xctestrun = parallelizes ? XCTestRun.parallelizing : XCTestRun()
            return SimulatorWorkerSetup.checksTheDefaultSimulators(configuration, given: xctestrun)
        }

        XCTAssertTrue(checks())
        XCTAssertTrue(checks(key: .disabled), "false gives no default count above 1 to check")
        XCTAssertTrue(checks(arguments: ["-parallel-testing-enabled", "YES"], parallelizes: false))
        XCTAssertFalse(checks(workers: 2))
        XCTAssertFalse(checks(key: .enabled))
        XCTAssertFalse(checks(parallelizes: false))
        XCTAssertFalse(checks(arguments: ["-parallel-testing-enabled", "NO"]))
    }
}
