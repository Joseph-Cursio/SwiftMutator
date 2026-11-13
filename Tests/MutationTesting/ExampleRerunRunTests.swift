@testable import muterCore
import TestingExtensions
import XCTest

/// Example reruns: once every mutant is tested, each kill whose recorded tests are all property tests, in a list cut
/// short, is tested again with every test but those `propertyTestFilter` selects (`ExampleReruns`).
final class ExampleRerunRunTests: MuterTestCase {
    private let state = MutationTestState()
    private let sum = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4"
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
        state.muterConfiguration = configuration()
        state.mutationMapping = try (1 ... 4).map { try makeSchemataMapping(file: "Sources/File\($0).swift", line: $0) }
    }

    // Mutants 1, 3 and 4 were killed by a property alone, and 2 survived. 1 and 4 stopped at that failed test, so an
    // example may have failed too, and are run again with the property tests skipped: an example fails for 1, which
    // becomes a kill by both, and every test passes for 4, which stays one by properties alone. 3 ran to its end.
    func test_theKillsOfPropertiesAloneCutShort_areTestedAgainWithThePropertyTestsSkipped() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed, .failed, .failed, .passed]
        ioDelegate.mutantTestLogs = [ordered, "✔ passed", ordered, ordered, sum, threePassed]
        ioDelegate.mutantRunEndings = [.stoppedAtFailedTest, .exited, .exited, .stoppedAtFailedTest]
        ioDelegate.controlRuns = [(.passed, threePassed)]
        let sent = recordEvents(named: [.exampleRerunsStarted, .exampleRerunsFinished, .exampleRerunsSkipped])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(
            try resultsFiles.kinds(),
            ["header", "mutant", "mutant", "mutant", "mutant", "exampleRerun", "exampleRerun", "end"]
        )
        let reruns = try resultsFiles.records(ExampleRerunResult.self)
        XCTAssertEqual(reruns.map(\.line), [1, 4])
        XCTAssertEqual(reruns.map(\.outcome), [.failed, .passed])
        XCTAssertEqual(reruns.first?.killedBy, [.init(name: "sum()", location: "SumTests.swift:12:5")])
        XCTAssertEqual(reruns.map(\.log), [nil, nil], "a failure its line names, and a pass, keep no log")
        XCTAssertEqual(
            fileManager.createdFiles["/logs/tests but the property tests with no mutant on.log"], Data(threePassed.utf8)
        )
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.recorded), [4], "never counted as a mutant")

        // The baseline and both reruns skip the property tests; the mutants' runs don't.
        let skipping = ioDelegate.configurations.suffix(2) + ioDelegate.controlRunConfigurations
        XCTAssertEqual(skipping.map(\.testFilterArguments), Array(repeating: ["--skip", "Properties"], count: 3))
        XCTAssertTrue(ioDelegate.configurations.dropLast(2).allSatisfy(\.testFilterArguments.isEmpty))

        XCTAssertEqual(sent().map(\.name), [.exampleRerunsStarted, .exampleRerunsFinished])
        let tally = try XCTUnwrap(sent().last?.object as? ExampleRerunTally)
        XCTAssertEqual([tally.rerun, tally.examplesFailed, tally.passed, tally.unsettled], [2, 1, 1, 0])

        let outcome = try XCTUnwrap(outcome(of: changes))
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .passed, .failed, .failed])
        XCTAssertEqual(outcome.mutations.map(\.exampleRerun?.outcome), [.failed, nil, nil, .passed])
        let summary = try XCTUnwrap(PropertyKillSummary(of: outcome.mutations, globs: ["*Properties*"]))
        XCTAssertEqual([summary.killedOnlyByProperties, summary.killedByBoth, summary.incompletePropertyOnlyKills], [
            2, 1, 0,
        ])
        XCTAssertEqual([summary.exampleReruns, summary.exampleRerunKills, summary.exampleRerunPasses], [2, 1, 1])
    }

    // With the property tests skipped and no mutant on, no test ran: no rerun means anything, so none runs, and that
    // is said.
    func test_noKillIsTestedAgain_whenTheRunWithNoMutantOn_ranNoTest() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .passed, .passed]
        ioDelegate.mutantTestLogs = [ordered, "✔ passed", "✔ passed", "✔ passed"]
        ioDelegate.mutantRunEndings = [.stoppedAtFailedTest]
        ioDelegate.controlRuns = [(.passed, "")]
        let sent = recordEvents(named: [.exampleRerunsStarted, .exampleRerunsSkipped])

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ExampleRerunResult.self), [])
        XCTAssertEqual(sent().map(\.name), [.exampleRerunsSkipped])
        let (reason, log) = try XCTUnwrap(sent().first?.object as? (String, String?))
        XCTAssertEqual(reason, "with no mutant on and the tests propertyTestFilter selects skipped, no test ran")
        XCTAssertEqual(log, "tests but the property tests with no mutant on.log")
    }

    // Kills by properties alone in a list cut short only: never a crash, a list that holds every failed test, one that
    // names an example, one not in the build, one tested so already, or one whose code didn't run.
    func test_candidates_areKillsByPropertiesAloneInAListCutShort() {
        let property = FailedTestLine.FailedTest(name: "ordered()", location: "SortProperties.swift:8:5")
        let example = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:12:5")
        func kill(_ tests: [FailedTestLine.FailedTest], complete: Bool = false) -> MutationTestOutcome.Mutation {
            .make(
                testSuiteOutcome: .failed,
                killingTests: .init(tests: tests, count: tests.count, isComplete: complete)
            )
        }
        var crash = kill([property])
        crash = .make(testSuiteOutcome: .runtimeError, killingTests: crash.killingTests)
        var testedAgain = kill([property])
        testedAgain.exampleRerun = .init(outcome: .passed, killingTests: nil)
        var didNotRun = kill([property])
        didNotRun.activated = .didNotRun
        let session = TestingSession(startedAt: Date())
        session.outcomes = [
            0: kill([property]),
            1: crash,
            2: kill([property], complete: true),
            3: kill([property, example]),
            4: kill([property]),
            5: testedAgain,
            6: didNotRun,
            7: kill([example]),
            8: kill([property]),
        ]
        session.notInTheBuild = [4]

        XCTAssertEqual(PerformMutationTesting.exampleRerunCandidates(in: session, globs: ["*Properties*"]), [0, 8])
    }

    // `swift test` and the bundles run directly take `--skip` for each entry; no other test command stops at its first
    // failed test, so none is given one, nor a configuration with no filter.
    func test_withPropertyTestsSkipped_skipsEachEntry_underSwiftTestOnly() throws {
        let swift = configuration()
        let skipping = try XCTUnwrap(swift.withPropertyTestsSkipped())
        XCTAssertEqual(skipping.testFilterArguments, ["--skip", "Properties"])

        let xcodebuild = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", "platform=macOS", "test"],
            propertyTests: ["*Properties*"],
            propertyTestFilter: ["AppTests/Properties"]
        )
        XCTAssertNotNil(xcodebuild.withPropertyTestFilter(), "the property rerun runs under xcodebuild")
        XCTAssertNil(xcodebuild.withPropertyTestsSkipped())
        XCTAssertNil(configuration(filter: nil).withPropertyTestsSkipped())
    }

    // A rerun that only failed property tests the filter didn't select, but the globs match, says nothing of the
    // examples: the kill stays one by properties alone, still cut short.
    func test_aRerunFailingOnlyPropertyTests_settlesNothing() throws {
        let property = FailedTestLine.FailedTest(name: "ordered()", location: "SortProperties.swift:8:5")
        let other = FailedTestLine.FailedTest(name: "reversed()", location: "OtherProperties.swift:3:5")
        var mutation = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .failed,
            killingTests: .init(tests: [property], count: 1, isComplete: false)
        )
        mutation.exampleRerun = .init(
            outcome: .failed,
            killingTests: .init(tests: [other], count: 1, isComplete: false)
        )

        let summary = try XCTUnwrap(PropertyKillSummary(of: [mutation], globs: ["*Properties*"]))

        XCTAssertEqual([summary.killedOnlyByProperties, summary.killedByBoth, summary.incompletePropertyOnlyKills], [
            1, 0, 1,
        ])
        XCTAssertEqual([summary.exampleReruns, summary.exampleRerunKills, summary.exampleRerunPasses], [1, 0, 0])
        XCTAssertTrue(
            summary.splitSentences.contains(
                "Every test but the property tests ran again for 1 kill only properties were recorded making, whose "
                    + "lists were cut short: an example failed too for 0, which count as by both, and every test "
                    + "passed for 0; 1 settled nothing."
            ),
            "\(summary.splitSentences)"
        )
    }

    // MARK: Helpers

    private func configuration(filter: [String]? = ["Properties"]) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            mutationTestWorkers: 1,
            controlRunEvery: 0,
            propertyTests: ["*Properties*"],
            propertyTestFilter: filter
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
