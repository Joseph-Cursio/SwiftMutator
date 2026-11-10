@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

/// Kills only suspect tests failed for, tested again alone: a kill a test really makes fails again, and a flaky one
/// mostly doesn't.
final class PerformMutationTestingSuspectRerunTests: MuterTestCase {
    typealias Rerun = MutantResult.Rerun
    typealias TestAlone = MutantResult.TestAlone

    private let state = MutationTestState()
    let timing = "✘ Test timing() recorded an issue at TimingTests.swift:9:5: Expectation failed: 1.2 < 1"
    let sum = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4"
    let allPassed = "✔ Test run with 2 tests in 0 suites passed after 0.001 seconds."

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { _, _ in [] },
        removeWorkerDirectories: { _ in }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        state.muterConfiguration = configuration()
        state.mutationMapping = try (1 ... 3).map { try makeSchemataMapping(file: "Sources/File\($0).swift", line: 1) }
            .mergeByFilePath()
        // timing() fails for all 3 mutants, each in a file of its own, so it is suspect at these thresholds.
        ioDelegate.mutantTestLogs = [timing, timing, timing]
    }

    private func configuration(reruns: Int? = nil) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            mutationTestWorkers: 1,
            suspectTestFilePercent: 50,
            suspectTestMinimumFiles: 2,
            suspectKillReruns: reruns
        )
    }

    private func recordEvents(named names: [RunEvent.Name]) -> () -> [RunEvent] {
        var sent: [RunEvent] = []
        for name in names {
            let observer = runEvents.observe(name) { sent.append($0) }
            addTeardownBlock { observer.cancel() }
        }
        return { sent }
    }

    private func makeSchemataMapping(file: String, line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/project_mutated/\(file)",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line * 10, line: line, column: 5),
                        snapshot: .make(before: ">", after: "<", description: "changed > to <")
                    ),
                ]
            ),
            filePath: "/project_mutated/\(file)"
        )
    }

    private func outcome(of changes: [MutationTestState.Change]) -> MutationTestOutcome? {
        guard case let .mutationTestOutcomeGenerated(outcome)? = changes.first else { return nil }
        return outcome
    }

    // MARK: Whole runs

    func test_aKillThatFailsAgain_stands_andARerunThatPasses_becomesASurvivor() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed, .failed, .failed, .passed]
        ioDelegate.mutantTestLogs += [timing + "\n" + sum, timing, allPassed]
        let sent = recordEvents(named: [.suspectKillRerunsStarted, .suspectKillRerunsFinished])

        let changes = try await sut.run(with: state)

        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.count, 6)
        let reruns = records.compactMap(\.rerun)
        XCTAssertEqual(reruns.map(\.because), Array(repeating: Rerun.onlySuspectTestsFailed, count: 3))
        XCTAssertEqual(reruns.map(\.workers), [1, 1, 1])
        let timingAgain = TestAlone(name: "timing()", file: "TimingTests.swift", result: TestAlone.failedAgain)
        let timingPassedAlone = TestAlone(name: "timing()", file: "TimingTests.swift", result: TestAlone.passed)
        XCTAssertEqual(reruns.compactMap(\.alone), [[timingAgain], [timingAgain], [timingPassedAlone]])
        XCTAssertEqual(records.suffix(3).map(\.outcome), [.failed, .failed, .passed])
        XCTAssertEqual(records.suffix(3).first?.killedBy?.map(\.name), ["timing()", "sum()"])

        let outcome = try XCTUnwrap(outcome(of: changes))
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .failed, .passed])
        XCTAssertEqual(sent().first?.object as? SuspectKillReruns, SuspectKillReruns(count: 3, leftOut: 0))
        let tally = try XCTUnwrap(sent().last?.object as? SuspectKillRerunTally)
        XCTAssertEqual(tally.killed, 2)
        XCTAssertEqual(tally.survived, 1)

        let summary = try XCTUnwrap(
            KillingTestSummary(of: outcome.mutations, thresholds: outcome.suspectTestThresholds)
        )
        XCTAssertEqual(summary.killsTestedAlone, 3)
        XCTAssertEqual(summary.killsThatSurvivedAlone, 1)
        // Measured on first runs: 3 mutants in 3 files, though one is a survivor now.
        let test = try XCTUnwrap(summary.tests.first { $0.name == "timing()" })
        XCTAssertEqual(test.files, 3)
        XCTAssertEqual(test.failedAgainAlone, 2)
        XCTAssertEqual(test.notReproducedAlone, 1)
        XCTAssertTrue(test.isFlaky)
    }

    func test_eachRun_goesToItsEnd_inTheSameEnvironment_afterOneWithNoMutantOn() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed, .failed, .failed, .failed]
        ioDelegate.mutantTestLogs += [timing, timing, timing]

        _ = try await sut.run(with: state)

        let configurations = ioDelegate.configurations
        XCTAssertEqual(configurations.count, 6)
        XCTAssertEqual(configurations.prefix(3).map(\.runsGoToTheirEnd), [false, false, false])
        XCTAssertEqual(configurations.suffix(3).map(\.runsGoToTheirEnd), [true, true, true])
        // Still as stopAtFirstFailure said, so the environment doesn't change, which recompiles the package's manifest.
        XCTAssertEqual(configurations.suffix(3).map(\.stopsAtFirstFailure), [true, true, true])
        XCTAssertEqual(ioDelegate.controlRunConfigurations.map(\.runsGoToTheirEnd), [true])
    }

    func test_aTimeoutOrBuildError_replacesNothing_andKeepsItsLog() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed, .timeout, .buildError, .failed]
        ioDelegate.mutantTestLogs += [timing, "error: it broke", timing]
        let sent = recordEvents(named: [.suspectKillRerunsFinished])

        let changes = try await sut.run(with: state)

        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records.compactMap(\.rerun).count, 1)
        XCTAssertEqual(
            try XCTUnwrap(outcome(of: changes)).mutations.map(\.testSuiteOutcome), [.failed, .failed, .failed]
        )
        XCTAssertEqual((sent().first?.object as? SuspectKillRerunTally)?.unsettled, 2)
        XCTAssertEqual(ioDelegate.keptOutputs.filter { $0.path?.contains(" (alone).log") == true }.count, 2)
    }

    func test_whenTheTestsDontPassAloneWithNoMutantOn_noKillIsTestedAgain_andThatIsSaid() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed]
        ioDelegate.controlRuns = [(.failed, timing)]
        let sent = recordEvents(named: [.suspectKillRerunsSkipped, .suspectKillRerunsStarted])

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(MutantResult.self).compactMap(\.rerun), [])
        XCTAssertEqual(sent().map(\.name), [RunEvent.Name.suspectKillRerunsSkipped])
    }

    func test_aLimitOfNone_testsNoKillAgain() async throws {
        state.muterConfiguration = configuration(reruns: 0)
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 3)
        XCTAssertEqual(ioDelegate.controlRunConfigurations, [])
    }

    func test_withNoSuspectTest_nothingRunsAgain() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed]
        ioDelegate.mutantTestLogs = [timing, sum, "✘ Test other() recorded an issue at O.swift:1:1: Expectation failed"]

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 3)
        XCTAssertEqual(ioDelegate.controlRunConfigurations, [])
    }

    func test_aFlipInASessionThatCantShowItsCodeRan_isASurvivor_notUncovered() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed, .failed, .failed, .passed]
        ioDelegate.mutantTestLogs += [timing, timing, allPassed]
        ioDelegate.mutantActivations = Array(repeating: nil, count: 6)

        let changes = try await sut.run(with: state)

        XCTAssertEqual(
            try XCTUnwrap(outcome(of: changes)).mutations.map(\.testSuiteOutcome), [.failed, .failed, .passed]
        )
        XCTAssertNil(try resultsFiles.records(MutantResult.self).last?.activated)
    }

    func test_aFirstRunShownToRunItsCode_staysShown_whenARerunThatPassesDoesntShowIt() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed, .failed, .failed, .passed]
        ioDelegate.mutantTestLogs += [timing, timing, allPassed]
        ioDelegate.mutantActivations = [true, true, true, true, true, nil]

        let changes = try await sut.run(with: state)

        XCTAssertEqual(try XCTUnwrap(outcome(of: changes)).mutations.last?.testSuiteOutcome, .passed)
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).last?.activated, true)
    }
}
