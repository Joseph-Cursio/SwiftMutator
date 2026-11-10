@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

/// An xcodebuild project's workers, each on a simulator of its own.
final class PerformMutationTestingXcodeWorkersTests: MuterTestCase {
    /// What the simulators and the delegate had been asked, and how many headers were written, when the workers were
    /// said.
    private struct StateAtTheChoice {
        let simulators: [String]
        let delegate: [String]
        let headers: Int
    }

    let state = MutationTestState()
    private var clonedCounts: [Int] = []

    lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [weak self] _, count in
            guard let self else { return [] }
            clonedCounts.append(count)
            return []
        },
        removeWorkerDirectories: { _ in }
    )

    let destination = "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5"
    private let checkRun = "runTestsWithoutBuilding(using:timeLimit:savingResultsIntoFileNamed:)"
    /// The output files of the runs with no mutant on that check the workers' simulators, not the timed test run's.
    var checkRuns: [String] {
        ioDelegate.testLogs.filter { $0.contains("no-mutant run worker") }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            mutationTestWorkers: 2
        )
        state.apply([.testDiagnosticsOptionChecked(canBeTurnedOff: true)])
        state.mutationMapping = try (1...4).map(makeSchemataMapping(line:))
    }

    // The simulators are made before the baseline, which they boot during, and checked once it has passed. Only then
    // is the number of workers said, and the header written with it, before any mutant's run.
    func test_theSimulatorsAreMadeBeforeTheBaseline_andCheckedBeforeTheWorkersAreSaid() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        var atTheBaseline: [String] = []
        ioDelegate.whileRunningBaseline = { [workerSimulators] _ in atTheBaseline = workerSimulators.calls }
        var atTheChoice: StateAtTheChoice?
        whenSent(.workersChosen) { [resultsFiles, workerSimulators, ioDelegate] _ in
            let headers = (try? resultsFiles.records(ResultsHeader.self).count) ?? -1
            atTheChoice = StateAtTheChoice(
                simulators: workerSimulators.calls, delegate: ioDelegate.methodCalls, headers: headers
            )
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            Array(atTheBaseline.prefix(2)),
            ["sweep /project_mutated", "prepare 2 like \(destination) for /project_mutated"]
        )
        XCTAssertEqual(atTheChoice?.simulators, [
            "sweep /project_mutated",
            "prepare 2 like \(destination) for /project_mutated",
            "boot SIM-0 SIM-1",
        ])
        // The check runs run at once, so in no set order.
        XCTAssertEqual(atTheChoice?.delegate.first, "benchmarkTests(using:savingResultsIntoFileNamed:)")
        XCTAssertEqual(
            atTheChoice?.delegate.dropFirst().sorted(),
            [checkRun, checkRun, "switchOn(schemata:for:at:named:)", "switchOn(schemata:for:at:named:)"]
        )
        XCTAssertEqual(atTheChoice?.headers, 0)
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 4)
    }

    // Each check run tests from its worker's own `.xctestrun`, with no mutant switched on in it, on its simulator, one
    // test at a time, and keeps its log.
    func test_eachSimulatorRunsTheTestsWithNoMutantOn_fromItsWorkersTestRun() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)

        _ = try await sut.run(with: state)

        // The timed test run follows them, on worker 0.
        let checks = ioDelegate.configurationsWithoutBuilding.compactMap(\.xcodeWorker)
        XCTAssertEqual(checks.sorted { $0.testRunFile > $1.testRunFile }, [worker(0), worker(0), worker(1)])
        XCTAssertEqual(ioDelegate.testLogs.prefix(4).last, "/logs/running/timed test run")
        XCTAssertEqual(
            Set(ioDelegate.testLogs.filter { $0.contains("no-mutant") }),
            ["/logs/running/no-mutant run worker 0", "/logs/running/no-mutant run worker 1"]
        )
        let switchedOff = zip(ioDelegate.schematas, ioDelegate.testRunFileNames).filter { $0.0 == .null }.map(\.1)
        XCTAssertEqual(switchedOff.sorted(), ["muter-worker1.xctestrun", "muter.xctestrun", "muter.xctestrun"])
        XCTAssertEqual(
            fileManager.createdFiles["/logs/no-mutant run worker 1.log"],
            Data("timed test run log".utf8)
        )
        // Each moves the output it wrote, so nothing is left in `running/`, nor written twice.
        for index in 0 ... 1 {
            let output = "/logs/running/no-mutant run worker \(index)"
            XCTAssertTrue(
                ioDelegate.keptOutputs.contains { $0 == (output, "/logs/no-mutant run worker \(index).log") },
                "\(ioDelegate.keptOutputs)"
            )
        }
    }

    // The timed test run sets the default as SwiftPM's does: 5 times it, and once more for the second worker. The check
    // runs, which paid for each simulator's first install and launch, don't.
    func test_theTimedTestRun_setsTheDefaultTimeLimit_withOneMoreForEachWorkerBeyondTheFirst() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let nanoseconds = Locked<UInt64>(1)
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds.value) }
        // The two check runs, at once, then the timed test run.
        let runs = Locked(0)
        ioDelegate.whileRunningTestsWithoutBuilding = {
            let seconds: UInt64 = runs.change { $0 += 1; return $0 } <= 2 ? 90 : 10
            nanoseconds.change { $0 += seconds * 1_000_000_000 }
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), Array(repeating: 60, count: 4))
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.testRunSeconds, 10)
        XCTAssertEqual(header.timeoutSeconds, 60)
    }

    // With a buildTimeout, the timed test run, on the first worker's simulator, may take 5 times the slowest check run,
    // which ran its tests one at a time as it will, when that took longer than the baseline.
    func test_theTimedTestRunsLimit_comesFromTheSlowestCheckRun() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            mutationTestWorkers: 2,
            buildTimeout: 3_600
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let nanoseconds = Locked<UInt64>(1)
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds.value) }
        // The two check runs go at once on one clock, so either may span the other's time too: only one takes any, so
        // the slowest is 90 s however they interleave. Then the timed test run.
        let runs = Locked(0)
        ioDelegate.whileRunningTestsWithoutBuilding = {
            let seconds: UInt64 = switch runs.change { $0 += 1; return $0 } {
            case 1: 90
            case 2: 0
            default: 10
            }
            nanoseconds.change { $0 += seconds * 1_000_000_000 }
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.timeLimitsWithoutBuilding, [3_600, 3_600, 450])
    }

    // Nothing is copied or built again: every worker tests in the mutated project, from the baseline's build, on its
    // own simulator, from its own `.xctestrun`, with its own derived data, one test at a time.
    func test_eachWorkerTestsInTheMutatedProject_onItsOwnSimulator() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)

        let result = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(ioDelegate.builtWorkerDirectories, [])
        XCTAssertEqual(Set(ioDelegate.workingDirectories), [state.mutatedProjectDirectoryURL])
        XCTAssertEqual(distinct(ioDelegate.configurations.compactMap(\.xcodeWorker)).count, 2)
        let workers = [worker(0), worker(1)]
        XCTAssertTrue(ioDelegate.configurations.allSatisfy { $0.xcodeWorker.map(workers.contains) == true })
        XCTAssertEqual(ioDelegate.mutantsNotSwitchedOnForTheirRun, [])
        let mutantFiles = zip(ioDelegate.schematas, ioDelegate.testRunFileNames).filter { $0.0 != .null }.map(\.1)
        XCTAssertEqual(mutantFiles.count, 4, "each mutant switched on once")
        XCTAssertEqual(Set(mutantFiles), ["muter.xctestrun", "muter-worker1.xctestrun"])
        XCTAssertEqual(outcomes(in: result), Array(repeating: .failed, count: 4))
    }

    func test_theWorkersUsed_areSaidToTestOnSimulators() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(choices().map(\.sentence), ["👷 Testing 2 mutants at a time, each on a simulator of its own."])
    }

    // The run's other files go as its clones would: the mutated project keeps only worker 0's `.xctestrun`. The
    // simulators go once the work has ended.
    func test_theWorkersFiles_areRemovedAtTheEnd_andTheirSimulatorsOnceTheWorkHasEnded() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            fileManager.paths.filter { $0.hasSuffix(".DerivedData.noindex") || $0.hasSuffix(".xctestrun") }.sorted(),
            [
                "/project_mutated.DerivedData.noindex",
                "/project_mutated/muter-worker1.xctestrun",
                "/project_mutated_worker1.DerivedData.noindex",
            ]
        )
        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        await current.interruption.workEnded()
        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
    }

    /// Worker `number`'s part of the configuration, on the spy's simulator `SIM-<number>`.
    func worker(_ number: Int) -> MuterConfiguration.XcodeWorker {
        MuterConfiguration.XcodeWorker(
            testRunFile: MutationTestingDelegate.testRunFileName(ofWorker: number),
            derivedData: MuterConfiguration.XcodeWorker.derivedData(
                ofWorker: number, in: state.mutatedProjectDirectoryURL
            ),
            testDiagnosticsOff: true,
            destination: "platform=iOS Simulator,id=SIM-\(number)",
            parallelTestingOff: true
        )
    }

    /// Asserts that every mutant was tested one at a time, from `muter.xctestrun`, on the test command's destination,
    /// with parallel testing as the scheme has it.
    func assertTestedOnOneWorker(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") },
            Array(repeating: "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)", count: 4),
            file: file,
            line: line
        )
        let firstWorker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/project_mutated.DerivedData.noindex",
            testDiagnosticsOff: true
        )
        XCTAssertEqual(
            distinct(ioDelegate.configurations.compactMap(\.xcodeWorker)),
            [firstWorker],
            file: file,
            line: line
        )
    }

    /// The mutants' runs whose test command names `udid`'s simulator.
    func runs(on udid: String) -> [MuterConfiguration] {
        ioDelegate.configurations.filter { configuration in
            configuration.testWithoutBuildArguments(with: "muter.xctestrun").contains { $0.hasSuffix("id=\(udid)") }
        }
    }

    /// Each of `workers` once, in the order they first come.
    private func distinct(_ workers: [MuterConfiguration.XcodeWorker]) -> [MuterConfiguration.XcodeWorker] {
        workers.reduce(into: []) { distinct, worker in
            if !distinct.contains(worker) { distinct.append(worker) }
        }
    }

    /// The worker choices sent from now on, until the test ends.
    func sentChoices() -> () -> [WorkerChoice] {
        var choices: [WorkerChoice] = []
        whenSent(.workersChosen) { event in
            if case let .workersChosen(choice) = event { choices.append(choice) }
        }
        return { choices }
    }

    /// Calls `handler` with each event sent with `name`, from the task that sends it, until the test ends.
    func whenSent(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) {
        let observer = runEvents.observe(name, handler)
        addTeardownBlock { observer.cancel() }
    }

    /// Each mutant's outcome, in job order, from what `run(with:)` returned.
    private func outcomes(in result: [MutationTestState.Change]) -> [TestSuiteOutcome] {
        guard case let .mutationTestOutcomeGenerated(outcome) = result.first else { return [] }
        return outcome.mutations.map(\.testSuiteOutcome)
    }

    func makeSchemataMapping(line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/project_mutated/file\(line).swift",
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
            )
        )
    }
}
