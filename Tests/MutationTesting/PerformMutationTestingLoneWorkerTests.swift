@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

/// One xcodebuild worker, which tests on a simulator of its own when that should be faster than on the test command's
/// destination (`SimulatorWorkerSetup.oneWorkerPlan(for:state:)`).
final class PerformMutationTestingLoneWorkerTests: MuterTestCase {
    let state = MutationTestState()

    lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { _, _ in [] },
        removeWorkerDirectories: { _ in }
    )

    let destination = "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5"
    /// The output files of the runs with no mutant on that check a worker's simulator, not the timed test run's.
    var checkRuns: [String] {
        ioDelegate.testLogs.filter { $0.hasSuffix("no-mutant run worker 0") }
    }
    /// A baseline whose tests ran on one clone, as the destination's runs would, each paying for its clone and boot.
    private let oneCloneBaseline = """
    Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (123)' (0.010 seconds)
    Test case 'SumTests.difference()' passed on 'Clone 1 of iPhone 17 Pro - App (123)' (0.010 seconds)
    ** TEST SUCCEEDED **
    """
    /// A baseline that spread 12 s of tests over two clones.
    let spreadBaseline = """
    Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (123)' (5.000 seconds)
    Test case 'ParserTests.parse()' passed on 'Clone 2 of iPhone 17 Pro - App (124)' (7.000 seconds)
    ** TEST SUCCEEDED **
    """

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        configure()
        state.apply([
            .testDiagnosticsOptionChecked(canBeTurnedOff: true),
            .projectXCTestRun(.parallelizing),
        ])
        state.mutationMapping = try (1...6).map(makeSchemataMapping(line:))
        ioDelegate.baselineTestLog = oneCloneBaseline
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 6)
    }

    // The simulator is made before the baseline, booted while it runs, and checked by one run with no mutant on, one
    // test at a time. The mutants then run on it in job order, from `muter.xctestrun`, with worker 0's derived data.
    func test_oneWorker_onAParallelizingProject_testsInOrderOnASimulatorOfItsOwn() async throws {
        var atTheBaseline: [String] = []
        ioDelegate.whileRunningBaseline = { [workerSimulators] _ in atTheBaseline = workerSimulators.calls }
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            Array(atTheBaseline.prefix(2)),
            ["sweep /project_mutated", "prepare 1 like \(destination) for /project_mutated"]
        )
        XCTAssertEqual(workerSimulators.calls, [
            "sweep /project_mutated",
            "prepare 1 like \(destination) for /project_mutated",
            "boot SIM-0",
        ])
        // The check run, then the timed test run.
        XCTAssertEqual(ioDelegate.configurationsWithoutBuilding.map(\.xcodeWorker), [worker0, worker0])
        XCTAssertEqual(
            ioDelegate.configurationsWithoutBuilding.first?
                .testWithoutBuildArguments(with: "muter.xctestrun")
                .joined(separator: " ")
                .contains("-parallel-testing-enabled NO"),
            true
        )
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 6))
        let mutants = zip(ioDelegate.schematas, ioDelegate.testRunFileNames).filter { $0.0 != .null }
        XCTAssertEqual(mutants.map(\.0.id), state.mutationMapping.flatMap(\.mutationSchemata).map(\.id))
        XCTAssertEqual(Set(mutants.map(\.1)), ["muter.xctestrun"])
        XCTAssertEqual(ioDelegate.mutantsNotSwitchedOnForTheirRun, [])
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.worker), Array(repeating: 0, count: 6))
        XCTAssertEqual(choices().map(\.sentence), ["👷 Testing one mutant at a time, on a simulator of its own."])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [1])
        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        await current.interruption.workEnded()
        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
    }

    // The session keeps the deleted simulator's worker, for its files, but no mutant may run on it.
    func test_oneWorker_aFailedCheckRun_testsOnTheTestCommandsDestination_andSaysWhy() async throws {
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 0"] = (.failed, "** TEST FAILED **")
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
        XCTAssertEqual(choices().map(\.sentence), [
            "👷 Testing one mutant at a time on the test command's destination: worker 0's run with no mutant on, on "
                + "its simulator, didn't pass (its log is no-mutant run worker 0.log).",
        ])
        assertTestedOnTheDestination()
        XCTAssertFalse(
            ioDelegate.configurations.contains {
                $0.testWithoutBuildArguments(with: "muter.xctestrun").contains("-parallel-testing-enabled")
            }
        )
    }

    func test_oneWorker_simulatorsThatCanNotBeMade_fallBack_andSayWhy() async throws {
        let reason = "`xcrun simctl clone 693E96A4 swiftmutator-0123abcd-1-2-w0` failed with exit code 149"
        workerSimulators.preparing(.failure(WorkerSimulatorsUnavailable(reason: reason)))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            workerSimulators.calls,
            ["sweep /project_mutated", "prepare 1 like \(destination) for /project_mutated"]
        )
        XCTAssertEqual(
            choices().map(\.sentence),
            ["👷 Testing one mutant at a time on the test command's destination: \(reason)."]
        )
        XCTAssertEqual(checkRuns, [])
        assertTestedOnTheDestination()
    }

    func test_oneWorker_simulatorsThatDoNotBoot_areDeleted_andFallBack() async throws {
        let reason = "`xcrun simctl bootstatus SIM-0 -b` didn't finish within 300 seconds"
        workerSimulators.booting(throwing: WorkerSimulatorsUnavailable(reason: reason))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
        XCTAssertEqual(
            choices().map(\.sentence),
            ["👷 Testing one mutant at a time on the test command's destination: \(reason)."]
        )
        XCTAssertEqual(checkRuns, [])
        assertTestedOnTheDestination()
    }

    // As a device's bare `id=` does: the run tests on it as it would have without a word, unless the key asked.
    func test_oneWorker_aDestinationThatResolvesToNoSimulator_isQuiet() async throws {
        let reason = "no available simulator matches `-destination \(destination)`, or more than one does"
        workerSimulators.preparing(.failure(WorkerSimulatorsUnavailable(reason: reason, destinationUnresolved: true)))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(choices().compactMap(\.sentence), [])
        XCTAssertEqual(checkRuns, [])
        assertTestedOnTheDestination()
    }

    func test_oneWorker_aDestinationThatResolvesToNoSimulator_isSaid_whenOneWorkerSimulatorIsTrue() async throws {
        configure(oneWorkerSimulator: true)
        let reason = "no available simulator matches `-destination \(destination)`, or more than one does"
        workerSimulators.preparing(.failure(WorkerSimulatorsUnavailable(reason: reason, destinationUnresolved: true)))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            choices().map(\.sentence),
            ["👷 Testing one mutant at a time on the test command's destination: \(reason)."]
        )
        assertTestedOnTheDestination()
    }

    func test_oneWorker_aMacDestination_makesNoSimulator_andSaysNothing() async throws {
        let choices = sentChoices()
        let destinations = ["platform=macOS", "platform=macOS,variant=Mac Catalyst", "generic/platform=iOS Simulator"]
        for workerDestination in destinations {
            configure(destination: workerDestination)
            ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 6)

            _ = try await sut.run(with: state)
        }

        XCTAssertEqual(workerSimulators.calls, Array(repeating: "sweep /project_mutated", count: 3))
        XCTAssertEqual(choices().count, 3)
        XCTAssertEqual(choices().compactMap(\.sentence), [])
    }

    func test_oneWorker_aMacDestination_saysWhy_whenOneWorkerSimulatorIsTrue() async throws {
        configure(oneWorkerSimulator: true, destination: "platform=macOS")
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices().map(\.sentence), [
            "👷 Testing one mutant at a time on the test command's destination: a simulator of its own needs a first "
                + "`-destination` that is a simulator.",
        ])
    }

    /// Worker 0's part of the configuration, on the spy's simulator `SIM-0`.
    var worker0: MuterConfiguration.XcodeWorker {
        MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/project_mutated.DerivedData.noindex",
            testDiagnosticsOff: true,
            destination: "platform=iOS Simulator,id=SIM-0",
            parallelTestingOff: true
        )
    }

    /// An xcodebuild test command with `-destination destination` and `arguments`, without the key, and no workers
    /// asked for.
    func configure(destination: String? = nil, arguments: [String] = []) {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: testCommandArguments(destination: destination, arguments: arguments)
        )
    }

    /// An xcodebuild test command with `-destination destination`, `arguments` and the key, and no workers asked for.
    func configure(oneWorkerSimulator: Bool, destination: String? = nil, arguments: [String] = []) {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: testCommandArguments(destination: destination, arguments: arguments),
            oneWorkerSimulator: oneWorkerSimulator
        )
    }

    /// The arguments of an xcodebuild test command with `-destination destination`, this suite's unless given, and
    /// `arguments`.
    private func testCommandArguments(destination: String?, arguments: [String]) -> [String] {
        ["-scheme", "App", "-destination", destination ?? self.destination] + arguments + ["test"]
    }

    /// Asserts that every mutant was tested from `muter.xctestrun`, on the test command's destination, with parallel
    /// testing as the scheme has it, and none on the simulator that was deleted.
    func assertTestedOnTheDestination(file: StaticString = #filePath, line: UInt = #line) {
        let firstWorker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/project_mutated.DerivedData.noindex",
            testDiagnosticsOff: true
        )
        XCTAssertEqual(
            ioDelegate.configurations.map(\.xcodeWorker),
            Array(repeating: firstWorker, count: 6),
            file: file,
            line: line
        )
        let destinations = ioDelegate.configurations.map { configuration in
            configuration.testWithoutBuildArguments(with: "muter.xctestrun").dropFirst(2).first
        }
        XCTAssertEqual(Set(destinations), [destination], file: file, line: line)
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [1], file: file, line: line)
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

    func makeSchemataMapping(line: Int) throws -> SchemataMutationMapping {
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
