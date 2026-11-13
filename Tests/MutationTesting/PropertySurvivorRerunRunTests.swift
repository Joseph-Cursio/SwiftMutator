@testable import muterCore
import TestingExtensions
import XCTest

/// Property survivor reruns: once every mutant is tested, each survivor whose code ran is tested again with only the
/// property tests `propertyTestFilter` selects, up to `propertySurvivorReruns` times, stopping at the first failure
/// (`PropertySurvivorReruns`). They change no result.
final class PropertySurvivorRerunRunTests: MuterTestCase {
    private let state = MutationTestState()
    private let ordered = "✘ Test ordered() recorded an issue at SortProperties.swift:8:5: Expectation failed"
    private let threePassed = "✔ Test run with 3 tests in 1 suite passed after 0.4 seconds."

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { _, count in Array(repeating: URL(fileURLWithPath: "/clone"), count: count) },
        removeWorkerDirectories: { _ in }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        state.muterConfiguration = configuration(runs: 3)
        state.mutationMapping = try (1 ... 4).map { try makeSchemataMapping(file: "Sources/File\($0).swift", line: $0) }
    }

    // Mutants 1, 3 and 4 survive, and 2 a property killed, so it isn't tested again. In rounds: run 1 tests 1, 3 and
    // 4, and a property fails for 3; run 2 tests 1 and 4, and one fails for 1; run 3 tests 4, which passes, as every
    // run did. Each survivor's line is written when its runs end, and every survivor stays one.
    func test_survivors_areTestedAgainInRounds_untilAPropertyFails_orEveryRunPasses() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed, .passed]
            + [.passed, .failed, .passed] + [.failed, .passed] + [.passed]
        ioDelegate.mutantTestLogs = ["✔ passed", ordered, "✔ passed", "✔ passed"]
            + [threePassed, ordered, threePassed] + [ordered, threePassed] + [threePassed]
        ioDelegate.controlRuns = [(.passed, threePassed)]
        let sent = recordEvents(named: [
            .propertySurvivorRerunsStarted, .propertySurvivorRerunsFinished, .propertySurvivorRerunsSkipped,
            .propertyRerunsStarted,
        ])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(
            try resultsFiles.kinds(),
            ["header"] + Array(repeating: "mutant", count: 4) + Array(repeating: "propertySurvivorRerun", count: 3)
                + ["end"]
        )
        let reruns = try resultsFiles.records(PropertySurvivorRerunResult.self)
        XCTAssertEqual(reruns.map(\.line), [3, 1, 4], "in the order their runs ended")
        XCTAssertEqual(reruns.map(\.run), [1, 2, 3])
        XCTAssertEqual(reruns.map(\.runs), [3, 3, 3])
        XCTAssertEqual(reruns.map(\.outcome), [.failed, .failed, .passed])
        XCTAssertEqual(reruns.first?.killedBy, [.init(name: "ordered()", location: "SortProperties.swift:8:5")])
        // A failure its line names keeps no log, nor does a run that passed.
        XCTAssertEqual(reruns.map(\.log), [nil, nil, nil])
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.recorded), [4], "never counted as a mutant")

        // Every run of the property tests filters the test command: the six reruns and the baseline.
        let filtered = ioDelegate.configurations.suffix(6) + ioDelegate.controlRunConfigurations
        XCTAssertEqual(filtered.map(\.testFilterArguments), Array(repeating: ["--filter", "Properties"], count: 7))

        XCTAssertEqual(sent().map(\.name), [.propertySurvivorRerunsStarted, .propertySurvivorRerunsFinished])
        XCTAssertEqual(
            sent().first?.object as? PropertySurvivorReruns,
            PropertySurvivorReruns(count: 3, runs: 3, workers: 1, leftOut: 0)
        )
        let tally = try XCTUnwrap(sent().last?.object as? PropertySurvivorRerunTally)
        XCTAssertEqual([tally.finished, tally.failed, tally.passed, tally.unsettled], [3, 2, 1, 0])

        let outcome = try XCTUnwrap(outcome(of: changes))
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .failed, .passed, .passed])
        XCTAssertEqual(outcome.mutations.map(\.propertySurvivorRerun?.failedOnRun), [2, nil, 1, nil])
        XCTAssertEqual(outcome.mutations.map(\.propertySurvivorRerun?.passedEveryRun), [false, nil, false, true])
        let summary = try XCTUnwrap(PropertySurvivorRerunSummary(of: outcome.mutations))
        XCTAssertEqual(
            [summary.survivorsTestedAgain, summary.failedOnALaterRun, summary.passedEveryRun, summary.unsettled],
            [3, 2, 1, 0]
        )
    }

    // A run that times out settles nothing: the survivor's runs end there, and it isn't tested again.
    func test_aRunThatTimesOut_endsTheSurvivorsRuns_settlingNothing() async throws {
        state.mutationMapping = Array(state.mutationMapping.prefix(1))
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .timeout]
        ioDelegate.mutantTestLogs = ["✔ passed", "still running"]
        ioDelegate.controlRuns = [(.passed, threePassed)]
        let sent = recordEvents(named: [.propertySurvivorRerunsFinished])

        _ = try await sut.run(with: state)

        let reruns = try resultsFiles.records(PropertySurvivorRerunResult.self)
        XCTAssertEqual(reruns.map(\.run), [1])
        XCTAssertEqual(reruns.map(\.outcome), [.timeout])
        let tally = try XCTUnwrap(sent().last?.object as? PropertySurvivorRerunTally)
        XCTAssertEqual([tally.failed, tally.passed, tally.unsettled], [0, 0, 1])
    }

    // Over `propertySurvivorRerunLimit`, the rest are left out, and that is said.
    func test_survivorsOverTheLimit_areLeftOut() async throws {
        state.muterConfiguration = configuration(runs: 1, limit: 1)
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed, .passed, .passed]
        ioDelegate.mutantTestLogs = ["✔ passed", ordered, "✔ passed", "✔ passed", threePassed]
        ioDelegate.controlRuns = [(.passed, threePassed)]
        let sent = recordEvents(named: [.propertySurvivorRerunsStarted])

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(PropertySurvivorRerunResult.self).map(\.line), [1])
        XCTAssertEqual(
            sent().first?.object as? PropertySurvivorReruns,
            PropertySurvivorReruns(count: 1, runs: 1, workers: 1, leftOut: 2)
        )
    }

    // The property tests failing with no mutant on make every rerun mean nothing: none runs, and that is said.
    func test_noSurvivorIsTestedAgain_whenThePropertyTestsFailWithNoMutantOn() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed, .passed]
        ioDelegate.mutantTestLogs = ["✔ passed", ordered, "✔ passed", "✔ passed"]
        ioDelegate.controlRuns = [(.failed, "✘ Test run with 3 tests in 1 suite failed after 0.4 seconds.")]
        let sent = recordEvents(named: [.propertySurvivorRerunsStarted, .propertySurvivorRerunsSkipped])

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(PropertySurvivorRerunResult.self), [])
        XCTAssertEqual(sent().map(\.name), [.propertySurvivorRerunsSkipped])
        let (reason, log) = try XCTUnwrap(sent().first?.object as? (String, String?))
        XCTAssertEqual(reason, "the tests propertyTestFilter selects didn't pass with no mutant on")
        XCTAssertEqual(log, "property tests with no mutant on.log")
    }

    // Without `propertySurvivorReruns`, no survivor is tested again, and with no kill to test again either, the
    // property tests don't run at all.
    func test_noSurvivorIsTestedAgain_withoutTheKey() async throws {
        try await assertNoSurvivorIsTestedAgain(runs: nil)
    }

    func test_noSurvivorIsTestedAgain_withTheKeyAtZero() async throws {
        try await assertNoSurvivorIsTestedAgain(runs: 0)
    }

    // Survivors only: never a kill, one not in the build, one already tested so, or one whose code didn't run. The
    // limit counts those earlier sessions tested, and the rest are spread evenly in job order.
    func test_candidates_areSurvivorsWhoseCodeRan_withinWhatTheLimitLeaves() {
        let session = TestingSession(startedAt: Date())
        var rerun = MutationTestOutcome.Mutation.make(testSuiteOutcome: .passed)
        rerun.propertySurvivorRerun = .init(outcome: .passed, run: 3, runs: 3, killingTests: nil)
        var didNotRun = MutationTestOutcome.Mutation.make(testSuiteOutcome: .passed)
        didNotRun.activated = .didNotRun
        session.outcomes = [
            0: .make(testSuiteOutcome: .passed),
            1: .make(testSuiteOutcome: .failed),
            2: .make(testSuiteOutcome: .passed),
            3: rerun,
            4: didNotRun,
            5: .make(testSuiteOutcome: .passed),
            6: .make(testSuiteOutcome: .passed),
            7: .make(testSuiteOutcome: .timeout),
        ]
        session.notInTheBuild = [2]

        let all = PerformMutationTesting.propertySurvivorCandidates(in: session, limit: 100)
        let two = PerformMutationTesting.propertySurvivorCandidates(in: session, limit: 3)
        let none = PerformMutationTesting.propertySurvivorCandidates(in: session, limit: 1)

        XCTAssertEqual(all.indices, [0, 5, 6])
        XCTAssertEqual(all.leftOut, 0)
        XCTAssertEqual(two.indices, [0, 5], "the earlier rerun takes one of the three")
        XCTAssertEqual(two.leftOut, 1)
        XCTAssertEqual(none.indices, [])
        XCTAssertEqual(none.leftOut, 3)
    }

    // MARK: Helpers

    private func assertNoSurvivorIsTestedAgain(runs: Int?, line: UInt = #line) async throws {
        state.muterConfiguration = configuration(runs: runs)
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed, .passed]
        ioDelegate.mutantTestLogs = ["✔ passed", ordered, "✔ passed", "✔ passed"]

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(PropertySurvivorRerunResult.self), [], line: line)
        XCTAssertEqual(ioDelegate.controlRunConfigurations, [], line: line)
    }

    private func configuration(runs: Int?, limit: Int? = nil) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            mutationTestWorkers: 1,
            controlRunEvery: 0,
            propertyTests: ["*Properties*"],
            propertyTestFilter: ["Properties"],
            propertySurvivorReruns: runs,
            propertySurvivorRerunLimit: limit
        )
    }

    private func outcome(of changes: [MutationTestState.Change]) -> MutationTestOutcome? {
        guard case let .mutationTestOutcomeGenerated(outcome)? = changes.first else { return nil }
        return outcome
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
}
