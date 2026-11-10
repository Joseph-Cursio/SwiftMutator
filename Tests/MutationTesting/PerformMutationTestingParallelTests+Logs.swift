@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingParallelTests {
    // Never in the mutated project or a clone, where a test that lists the package's files, or asks git for untracked
    // ones, would see it.
    func test_everyTestRunWritesItsOutputInTheLogFoldersRunningFolder() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.testLogs.count, 5, "\(ioDelegate.testLogs)")
        XCTAssertEqual(
            ioDelegate.testLogs.prefix(3),
            ["/logs/running/baseline run", "/logs/running/baseline run worker 1", "/logs/running/timed test run"]
        )
        XCTAssertEqual(ioDelegate.testLogs.filter { !$0.hasPrefix("/logs/running/") }, [])
    }

    // Each run's file is moved to the name its log is kept under. A failed worker baseline's is what says why the run
    // stopped.
    func test_eachWorkerBaselinesLog_isKeptInTheLogFolder_aFailedOneToo() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.passed, .buildError]

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(
                reason: .workerBaselineTestFailed(worker: 1, directory: workerClone.path, log: "testLog")
            )
        )

        XCTAssertEqual(
            fileManager.paths.filter { $0.hasSuffix(".log") },
            ["/logs/baseline run.log", "/logs/baseline run worker 1.log"]
        )
        XCTAssertEqual(fileManager.contents, Data("testLog".utf8), "the worker baseline's log, kept last")
        XCTAssertEqual(
            ioDelegate.keptOutputs.map(\.output),
            ["/logs/running/baseline run", "/logs/running/baseline run worker 1"]
        )
        XCTAssertEqual(
            ioDelegate.keptOutputs.map(\.path),
            ["/logs/baseline run.log", "/logs/baseline run worker 1.log"]
        )
    }

    // Each recorded run's output is moved to the name its log is kept under, so a finished run's log folder keeps only
    // its own logs.
    func test_theRunningFolder_isRemovedOnceEmpty() async throws {
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.contentsOfDirectoryAtPath, ["/logs/running"])
        XCTAssertEqual(
            fileManager.paths.filter { !$0.hasSuffix(".log") },
            ["/project_mutated.Activation.noindex", "/logs/running"]
        )
    }

    // A stop leaves the output of the runs under way, all there is to say what they were doing.
    func test_theRunningFolder_isKeptWithWhatAStopLeftInIt() async throws {
        state.loggingDirectory = "/logs"
        fileManager.contentsOfDirectoryToReturn = ["Sample.swift_RelationalOperatorReplacement_0_1_0.log"]
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.paths.filter { !$0.hasSuffix(".log") }, ["/project_mutated.Activation.noindex"])
    }
}
