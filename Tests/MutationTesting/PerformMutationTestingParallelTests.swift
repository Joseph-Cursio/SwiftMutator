@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

/// The default test timeout and parallel workers.
final class PerformMutationTestingParallelTests: MuterTestCase {
    let state = MutationTestState()
    let workerClone = URL(fileURLWithPath: "/project_mutated_worker1")
    var clonedCounts: [Int] = []
    var removedClones: [[URL]] = []

    lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [weak self] _, count in
            guard let self else { return [] }
            clonedCounts.append(count)
            return Array(repeating: workerClone, count: count)
        },
        removeWorkerDirectories: { [weak self] in self?.removedClones.append($0) }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.mutationMapping = try [makeSchemataMapping(line: 1), makeSchemataMapping(line: 2)]
    }

    func test_withoutATimeout_mutantsGetTheMinimumDefault() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        // The spy's baseline returns at once, so the minimum applies.
        XCTAssertEqual(
            ioDelegate.configurations.map(\.testSuiteTimeout),
            [PerformMutationTesting.minimumDefaultTimeout, PerformMutationTesting.minimumDefaultTimeout]
        )
    }

    func test_aConfiguredTimeoutIsKept() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 42
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), [42, 42])
        XCTAssertFalse(ioDelegate.methodCalls.contains(timedRun))
    }

    // A SwiftPM mutant's run skips the build, so its default limit comes from one timed run of that command, with no
    // mutant on: five times it at one worker.
    func test_aSwiftPMRunWithoutATimeout_basesTheDefaultOnATimedTestRun() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        timeTheTestRun(seconds: 12)

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls.filter { $0 == timedRun }.count, 1)
        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), [60, 60])
    }

    // Each worker's tests compete with the others' for the same cores, so each worker beyond the first adds one more.
    func test_eachWorkerBeyondTheFirst_addsATimedTestRunToTheDefault() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.loggingDirectory = "/logs"
        // The baseline, the worker clone's build, then the two mutants.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        timeTheTestRun(seconds: 12)

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), [72, 72])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.testRunSeconds, 12)
        XCTAssertEqual(header.timeoutSeconds, 72)
    }

    // The workers are never more than the mutants to test, and the default counts only those that test them.
    func test_theDefault_countsOnlyTheWorkersThatTestMutants() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 8
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        timeTheTestRun(seconds: 12)

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), [72, 72])
    }

    // The progress bar's rate is measured from when the mutants start: after the worker clones are built, which can
    // take minutes and isn't time spent on mutants, and before any mutant's run.
    func test_theMutantRunsStart_onceTheClonesAreBuilt() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        var atTheStart: [[Int]] = []
        whenSent(.mutantRunsStarted) { [ioDelegate] _ in
            let mutantRuns = ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count
            atTheStart.append([ioDelegate.builtWorkerDirectories.count, mutantRuns])
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(atTheStart, [[1, 0]])
    }

    func test_aShortTimedTestRun_getsTheMinimum() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        timeTheTestRun(seconds: 1)

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            ioDelegate.configurations.map(\.testSuiteTimeout),
            [PerformMutationTesting.minimumTestRunTimeout, PerformMutationTesting.minimumTestRunTimeout]
        )
    }

    // A timed run that doesn't pass says nothing about how long a passing one takes: it may have crashed at once.
    // The default then comes from the baseline, as for other build systems.
    func test_whenTheTimedTestRunDoesNotPass_theDefaultComesFromTheBaseline() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.timedTestRunOutcome = .runtimeError
        timeTheTestRun(seconds: 12)

        _ = try await sut.run(with: state)

        // 3 times the baseline's 100 s, on the monotonic clock, as `timeTheTestRun` has it.
        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), [300, 300])
        XCTAssertNil(try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first).testRunSeconds)
    }

    // An xcodebuild project's mutants run `test-without-building` from `muter.xctestrun`, so the timed run tests from
    // it too, written first with no mutant switched on, and sets the default as SwiftPM's does.
    func test_anXcodebuildProject_timesATestRunFromItsTestRunWithNoMutantOn() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        timeTheTestRun(seconds: 12)

        _ = try await sut.run(with: state)

        XCTAssertEqual(Array(ioDelegate.methodCalls.prefix(3)), [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            timedRun,
        ])
        XCTAssertEqual(ioDelegate.schematas.first, .null)
        XCTAssertEqual(ioDelegate.testRunFileNames.first, "muter.xctestrun")
        XCTAssertEqual(
            ioDelegate.configurationsWithoutBuilding.map(\.xcodeWorker?.testRunFile),
            ["muter.xctestrun"]
        )
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.testRunSeconds, 12)
        XCTAssertEqual(header.timeoutSeconds, 60)
        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), [60, 60])
    }

    // An `.xctestrun` that can't be written times nothing; the first mutant's switch says why.
    func test_anXcodebuildTestRunThatCanNotBeWritten_isNotTimed() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.switchOnError = CocoaError(.fileWriteNoPermission)

        await assertThrowsMuterError(try await sut.run(with: state)) { error in
            guard case .mutationTestingAborted(reason: .mutantNotSwitchedOn) = error else {
                return XCTFail("\(error)")
            }
        }

        XCTAssertFalse(ioDelegate.methodCalls.contains(timedRun))
    }

    // Another build system's mutants have no test command to time without its build.
    func test_anotherBuildSystem_getsNoTimedTestRun() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/make", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertFalse(ioDelegate.methodCalls.contains(timedRun))
    }

    /// Runs mutation testing in a task of its own, so a test that cancels it mid-run doesn't cancel itself.
    func runInItsOwnTask() async -> Result<[MutationTestState.Change], Error> {
        await sut.runInItsOwnTask(with: state)
    }

    /// Cancels mutation testing whenever it sends `name`, from the task that sends it; returns how often it did.
    func cancelMutationTesting(whenSent name: RunEvent.Name) -> () -> Int {
        var count = 0
        let observer = runEvents.observe(name) { _ in
            count += 1
            withUnsafeCurrentTask { $0?.cancel() }
        }
        addTeardownBlock { observer.cancel() }
        return { count }
    }

    /// Calls `handler` with each event sent with `name`, from the task that sends it, until the test ends.
    func whenSent(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) {
        let observer = runEvents.observe(name, handler)
        addTeardownBlock { observer.cancel() }
    }

    /// The line of each mutant whose outcome is sent, in the order they're sent, until the test ends.
    func linesOfSentOutcomes() -> () -> [Int] {
        var lines: [Int] = []
        let observer = runEvents.observe(.newMutationTestOutcomeAvailable) { event in
            if let mutation = event.object as? MutationTestOutcome.Mutation {
                lines.append(mutation.point.position.line)
            }
        }
        addTeardownBlock { observer.cancel() }
        return { lines }
    }

    let timedRun = "runTestsWithoutBuilding(using:timeLimit:savingResultsIntoFileNamed:)"

    /// Makes the timed test run take `seconds` by the injected clock. Every baseline and mutant run takes time too, so
    /// a limit taken from anything but the timed run alone comes out wrong.
    func timeTheTestRun(seconds: UInt64) {
        let nanoseconds = Locked<UInt64>(1)
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds.value) }
        ioDelegate.whileRunningBaseline = { _ in nanoseconds.change { $0 += 100_000_000_000 } }
        ioDelegate.whileRunningTestsWithoutBuilding = { nanoseconds.change { $0 += seconds * 1_000_000_000 } }
        ioDelegate.whileRunningMutant = { _ in nanoseconds.change { $0 += 7_000_000_000 } }
    }

    /// xcodebuild worker `worker` of the mutated project, on its own simulator.
    func xcodebuildWorker(_ worker: Int) -> PerformMutationTesting.PoolWorker {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "test"],
            testSuiteTimeOut: 42
        )
        .forXcodeWorker(MuterConfiguration.XcodeWorker(
            testRunFile: MutationTestingDelegate.testRunFileName(ofWorker: worker),
            derivedData: MuterConfiguration.XcodeWorker.derivedData(
                ofWorker: worker, in: state.mutatedProjectDirectoryURL
            ),
            destination: "platform=iOS Simulator,id=SIM-\(worker)",
            parallelTestingOff: true,
            testDiagnosticsOff: true
        ))
        return PerformMutationTesting.PoolWorker(
            directory: state.mutatedProjectDirectoryURL,
            configuration: configuration
        )
    }

    /// `count` jobs, a mutant on each line from 1 of one file.
    func xcodebuildJobs(_ count: Int) throws -> [PerformMutationTesting.MutantJob] {
        try (1...count).map { line in
            try PerformMutationTesting.MutantJob(
                fileName: "file.swift",
                schema: .make(filePath: "/project_mutated/file.swift", position: .init(line: line))
            )
        }
    }

    func makeSchemataMapping(line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/some/path",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/tmp/project/file.swift",
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
