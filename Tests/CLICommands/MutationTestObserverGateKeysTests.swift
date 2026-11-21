@testable import muterCore
import XCTest

/// The end of a run whose gates come from the configuration's keys alone, `baseline:`, `maxNewSurvivors:`,
/// `maxScoreDrop:` and `maxDoubtfulKills:`, with no flag: the outcome takes them from the configuration
/// (`PerformMutationTesting.addBaseline`), and the observer judges the run's end by them as it would by the flags.
final class MutationTestObserverGateKeysTests: MuterTestCase {
    private let state = MutationTestState()
    private lazy var sut = MutationTestObserver(runOptions: .make())

    override func setUp() {
        super.setUp()

        fileManager.currentDirectoryPathToReturn = "/"
    }

    private func key(_ line: Int) -> MutantKey {
        MutantKey(
            path: "Sources/X.swift",
            mutationOperatorId: .relationalBoundary,
            line: line,
            column: 17,
            occurrence: 0
        )
    }

    /// A finished run with a survivor at line 1, which the baseline file records, a new one at line 5, and a kill at
    /// line 3 whose code never ran, against a file of a run that killed both of its mutants, with the state's gates.
    private func finishedOutcome() -> MutationTestOutcome {
        state.mutationOperatorList = [.relationalBoundary]
        state.apply([
            .baselineFileLoaded(
                BaselineFile(
                    path: "/project/muter.baseline.yml",
                    swiftMutator: muterCore.version,
                    score: .init(killed: 2, scored: 2),
                    scope: BaselineScope(operators: [], skipCoverage: false, configuration: .init()),
                    survivors: [BaselineSurvivor(mutant: key(1), outcome: .survived, before: "<", after: "<=")]
                )
            ),
        ])
        var outcome = MutationTestOutcome(
            mutations: [(1, TestSuiteOutcome.passed), (3, .failed), (5, .passed)].map { line, testOutcome in
                var mutation = MutationTestOutcome.Mutation.make(
                    testSuiteOutcome: testOutcome,
                    snapshot: .make(before: "<", after: "<="),
                    key: key(line)
                )
                if line == 3 {
                    mutation.activated = .didNotRun
                }
                return mutation
            }
        )
        PerformMutationTesting.addBaseline(of: state, to: &outcome)
        return outcome
    }

    func test_theGateKeys_alone_failTheRun_asTheirFlagsWould() throws {
        state.muterConfiguration.gates = RunGates(
            baseline: "/project/muter.baseline.yml",
            maxNewSurvivors: 0,
            maxScoreDrop: 1,
            maxDoubtfulKills: 0
        )
        try sut.start()

        runEvents.send(.mutationTestingFinished(finishedOutcome()))

        XCTAssertEqual(sut.checks.newSurvivors?.result, .failed)
        XCTAssertEqual(sut.checks.scoreDrop?.result, .failed)
        XCTAssertEqual(sut.checks.doubtfulKills?.result, .failed)
        XCTAssertEqual(sut.checks.exitStatus, .scoreBelowThreshold)
        XCTAssertTrue(
            printer.linesPassed.contains {
                $0.hasPrefix("❌ 1 new survivor against the baseline file /project/muter.baseline.yml")
            },
            "\(printer.linesPassed)"
        )
    }

    // A count from `maxNewSurvivors:` lets the new survivor through, and a gate no key sets checks nothing.
    func test_aKeysCount_letsTheSurvivorThrough_andAGateNoKeySets_checksNothing() throws {
        state.muterConfiguration.gates = RunGates(baseline: "/project/muter.baseline.yml", maxNewSurvivors: 1)
        try sut.start()

        runEvents.send(.mutationTestingFinished(finishedOutcome()))

        XCTAssertEqual(sut.checks.newSurvivors?.result, .passed)
        XCTAssertNil(sut.checks.scoreDrop)
        XCTAssertNil(sut.checks.doubtfulKills)
        XCTAssertNil(sut.checks.exitStatus)
    }
}
