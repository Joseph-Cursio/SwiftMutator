@testable import muterCore
import XCTest

/// What the end of a run checks with, as mutation testing gives it to the outcome: `--max-score-drop` with
/// `--baseline`, and `--max-doubtful-kills` with or without it.
final class PerformMutationTestingCheckLimitsTests: MuterTestCase {
    private let state = MutationTestState()
    private lazy var sut = PerformMutationTesting()

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.mutationMapping = try [
            SchemataMutationMapping.make(
                filePath: "/some/path",
                (
                    source: "func bar() { }",
                    schemata: [
                        .make(
                            filePath: "/tmp/project/file.swift",
                            mutationOperatorId: .ror,
                            syntaxMutation: "",
                            position: .firstPosition,
                            snapshot: .null
                        ),
                    ]
                )
            ),
        ]
    }

    func test_theOutcome_carriesTheLimits() async throws {
        state.runOptions = .make(baseline: "muter.baseline.yml", maxScoreDrop: 1.5, maxDoubtfulKills: 3)
        let outcome = try await finishedOutcome()

        XCTAssertEqual(outcome.maxScoreDrop, 1.5)
        XCTAssertEqual(outcome.maxDoubtfulKills, 3)
    }

    // `--max-score-drop` says only what `--baseline` allows.
    func test_withoutABaselineFile_onlyTheDoubtfulKillLimit_isCarried() async throws {
        state.runOptions = .make(maxScoreDrop: 1.5, maxDoubtfulKills: 0)
        let outcome = try await finishedOutcome()

        XCTAssertNil(outcome.maxScoreDrop)
        XCTAssertEqual(outcome.maxDoubtfulKills, 0)
    }

    /// The outcome a run of the one mutant, killed, finishes with.
    private func finishedOutcome() async throws -> MutationTestOutcome {
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
        var sent: [RunEvent] = []
        let token = runEvents.observe(.mutationTestingFinished) { sent.append($0) }
        defer { token.cancel() }

        _ = try await sut.run(with: state)

        return try XCTUnwrap(sent.compactMap { $0.object as? MutationTestOutcome }.first)
    }
}
