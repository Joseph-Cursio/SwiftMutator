@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

/// Kills only suspect tests failed for, tested again alone: a kill a test really makes fails again, and a flaky one
/// mostly doesn't.
final class PerformMutationTestingSuspectRerunTests: MuterTestCase {
    private typealias Rerun = MutantResult.Rerun
    private typealias TestAlone = MutantResult.Rerun.TestAlone
    private let state = MutationTestState()
    private let timing = "✘ Test timing() recorded an issue at TimingTests.swift:9:5: Expectation failed: 1.2 < 1"
    private let sum = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4"
    private let allPassed = "✔ Test run with 2 tests in 0 suites passed after 0.001 seconds."

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
            filePath: "/project_mutated/\(file)",
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
            )
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

    // MARK: Which kills

    private func kill(naming names: [String], at index: Int = 0) -> MutationTestOutcome.Mutation {
        .make(
            testSuiteOutcome: .failed,
            point: .make(filePath: "/project/Sources/F\(index).swift"),
            killingTests: .init(
                tests: names.map { .init(name: $0, location: nil) }, count: names.count, isComplete: true
            )
        )
    }

    private func identity(_ name: String) -> FailedTestLine.TestIdentity {
        .init(name: name, file: nil)
    }

    private func candidates(
        _ outcomes: [Int: MutationTestOutcome.Mutation],
        suspects: [String],
        limit: Int = 100,
        notInTheBuild: Set<Int> = []
    ) -> (indices: [Int], leftOut: Int) {
        PerformMutationTesting.suspectKillCandidates(
            in: outcomes,
            notInTheBuild: notInTheBuild,
            suspects: Set(suspects.map(identity)),
            limit: limit
        )
    }

    func test_candidates_areEveryKillOnlySuspectsFailedFor_upToTheLimit() {
        let outcomes = Dictionary(uniqueKeysWithValues: (0 ..< 10).map { ($0, kill(naming: ["a"], at: $0)) })

        XCTAssertEqual(candidates(outcomes, suspects: ["a"]).indices, Array(0 ..< 10))
        let limited = candidates(outcomes, suspects: ["a"], limit: 5)
        XCTAssertEqual(limited.indices.count, 5)
        XCTAssertEqual(limited.leftOut, 5)
        XCTAssertEqual(candidates(outcomes, suspects: ["a"], limit: 0).indices, [])
    }

    func test_candidates_giveEverySuspectItsShare_beforeAnyGetsMore() {
        var outcomes = Dictionary(uniqueKeysWithValues: (0 ..< 90).map { ($0, kill(naming: ["a"], at: $0)) })
        for index in 90 ..< 95 {
            outcomes[index] = kill(naming: ["b"], at: index)
        }

        let picked = candidates(outcomes, suspects: ["a", "b"], limit: 6).indices

        XCTAssertEqual(picked.count { $0 < 90 }, 3)
        XCTAssertEqual(picked.count { $0 >= 90 }, 3)
    }

    // A suspect that only ever fails beside another test has no kill of its own to judge it by.
    func test_candidates_topUpFromOtherKills_aSuspectWithTooFewOfItsOwn() {
        let outcomes = [
            0: kill(naming: ["a"]),
            1: kill(naming: ["a", "good"]),
            2: kill(naming: ["a", "good"]),
            3: kill(naming: ["a", "good"]),
            4: kill(naming: ["good"]),
        ]

        XCTAssertEqual(candidates(outcomes, suspects: ["a"]).indices.count, 3)
        XCTAssertTrue(candidates(outcomes, suspects: ["a"]).indices.contains(0))
        XCTAssertFalse(candidates(outcomes, suspects: ["a"]).indices.contains(4))
    }

    func test_candidates_leaveOutWhatCantOrNeedntBeTested() {
        var unproven = kill(naming: ["a"])
        unproven.activated = false
        var tested = kill(naming: ["a"])
        tested.rerun = Rerun(because: Rerun.onlySuspectTestsFailed, workers: 1, alone: [])
        var unprovenThenProven = kill(naming: ["a"])
        unprovenThenProven.rerun = Rerun(because: Rerun.codeNotShownRunning, workers: 1)
        let reused = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .failed,
            killingTests: .init(tests: [.init(name: "a", location: nil)], count: 1, isComplete: true),
            reusedFrom: .init(resultsFile: "r", session: 1, despiteChanges: false)
        )
        let outcomes = [
            0: kill(naming: ["a"]),
            1: unproven,
            2: tested,
            3: reused,
            4: kill(naming: ["a"]),
            5: kill(naming: []),
            6: unprovenThenProven,
            7: .make(testSuiteOutcome: .runtimeError),
        ]

        XCTAssertEqual(candidates(outcomes, suspects: ["a"], notInTheBuild: [4]).indices, [0, 6])
    }

    func test_candidates_countAKillThatNamesSeveralSuspects_forEachOfThem() {
        var outcomes: [Int: MutationTestOutcome.Mutation] = [:]
        for index in 0 ..< 3 {
            outcomes[index] = kill(naming: ["a", "b", "good"], at: index)
        }
        for index in 3 ..< 6 {
            outcomes[index] = kill(naming: ["b"], at: index)
        }
        for index in 6 ..< 9 {
            outcomes[index] = kill(naming: ["c"], at: index)
        }

        let picked = candidates(outcomes, suspects: ["a", "b", "c"], limit: 6).indices

        XCTAssertEqual(picked.count { $0 >= 6 }, 3, "\(picked)")
    }

    func test_candidates_countWhatEarlierSessionsTested_towardATestsShare() {
        var outcomes = Dictionary(uniqueKeysWithValues: (0 ..< 3).map { ($0, kill(naming: ["a"], at: $0)) })
        for index in 3 ..< 6 {
            outcomes[index] = kill(naming: ["b"], at: index)
        }
        for index in 6 ..< 9 {
            var tested = kill(naming: ["a"], at: index)
            tested.rerun = Rerun(
                because: Rerun.onlySuspectTestsFailed,
                workers: 1,
                alone: [.init(name: "a", file: nil, result: TestAlone.failedAgain)]
            )
            outcomes[index] = tested
        }

        let picked = candidates(outcomes, suspects: ["a", "b"], limit: 6).indices

        XCTAssertEqual(picked.sorted(), [3, 4, 5])
    }

    // A resumed run's earlier sessions used some of the limit, so stopping it tests no more than running it through.
    func test_theLimit_isPerRun_soItCountsThoseEarlierSessionsTested() {
        var outcomes = Dictionary(uniqueKeysWithValues: (0 ..< 5).map { ($0, kill(naming: ["a"], at: $0)) })
        for index in 5 ..< 8 {
            var tested = kill(naming: ["a"], at: index)
            tested.rerun = Rerun(because: Rerun.onlySuspectTestsFailed, workers: 1, alone: [])
            outcomes[index] = tested
        }

        let (indices, leftOut) = candidates(outcomes, suspects: ["a"], limit: 5)

        XCTAssertEqual(indices.count, 2)
        XCTAssertEqual(leftOut, 3)
    }

    func test_evenlySpaced_spreadsOverAll() {
        XCTAssertEqual(PerformMutationTesting.evenlySpaced(Array(0 ..< 10), count: 2), [0, 5])
        XCTAssertEqual(PerformMutationTesting.evenlySpaced(Array(0 ..< 3), count: 5), [0, 1, 2])
        XCTAssertEqual(PerformMutationTesting.evenlySpaced(Array(0 ..< 3), count: 0), [])
    }

    // MARK: What a run says of a test

    private func alone(
        _ outcome: TestSuiteOutcome,
        _ log: String,
        ending: TestRun.Ending = .exited,
        activated: Bool? = true,
        sessionShowsActivation: Bool = false
    ) -> String? {
        PerformMutationTesting.testsAlone(
            [.init(name: "timing()", location: "TimingTests.swift:9:5")],
            in: TestRun(outcome: outcome, testLog: log, ending: ending, activated: activated),
            sessionShowsActivation: sessionShowsActivation
        ).first?.result
    }

    func test_aTestThatFailsAgain_failedAgain() {
        XCTAssertEqual(alone(.failed, timing), TestAlone.failedAgain)
        XCTAssertEqual(alone(.failed, timing, activated: nil), TestAlone.failedAgain)
    }

    func test_aTestThatFails_withItsMutantsCodeNotRunning_doesntFailForTheMutant() {
        XCTAssertEqual(alone(.failed, timing, activated: false), TestAlone.failedWithItsCodeNotRunning)
        // Once a session's runs show they can say, one that says nothing didn't reach mutated code.
        XCTAssertEqual(
            alone(.failed, timing, activated: nil, sessionShowsActivation: true), TestAlone.failedWithItsCodeNotRunning
        )
    }

    // `swift test --quiet` prints no line for a test that passes, so a run that reached its end says it by leaving it
    // out.
    func test_aTestARunThatRanEveryTestDoesntShowFailing_passed() {
        XCTAssertEqual(alone(.failed, sum), TestAlone.passed)
        XCTAssertEqual(alone(.passed, allPassed), TestAlone.passed)
    }

    // A run a crash or its time limit ended may never have run this one, however complete its list looks.
    func test_aRunThatMayNotHaveRunTheTest_saysNothingOfIt() {
        XCTAssertNil(alone(.runtimeError, "signal 11"))
        XCTAssertNil(alone(.failed, sum + "\nerror: Exited with unexpected signal code 11"))
        XCTAssertNil(alone(.failed, sum, ending: .timedOut))
        XCTAssertNil(alone(.passed, allPassed, ending: .timedOut))
        // A failed run that names nothing failing may be one whose lines this can't read.
        XCTAssertNil(alone(.failed, ""))
    }

    func test_aFailureByAnotherTestOfTheSameName_saysNothing() {
        let other = "✘ Test timing() recorded an issue at OtherTests.swift:2:5: Expectation failed: 1 == 2"
        XCTAssertNil(alone(.failed, other))
    }

    func test_aFailureOnlyALookalikeShows_saysNothing() {
        let run = TestRun(outcome: .failed, testLog: sum, ending: .exited, activated: true)
        let lookalike = FailedTestLine.TestIdentity(name: "sum()", file: "SumTests.swift")

        let results = PerformMutationTesting.testsAlone(
            [.init(name: "timing()", location: "TimingTests.swift:9:5")], in: run, ignoring: [lookalike]
        )

        XCTAssertNil(results.first?.result)
    }
}
