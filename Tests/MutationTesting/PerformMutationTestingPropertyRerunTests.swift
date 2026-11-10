@testable import muterCore
import TestingExtensions
import XCTest

/// Property reruns: once every mutant is tested, each kill whose recorded tests include no property test is tested
/// again with only the property tests `propertyTestFilter` selects (`PropertyReruns`).
final class PerformMutationTestingPropertyRerunTests: MuterTestCase {
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

    // Mutants 1 and 4 were killed by an example alone, 2 by a property, and 3 survived: 1 and 4 are run again, and
    // the property tests killed 1 too, and passed for 4.
    func test_theKillsOfExamplesAlone_areTestedAgainWithTheFilteredPropertyTests() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .passed, .failed, .failed, .passed]
        ioDelegate.mutantTestLogs = [sum, ordered, "✔ passed", sum, ordered, threePassed]
        ioDelegate.controlRuns = [(.passed, threePassed)]
        let sent = recordEvents(named: [.propertyRerunsStarted, .propertyRerunsFinished, .propertyRerunsSkipped])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(
            try resultsFiles.kinds(),
            ["header", "mutant", "mutant", "mutant", "mutant", "propertyRerun", "propertyRerun", "end"]
        )
        let reruns = try resultsFiles.records(PropertyRerunResult.self)
        XCTAssertEqual(reruns.map(\.line), [1, 4])
        XCTAssertEqual(reruns.map(\.outcome), [.failed, .passed])
        XCTAssertEqual(reruns.first?.killedBy, [.init(name: "ordered()", location: "SortProperties.swift:8:5")])
        XCTAssertEqual(reruns.map(\.session), [1, 1])
        // A kill its line names keeps no log, nor does a run that passed; the property tests' baseline keeps its own.
        XCTAssertEqual(reruns.map(\.log), [nil, nil])
        XCTAssertEqual(
            fileManager.createdFiles["/logs/property tests with no mutant on.log"], Data(threePassed.utf8)
        )
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.recorded), [4], "never counted as a mutant")

        // The property tests' runs, the baseline with no mutant on and the two reruns, filter the test command.
        let filtered = ioDelegate.configurations.suffix(2) + ioDelegate.controlRunConfigurations
        XCTAssertEqual(filtered.map(\.testFilterArguments), Array(repeating: ["--filter", "Properties"], count: 3))
        XCTAssertTrue(ioDelegate.configurations.dropLast(2).allSatisfy(\.testFilterArguments.isEmpty))

        XCTAssertEqual(sent().map(\.name), [.propertyRerunsStarted, .propertyRerunsFinished])
        let tally = try XCTUnwrap(sent().last?.object as? PropertyRerunTally)
        XCTAssertEqual([tally.rerun, tally.killed, tally.passed, tally.unsettled], [2, 1, 1, 0])

        let outcome = try XCTUnwrap(outcome(of: changes))
        XCTAssertEqual(outcome.mutations.map(\.propertyRerun?.outcome), [.failed, nil, nil, .passed])
        let summary = try XCTUnwrap(PropertyKillSummary(of: outcome.mutations, globs: ["*Properties*"]))
        XCTAssertEqual([summary.killedOnlyByExamples, summary.killedOnlyByProperties, summary.killedByBoth], [1, 1, 1])
        XCTAssertEqual([summary.propertyReruns, summary.propertyRerunKills, summary.propertyRerunPasses], [2, 1, 1])
    }

    // A filter that matches no test passes with every mutant on: no rerun means anything, so none runs, and that is
    // said.
    func test_noKillIsTestedAgain_whenTheFilteredRunWithNoMutantOn_ranNoTest() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .passed, .failed]
        ioDelegate.mutantTestLogs = [sum, ordered, "✔ passed", sum]
        ioDelegate.controlRuns = [(.passed, "")]
        let sent = recordEvents(named: [.propertyRerunsStarted, .propertyRerunsSkipped])

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(PropertyRerunResult.self), [])
        XCTAssertEqual(sent().map(\.name), [.propertyRerunsSkipped])
        let (reason, log) = try XCTUnwrap(sent().first?.object as? (String, String?))
        XCTAssertEqual(
            reason, "with no mutant on, the tests propertyTestFilter selects ran none, so it may match no test"
        )
        XCTAssertEqual(log, "property tests with no mutant on.log")
    }

    func test_noRerun_withoutAFilter_orWithNoKillOfExamplesAlone() async throws {
        state.muterConfiguration = configuration(filter: nil)
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .passed, .failed]
        ioDelegate.mutantTestLogs = [sum, ordered, "✔ passed", sum]

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(PropertyRerunResult.self), [])
        XCTAssertEqual(ioDelegate.controlRunConfigurations, [])
    }

    // MARK: Helpers

    func test_testsRun_addsSwiftTestingsRuns_toXCTestsLargestCount() {
        let log = """
        ✔ Test run with 3 tests in 1 suite passed after 0.4 seconds.
        ✔ Test run with 1 test in 1 suite passed after 0.1 seconds.
        Test Suite 'SortTests' passed. Executed 2 tests, with 0 failures (0 unexpected) in 0.1 seconds
        Test Suite 'All tests' passed. Executed 5 tests, with 0 failures (0 unexpected) in 0.2 seconds
        """
        XCTAssertEqual(PerformMutationTesting.testsRun(in: log), 9)
        XCTAssertEqual(PerformMutationTesting.testsRun(in: ""), 0)
        XCTAssertEqual(PerformMutationTesting.testsRun(in: "Executed 0 tests, with 0 failures"), 0)
    }

    func test_aFailedRunWithNoMutantOn_makesTheRerunsMeanNothing() {
        let passed = TestRun(outcome: .passed, testLog: threePassed, ending: .exited, exitStatus: 0)
        let failedLog = "✘ Test run with 3 tests in 1 suite failed after 0.4 seconds."
        let failed = TestRun(outcome: .failed, testLog: failedLog, ending: .exited, exitStatus: 1)
        let crashedEarly = TestRun(outcome: .runtimeError, testLog: "", ending: .exited, exitStatus: 1)

        XCTAssertNil(PerformMutationTesting.whyPropertyRerunsMeanNothing(passed))
        XCTAssertEqual(
            PerformMutationTesting.whyPropertyRerunsMeanNothing(failed),
            "the tests propertyTestFilter selects didn't pass with no mutant on"
        )
        XCTAssertNotNil(PerformMutationTesting.whyPropertyRerunsMeanNothing(crashedEarly))
    }

    private func configuration(filter: [String]? = ["Properties"]) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
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
}
