import Foundation

/// An example rerun's line in the results file: a kill whose recorded tests are all property tests, and whose list was
/// cut short, tested again with every test but those `propertyTestFilter` selects (`ExampleReruns`). A run stopped at
/// its first failed test records that test alone, so a property that failed first hides an example that would also
/// have failed. It follows the mutant's own line, which it never replaces: the reports read it to tell "only by
/// properties" from "by both". A later `mutant` line of the same key, a new result, sets it aside. A reader that
/// doesn't know the kind skips the line.
struct ExampleRerunResult: Codable, Equatable {
    var kind = "exampleRerun" // swiftlint:disable:this unused_declaration - results file key; Codable writes it
    let session: Int
    /// The mutant's key's fields (`MutantKey`), as its `mutant` line records them.
    let path: String
    let line: Int
    let column: Int
    let occurrence: Int
    let mutationOperatorId: MutationOperator.Id
    /// How the tests came out with the mutant on and the property tests skipped: `failed` with a test the
    /// `propertyTests` globs don't match is a kill by an example too.
    let outcome: TestSuiteOutcome
    let endedBy: TestRun.Ending
    /// Only for an `exited` run: its exit code, or the signal that ended it.
    let exitStatus: Int32? // swiftlint:disable:this unused_declaration - results file key; Codable writes it
    /// From launch to classification, to the millisecond.
    let durationSeconds: Double // swiftlint:disable:this unused_declaration - results file key; Codable writes it
    /// Where it ran, as a mutant's `worker` says.
    let worker: Int // swiftlint:disable:this unused_declaration - results file key; Codable writes it
    let finishedAt: Date
    /// The tests its log shows failing, as a mutant's `killedBy` names them.
    let killedBy: [FailedTestLine.FailedTest]?
    /// How many distinct tests its log shows failing, uncapped.
    let failedTestCount: Int?
    /// The first line that shows one, without colour codes, capped.
    let firstFailedTestLine: String? // swiftlint:disable:this unused_declaration - results file key; Codable writes it
    /// The kept log's file name in the session's `logDirectory`, when it was kept.
    let log: String?

    var key: MutantKey {
        MutantKey(
            path: path,
            mutationOperatorId: mutationOperatorId,
            line: line,
            column: column,
            occurrence: occurrence
        )
    }
}

extension MutationTestOutcome {
    /// A kill by properties alone's example rerun, as the reports read it (`ExampleRerunResult`).
    struct ExampleRerun: Codable, Equatable {
        let outcome: TestSuiteOutcome
        /// The tests it recorded failing.
        let killingTests: KillingTests?

        /// Whether an example killed the mutant too: a test that `isProperty` doesn't pick out failed. The tests left
        /// once the filter's are skipped may hold property tests the globs match, which say nothing of the examples.
        func examplesFailed(isProperty: (FailedTestLine.TestIdentity) -> Bool) -> Bool {
            (killingTests?.tests ?? []).contains { !isProperty(FailedTestLine.TestIdentity($0)) }
        }
    }
}
