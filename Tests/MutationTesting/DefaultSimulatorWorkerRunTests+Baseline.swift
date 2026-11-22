@testable import muterCore
import XCTest

/// How a default count of xcodebuild workers, and a run of too few mutants for one, read the baseline and fall back.
extension DefaultSimulatorWorkerRunTests {
    // No clone line: a mutant's run on the destination tests one test at a time, as each worker does.
    func test_aBaselineWithoutCloneLines_keepsTheSimulators() async throws {
        try testing(50)
        state.apply([.projectXCTestRun(.parallelizing)])
        ioDelegate.baselineTestLog = "** TEST SUCCEEDED **"

        _ = try await sut.run(with: state)

        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
    }

    // 50 s over 3 clones: 25 s of the run's time for each mutant on 2 simulators, less than the destination's
    // 10 + 50 / 3 s.
    func test_aMidSizeSuiteSpreadOverMoreClonesThanWorkers_keepsTheSimulators() async throws {
        try testing(50)
        state.apply([.projectXCTestRun(.parallelizing)])
        ioDelegate.baselineTestLog = """
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (121)' (20.000 seconds)
        Test case 'SumTests.difference()' passed on 'Clone 2 of iPhone 17 Pro - App (122)' (15.000 seconds)
        Test case 'ParserTests.parse()' passed on 'Clone 3 of iPhone 17 Pro - App (123)' (15.000 seconds)
        ** TEST SUCCEEDED **
        """

        _ = try await sut.run(with: state)

        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
    }

    // Too few mutants for a second simulator leave a lone worker, whose fallback reads as on a Mac with too little
    // memory for 2.
    func test_fewMutants_aWideBaseline_fallBackAsALoneWorkerDoes() async throws {
        try testing(49)
        state.apply([.projectXCTestRun(.parallelizing)])
        ioDelegate.baselineTestLog = wideBaseline

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
        XCTAssertEqual(choices.map(\.sentence), [
            "👷 Testing one mutant at a time on the test command's destination: the baseline's parallel testing spread "
                + "42.0 s of tests over 4 clones, which one at a time on one simulator could make slower; "
                + "`oneWorkerSimulator: true` tests on one anyway.",
        ])
        assertTestedOnTheDestination()
    }

    // True asked for simulators, so a destination that names no one simulator is said.
    func test_aDestinationThatResolvesToNoSimulator_isSaid_whenOneWorkerSimulatorIsTrue() async throws {
        configure(oneWorkerSimulator: .enabled)
        try testing(50)
        let reason = "no available simulator matches `-destination \(destination)`, or more than one does"
        workerSimulators.preparing(.failure(WorkerSimulatorsUnavailable(reason: reason, destinationUnresolved: true)))

        _ = try await sut.run(with: state)

        XCTAssertEqual(choices.map(\.sentence), [
            "👷 Testing one mutant at a time on the test command's destination instead: \(reason).",
        ])
        assertTestedOnTheDestination()
    }
}
