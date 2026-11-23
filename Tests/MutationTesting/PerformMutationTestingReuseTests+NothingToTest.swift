@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingReuseTests {
    // With every result kept and nothing changed, there is nothing to test, and no baseline to run.
    func test_withNothingToTest_andNothingChanged_runsNoBaseline() async throws {
        try reuse(heldEverywhere())

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.testLogs, [])
        XCTAssertEqual(try resultsFiles.kinds(), ["header", "mutant", "mutant", "mutant", "mutant", "end"])
    }

    // After any change, even one let through, the baseline still runs: a changed test that now fails would otherwise
    // keep every kill. Nothing else does, as nothing is left to test.
    func test_withNothingToTest_afterAChange_runsTheBaselineOnly() async throws {
        try reuse(heldEverywhere(), changes: [.init(path: "README.md", kind: .added)], waiving: ["README.md"])
        state.resumeWaived = ["README.md"]
        ioDelegate.testSuiteOutcomes = [.passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.testLogs, [running("baseline run")])
        XCTAssertEqual(try resultsFiles.kinds(), ["header", "mutant", "mutant", "mutant", "mutant", "end"])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).first?.mutantsToTest, 0)
        XCTAssertTrue(fileManager.paths.contains("/project_muter_logs/now/baseline run.log"), "its log is kept")
    }

    // An xcodebuild session with nothing left to test has no workers, so its header doesn't say where they tested.
    func test_withNothingToTest_anXcodebuildSessionsHeader_doesntSayWhereTheWorkersTested() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", "platform=iOS Simulator,name=iPhone 17 Pro", "test"]
        )
        for changes in [[], [ProjectTree.FileChange(path: "README.md", kind: .added)]] {
            try reuse(heldEverywhere(), changes: changes, waiving: ["README.md"])
            state.resumeWaived = ["README.md"]
            ioDelegate.testSuiteOutcomes = [.passed]

            _ = try await sut.run(with: state)
        }

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.mutantsToTest), [0, 0])
        XCTAssertEqual(
            try resultsFiles.records(ResultsHeader.self).map(\.workersOnOwnSimulators),
            [.notRecorded, .notRecorded]
        )
    }

    // With nothing left to test, the header says whether the runs stop at their first failed test as a session that
    // tests says it: on a Mac, those of tests that run in Xcode's `xctest` agent do; those of a Mac app's hosted tests
    // go to their end.
    func test_withNothingToTest_aMacSessionsHeader_saysWhetherItsRunsStop() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", "platform=macOS", "test"]
        )
        let hosted = muterCore.XCTestRun.withTestTargets([
            "AppTests": ["TestHostPath": muterCore.XCTestRun.macAppPath, "IsAppHostedTestBundle": true],
        ])
        for xctestRun in [muterCore.XCTestRun.unhostedFixture, hosted] {
            try reuse(heldEverywhere())
            state.projectXCTestRun = xctestRun

            _ = try await sut.run(with: state)
        }

        XCTAssertEqual(ioDelegate.testLogs, [], "no baseline: nothing changed")
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.mutantsToTest), [0, 0])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.stopsAtFirstFailure), [true, false])
    }

    // Without a log folder, as a state that bypasses the handler has, the baseline's output is discarded, and no log is
    // written in the current directory, the mutated project.
    func test_withNothingToTest_afterAChange_withNoLogFolder_keepsNoBaselineLog() async throws {
        try reuse(heldEverywhere(), changes: [.init(path: "README.md", kind: .added)], waiving: ["README.md"])
        state.resumeWaived = ["README.md"]
        state.loggingDirectory = ""
        ioDelegate.testSuiteOutcomes = [.passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.keptOutputs.map(\.output), ["baseline run"])
        XCTAssertEqual(ioDelegate.keptOutputs.map(\.path), [nil])
        XCTAssertFalse(fileManager.paths.contains { $0.hasSuffix("baseline run.log") }, "\(fileManager.paths)")
    }

    // ...and a failing baseline then stops the run, as any run's does.
    func test_withNothingToTest_afterAChange_aFailingBaselineStopsTheRun() async throws {
        try reuse(heldEverywhere(), changes: [.init(path: "README.md", kind: .added)], waiving: ["README.md"])
        ioDelegate.testSuiteOutcomes = [.failed]

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        XCTAssertEqual(resultsFiles.lines, [])
    }
}
