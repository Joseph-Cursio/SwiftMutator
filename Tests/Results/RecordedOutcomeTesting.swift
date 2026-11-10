import Foundation
@testable import muterCore

/// Fixtures for the suites that rebuild a run's outcome from its results file: schemata mappings, and the lines
/// mutation testing writes for their mutants.
protocol RecordedOutcomeTesting {}

extension RecordedOutcomeTesting {
    /// A file in the mutated project at `path`, with a mutant on each of `lines`, at column 5.
    func makeMapping(_ path: String, lines: [Int]) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: path,
            (
                source: "func bar() { }",
                schemata: lines.map { line in
                    try .make(
                        filePath: path,
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line * 10, line: line, column: 5),
                        // A description with a quote and a line break, which the file escapes.
                        snapshot: .make(
                            before: ">",
                            after: "<",
                            description: "changed \"x > \(line)\"\nto \"x < \(line)\""
                        )
                    )
                }
            )
        )
    }

    /// The line mutation testing writes when the run of `schema`'s mutant, keyed `key`, ends in `outcome`, ended
    /// `endedBy`, with `killedBy` failed, of `failedTestCount`.
    func mutantResult(
        _ schema: MutationSchema,
        _ key: MutantKey,
        outcome: TestSuiteOutcome = .failed,
        session: Int = 1,
        finishedAt: Date = ResultsHeader.fixedStart + 1,
        killedBy: [FailedTestLine.FailedTest]? = nil,
        failedTestCount: Int? = nil,
        endedBy: TestRun.Ending = .exited
    ) -> MutantResult {
        MutantResult(
            session: session,
            path: key.path,
            line: key.line,
            column: key.column,
            occurrence: key.occurrence,
            utf8Offset: schema.position.utf8Offset,
            mutationOperatorId: schema.mutationOperatorId,
            switchID: schema.id,
            snapshot: schema.snapshot,
            outcome: outcome,
            endedBy: endedBy,
            exitStatus: endedBy == .exited ? (outcome == .passed ? 0 : 1) : nil,
            durationSeconds: 1.5,
            worker: 0,
            finishedAt: finishedAt,
            killedBy: killedBy,
            failedTestCount: failedTestCount,
            firstFailedTestLine: nil,
            log: "",
            fileSHA256: nil
        )
    }
}
