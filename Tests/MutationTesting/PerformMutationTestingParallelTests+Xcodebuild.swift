@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

extension PerformMutationTestingParallelTests {
    // An xcodebuild project on a simulator gets one per worker, not a copy: every worker tests in the mutated project.
    func test_anXcodebuildProjectOnASimulator_getsASimulatorPerWorker_andNoCopies() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "test"],
            mutationTestWorkers: 4
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(ioDelegate.builtWorkerDirectories, [])
        XCTAssertEqual(workerSimulators.calls.prefix(3), [
            "sweep /project_mutated",
            "prepare 2 like platform=iOS Simulator,name=iPhone 17 for /project_mutated",
            "boot SIM-0 SIM-1",
        ])
        XCTAssertEqual(
            ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") },
            Array(repeating: "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:workingDirectory:)", count: 2)
        )
        XCTAssertEqual(Set(ioDelegate.workingDirectories), [state.mutatedProjectDirectoryURL])
        XCTAssertEqual(
            Set(ioDelegate.configurations.compactMap(\.xcodeWorker?.destination)),
            ["platform=iOS Simulator,id=SIM-0", "platform=iOS Simulator,id=SIM-1"]
        )
    }

    // A Mac app's test runs share its defaults, so a macOS destination tests one mutant at a time, and says why.
    func test_anXcodebuildProjectOnAMac_testsOneMutantAtATime() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=macOS", "test"],
            mutationTestWorkers: 4
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        var choices: [WorkerChoice] = []
        whenSent(.workersChosen) { event in
            if case let .workersChosen(choice) = event { choices.append(choice) }
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(
            ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") },
            Array(repeating: "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)", count: 2)
        )
        // The timed test run's, then each mutant's.
        XCTAssertEqual(ioDelegate.testRunFileNames, ["muter.xctestrun", "muter.xctestrun", "muter.xctestrun"])
        XCTAssertEqual(choices.map(\.used), [1])
        XCTAssertEqual(
            choices.first?.sentence,
            "👷 Testing one mutant at a time, though 4 workers were asked for: a Mac app's test runs share its "
                + "UserDefaults, saved state and container, so workers would see each other's."
        )
    }

    // An xcodebuild project's workers all run in the mutated project, each from an `.xctestrun` of its own, which it
    // switches each of its mutants on in just before the mutant's run. While one worker's first run is under way, the
    // other switches on its next mutants in its own file, never the one that run tests from.
    func test_aPoolOfXcodebuildWorkers_testsEachMutantFromItsOwnWorkersTestRun() async throws {
        let workers = (0...1).map(xcodebuildWorker)
        let jobs = try xcodebuildJobs(4)
        ioDelegate.testSuiteOutcomes = Array(repeating: .failed, count: 4)
        // The first run waits until the last has started, so the other worker runs the other three meanwhile. The
        // wait is bounded, so the test can't hang.
        let lastRunStarted = DispatchSemaphore(value: 0)
        ioDelegate.whileRunningMutant = { number in
            if number == 0 { _ = lastRunStarted.wait(timeout: .now() + 5) }
            if number == 3 { lastRunStarted.signal() }
        }
        var finished: [FinishedRun] = []

        try await sut.runPool(
            jobs.indices.map(PerformMutationTesting.PoolTask.mutant),
            of: jobs,
            on: workers,
            switchingOnFrom: XCTestRun(),
            outputNamed: { index, _ in "\(index).log" },
            recording: { finished.append($0) }
        )

        XCTAssertEqual(finished.map(\.index).sorted(), [0, 1, 2, 3])
        let runs = (0...1).map { worker in finished.filter { $0.worker == worker }.count }
        XCTAssertEqual(runs.sorted(), [1, 3], "one worker ran three while the other's first run was under way")
        XCTAssertEqual(ioDelegate.mutantsNotSwitchedOnForTheirRun, [])
        XCTAssertEqual(ioDelegate.schematas.map(\.id).sorted(), jobs.map(\.schema.id).sorted())
        let fileNames = ioDelegate.testRunFileNames
        XCTAssertEqual(
            (0...1).map(MutationTestingDelegate.testRunFileName(ofWorker:))
                .map { name in fileNames.filter { $0 == name }.count },
            runs
        )
        let destinations = ioDelegate.configurations.compactMap(\.xcodeWorker?.destination)
        XCTAssertEqual(
            (0...1).map { worker in destinations.filter { $0 == "platform=iOS Simulator,id=SIM-\(worker)" } }
                .map(\.count),
            runs
        )
        XCTAssertEqual(Set(ioDelegate.testRunPaths), [state.mutatedProjectDirectoryURL])
        XCTAssertEqual(Set(ioDelegate.workingDirectories), [state.mutatedProjectDirectoryURL])
    }

    // As in the serial loop: a test run that couldn't be written would still switch on the mutant before.
    func test_aPoolOfXcodebuildWorkers_stopsBeforeTheRunOfAMutantThatCanNotBeSwitchedOn() async throws {
        let jobs = try xcodebuildJobs(2)
        ioDelegate.testSuiteOutcomes = [.failed, .failed]
        let error = CocoaError(.fileWriteOutOfSpace)
        ioDelegate.switchOnError = error
        var finished: [FinishedRun] = []

        await assertThrowsMuterError(
            try await sut.runPool(
                [.mutant(0), .mutant(1)],
                of: jobs,
                on: [xcodebuildWorker(0)],
                switchingOnFrom: XCTestRun(),
                outputNamed: { index, _ in "\(index).log" },
                recording: { finished.append($0) }
            ),
            .mutationTestingAborted(
                reason: .mutantNotSwitchedOn(id: jobs[0].schema.id, description: error.localizedDescription)
            )
        )

        XCTAssertEqual(ioDelegate.methodCalls, ["switchOn(schemata:for:at:named:)"])
        XCTAssertEqual(finished.count, 0)
    }

    // A run the simulator failed to launch runs again on its worker, from the same `.xctestrun`, with the mutant still
    // switched on, before that worker takes another job. Only the second run is handed on, with the first's failure.
    func test_aPoolOfXcodebuildWorkers_runsAgainOnItsWorker_aRunTheSimulatorFailedToLaunch() async throws {
        let workers = (0...1).map(xcodebuildWorker)
        let jobs = try xcodebuildJobs(3)
        ioDelegate.testSuiteOutcomes = Array(repeating: .failed, count: 4)
        ioDelegate.mutantTestLogs = [loadFixture("SimulatorTrouble/launch_preflightBusy.log")]
        var finished: [FinishedRun] = []

        try await sut.runPool(
            jobs.indices.map(PerformMutationTesting.PoolTask.mutant),
            of: jobs,
            on: workers,
            switchingOnFrom: XCTestRun(),
            outputNamed: { index, _ in "\(index).log" },
            recording: { finished.append($0) }
        )

        XCTAssertEqual(finished.map(\.index).sorted(), [0, 1, 2])
        let repeated = finished.filter { $0.launchFailure != nil }
        XCTAssertEqual(repeated.count, 1)
        let run = try XCTUnwrap(repeated.first)
        XCTAssertEqual(run.launchFailure?.line, "Simulator device failed to launch com.example.MacCloud-client-iOS.")
        XCTAssertEqual(run.run.testLog, "testLog")
        let runsOfItsJob = zip(ioDelegate.testLogs, ioDelegate.configurations).filter { $0.0 == "\(run.index).log" }
        XCTAssertEqual(
            runsOfItsJob.map(\.1.xcodeWorker),
            Array(repeating: workers[run.worker].configuration.xcodeWorker, count: 2)
        )
        XCTAssertEqual(ioDelegate.testLogs.count, 4)
        XCTAssertEqual(ioDelegate.schematas.count, 3, "each mutant switched on once")
        XCTAssertEqual(ioDelegate.mutantsNotSwitchedOnForTheirRun, [])
    }
}
