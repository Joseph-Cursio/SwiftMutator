@testable import muterCore
import XCTest

/// An xcodebuild run on a simulator that neither `mutationTestWorkers` nor `--workers` gives a count, on a Mac with
/// enough processors and memory for 2 workers (`MuterConfiguration.defaultWorkerCount`).
final class DefaultSimulatorWorkerRunTests: MuterTestCase {
    let state = MutationTestState()
    let destination = "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5"
    var choices: [WorkerChoice] = []

    lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { _, _ in [] },
        removeWorkerDirectories: { _ in }
    )

    /// The output files of the runs with no mutant on that check the workers' simulators, not the timed test run's.
    private var checkRuns: [String] {
        ioDelegate.testLogs.filter { $0.contains("no-mutant run worker") }
    }

    private let bothCheckRuns: Set = ["/logs/running/no-mutant run worker 0", "/logs/running/no-mutant run worker 1"]
    /// A baseline that spread 42 s of tests over 4 clones, which 2 workers testing one test at a time could take longer
    /// over than the destination's runs.
    let wideBaseline = """
    Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (121)' (12.000 seconds)
    Test case 'SumTests.difference()' passed on 'Clone 2 of iPhone 17 Pro - App (122)' (10.000 seconds)
    Test case 'ParserTests.parse()' passed on 'Clone 3 of iPhone 17 Pro - App (123)' (10.000 seconds)
    Test case 'ParserTests.print()' passed on 'Clone 4 of iPhone 17 Pro - App (124)' (10.000 seconds)
    ** TEST SUCCEEDED **
    """
    /// A baseline that spread 60 s of tests over 2 clones, no more than the workers.
    private let narrowBaseline = """
    Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (121)' (30.000 seconds)
    Test case 'ParserTests.parse()' passed on 'Clone 2 of iPhone 17 Pro - App (122)' (30.000 seconds)
    ** TEST SUCCEEDED **
    """

    // After `setUpWithError`, as XCTest calls them, as the world is made anew in each.
    override func setUp() {
        super.setUp()

        current.processorCount = 18
        current.physicalMemory = 64 << 30
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        configure()
        state.apply([.testDiagnosticsOptionChecked(canBeTurnedOff: true)])
        let observer = runEvents.observe(.workersChosen) { [weak self] event in
            if case let .workersChosen(choice) = event { self?.choices.append(choice) }
        }
        addTeardownBlock { observer.cancel() }
    }

    // Without parallel testing, a run on the destination tests one test at a time, as each worker does: no check.
    func test_enoughMutants_testOnTwoSimulators_byDefault() async throws {
        try testing(50)

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, [
            "sweep /project_mutated",
            "prepare 2 like \(destination) for /project_mutated",
            "boot SIM-0 SIM-1",
        ])
        XCTAssertEqual(Set(checkRuns), bothCheckRuns)
        XCTAssertEqual(Set(ioDelegate.configurations.compactMap(\.xcodeWorker?.destination)), [
            "platform=iOS Simulator,id=SIM-0", "platform=iOS Simulator,id=SIM-1",
        ])
        XCTAssertEqual(choices.map(\.sentence), [
            "👷 Testing 2 mutants at a time, each on a simulator of its own, by default: `--workers` or "
                + "`mutationTestWorkers` sets another count.",
        ])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.workers, 2)
        XCTAssertEqual(header.workersOnOwnSimulators, .ownSimulators)
        XCTAssertNil(header.configuration.mutationTestWorkers, "the configuration is kept as loaded")
    }

    // A second simulator costs 15 to 30 s, which fewer than 50 mutants don't pay back: the lone worker's plan decides.
    func test_fewMutants_leaveOneWorker_onASimulatorOfItsOwn_whenThatShouldBeFaster() async throws {
        try testing(49)
        state.apply([.projectXCTestRun(.parallelizing)])
        ioDelegate.baselineTestLog = """
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (121)' (0.010 seconds)
        ** TEST SUCCEEDED **
        """

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, [
            "sweep /project_mutated",
            "prepare 1 like \(destination) for /project_mutated",
            "boot SIM-0",
        ])
        XCTAssertEqual(choices.map(\.sentence), ["👷 Testing one mutant at a time, on a simulator of its own."])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.workers, 1)
        XCTAssertEqual(header.workersOnOwnSimulators, .ownSimulators)
    }

    func test_fewMutants_leaveOneWorker_onTheDestination_withoutParallelTesting() async throws {
        try testing(49)

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices.map(\.sentence), [nil])
        assertTestedOnTheDestination()
    }

    // 2 workers testing one test at a time take about 21 s of the run's time for each mutant; the destination about
    // 42 / 4 s, plus its clone and boot.
    func test_aBaselineSpreadOverMoreClonesThanWorkers_testsOnTheDestinationInstead() async throws {
        try testing(50)
        state.apply([.projectXCTestRun(.parallelizing)])
        ioDelegate.baselineTestLog = wideBaseline

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, [
            "sweep /project_mutated",
            "prepare 2 like \(destination) for /project_mutated",
            "boot SIM-0 SIM-1",
            "removeAll",
        ])
        XCTAssertEqual(checkRuns, [])
        XCTAssertEqual(choices.map(\.sentence), [
            "👷 Testing one mutant at a time on the test command's destination instead: the baseline's parallel "
                + "testing spread 42.0 s of tests over 4 clones, which 2 workers testing one at a time, each on a "
                + "simulator of its own, could make slower; `--workers 2` tests on 2 simulators anyway.",
        ])
        assertTestedOnTheDestination()
    }

    func test_aBaselineSpreadOverNoMoreClonesThanWorkers_keepsTheSimulators() async throws {
        try testing(50)
        state.apply([.projectXCTestRun(.parallelizing)])
        ioDelegate.baselineTestLog = narrowBaseline

        _ = try await sut.run(with: state)

        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        XCTAssertEqual(Set(checkRuns), bothCheckRuns)
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
    }

    func test_oneWorkerSimulatorTrue_keepsTheSimulators_withoutCheckingTheBaseline() async throws {
        configure(oneWorkerSimulator: .enabled)
        try testing(50)
        state.apply([.projectXCTestRun(.parallelizing)])
        ioDelegate.baselineTestLog = wideBaseline

        _ = try await sut.run(with: state)

        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
    }

    // False asks for no simulator SwiftMutator makes, so the run tests as it did before the default.
    func test_oneWorkerSimulatorFalse_testsOneAtATime_onTheDestination() async throws {
        configure(oneWorkerSimulator: .disabled)
        try testing(50)

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices.map(\.sentence), [nil])
        assertTestedOnTheDestination()
    }

    // As a lone worker's does: nobody asked for these workers, so nothing is said of them.
    func test_aDestinationThatResolvesToNoSimulator_fallsBackQuietly() async throws {
        try testing(50)
        let reason = "no available simulator matches `-destination \(destination)`, or more than one does"
        workerSimulators.preparing(.failure(WorkerSimulatorsUnavailable(reason: reason, destinationUnresolved: true)))

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            workerSimulators.calls,
            ["sweep /project_mutated", "prepare 2 like \(destination) for /project_mutated"]
        )
        XCTAssertEqual(choices.map(\.sentence), [nil])
        XCTAssertEqual(checkRuns, [])
        assertTestedOnTheDestination()
    }

    func test_aFailedCheckRun_testsOnTheDestinationInstead_andSaysWhy() async throws {
        try testing(50)
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 1"] = (.failed, "** TEST FAILED **")

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
        XCTAssertEqual(choices.map(\.sentence), [
            "👷 Testing one mutant at a time on the test command's destination instead: worker 1's run with no mutant "
                + "on, on its simulator, didn't pass (its log is no-mutant run worker 1.log).",
        ])
        assertTestedOnTheDestination()
    }

    // A count that was asked for is never checked against the baseline, nor dropped by the machine.
    func test_anAskedCount_isNotCheckedAgainstTheBaseline() async throws {
        state.muterConfiguration = state.muterConfiguration.overriding(workers: 3, timeout: nil)
        current.physicalMemory = 8 << 30
        try testing(50)
        state.apply([.projectXCTestRun(.parallelizing)])
        ioDelegate.baselineTestLog = wideBaseline

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls.dropFirst().first, "prepare 3 like \(destination) for /project_mutated")
        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [3])
    }

    func test_aMacDestination_testsOneAtATime() async throws {
        configure(destination: "platform=macOS")
        try testing(50)

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices.map(\.sentence), [nil])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [1])
    }

    /// An xcodebuild test command on `destination`, this suite's unless given, with the key and no workers asked for.
    func configure(destination: String? = nil, oneWorkerSimulator: ConfigurationSwitch = .unset) {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination ?? self.destination, "test"],
            oneWorkerSimulator: oneWorkerSimulator
        )
    }

    /// `mutants` mutants, one in each file, each failing its run, after a passing baseline.
    func testing(_ mutants: Int) throws {
        state.mutationMapping = try (1...mutants).map(makeSchemataMapping(line:))
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: mutants)
    }

    /// Asserts that every mutant was tested one at a time from `muter.xctestrun`, on the test command's destination,
    /// as the header says.
    func assertTestedOnTheDestination(file: StaticString = #filePath, line: UInt = #line) {
        let firstWorker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/project_mutated.DerivedData.noindex",
            testDiagnosticsOff: true
        )
        XCTAssertEqual(
            ioDelegate.configurations.map(\.xcodeWorker),
            Array(repeating: firstWorker, count: state.mutationMapping.count),
            file: file,
            line: line
        )
        let header = try? resultsFiles.records(ResultsHeader.self)
        XCTAssertEqual(header?.map(\.workers), [1], file: file, line: line)
        XCTAssertEqual(header?.map(\.workersOnOwnSimulators), [.testCommandsDestination], file: file, line: line)
    }

    private func makeSchemataMapping(line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/project_mutated/file\(line).swift",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line, line: line, column: 0),
                        snapshot: .null
                    ),
                ]
            ),
            filePath: "/project_mutated/file\(line).swift"
        )
    }
}
