import Foundation

struct MutationTestOutcome {
    let mutations: [Mutation]
    let coverage: Coverage
    /// Whether the run skipped coverage (`--skip-coverage`), so a `.null` coverage wasn't a failure to gather it.
    let coverageSkipped: Bool
    let testDuration: TimeInterval
    let newVersion: String
    /// What `--since` chose; nil without it.
    let since: ChangeSelection?

    init(
        mutations: [Mutation] = [],
        coverage: Coverage = .null,
        coverageSkipped: Bool = false,
        testDuration: TimeInterval = 0,
        newVersion: String = "",
        since: ChangeSelection? = nil
    ) {
        self.mutations = mutations
        self.coverage = coverage
        self.coverageSkipped = coverageSkipped
        self.testDuration = testDuration
        self.newVersion = newVersion
        self.since = since
    }
}

extension MutationTestOutcome: Equatable {}

extension MutationTestOutcome {
    struct Mutation: Equatable {
        let testSuiteOutcome: TestSuiteOutcome
        let point: MutationPoint
        let snapshot: MutationOperator.Snapshot
        let originalProjectPath: String
        /// The tests its run's log showed failing, as its results line records them. nil when none were recorded: a
        /// survivor, a build error, or a session whose failed-test lines weren't reliable.
        let killingTests: KillingTests?
        /// Where it was tested, for a result a run reused from an earlier run's results file (`--reuse`); nil for one
        /// the run tested, or kept from an earlier session of its own file.
        let reusedFrom: ReusedFrom?

        /// `killingTests` and `reusedFrom` have no default: the run, `swift-mutator report` and `--resume` must each
        /// pass theirs.
        init(
            testSuiteOutcome: TestSuiteOutcome,
            mutationPoint: MutationPoint,
            mutationSnapshot: MutationOperator.Snapshot,
            originalProjectDirectoryUrl: URL,
            mutatedProjectDirectoryURL: URL,
            killingTests: KillingTests?,
            reusedFrom: ReusedFrom?
        ) {
            self.testSuiteOutcome = testSuiteOutcome
            point = mutationPoint
            snapshot = mutationSnapshot
            self.killingTests = killingTests
            self.reusedFrom = reusedFrom

            let splitTempFilePath = mutationPoint.filePath.split(separator: "/")
            let tempProjectDirectoryName = mutatedProjectDirectoryURL.lastPathComponent
            let numberOfDirectoriesToDrop = splitTempFilePath.map(String.init)
                .firstIndex(of: tempProjectDirectoryName) ?? 0
            let pathSuffix = splitTempFilePath.dropFirst(numberOfDirectoriesToDrop + 1).joined(separator: "/")

            originalProjectPath = originalProjectDirectoryUrl
                .appendingPathComponent(pathSuffix, isDirectory: true)
                .path
        }
    }

    /// A mutant's `MutantResult.killedBy` and `failedTestCount`, with whether the list is complete
    /// (Docs/results-file.md). The JSON report holds it as `{tests: [{name, location?}], count, isComplete}`.
    struct KillingTests: Codable, Equatable {
        /// Each test once, in the order it first failed, at most `FailedTestLine.killedByLimit`.
        let tests: [FailedTestLine.FailedTest]
        /// How many distinct tests failed, uncapped.
        let count: Int
        /// Whether the run exited by itself and `tests` names every test that failed. A run stopped at its first
        /// failed test, or at its time limit, may have had others to fail.
        let isComplete: Bool
    }
}

// In an extension, so the memberwise initializer stays.
extension MutationTestOutcome.KillingTests {
    /// The tests a run that ended `endedBy` recorded failing: nil when it recorded none, and an empty list stays
    /// empty. Without a count, the list's length is the count.
    init?(killedBy: [FailedTestLine.FailedTest]?, failedTestCount: Int?, endedBy: TestRun.Ending) {
        guard let killedBy else { return nil }
        let count = failedTestCount ?? killedBy.count
        self.init(tests: killedBy, count: count, isComplete: endedBy == .exited && count == killedBy.count)
    }

    /// The tests `failures` names, for a run that ended `endedBy`.
    init?(_ failures: FailedTestLine.FailedTests?, endedBy: TestRun.Ending) {
        self.init(killedBy: failures?.tests, failedTestCount: failures?.count, endedBy: endedBy)
    }

    /// The tests a results line records.
    init?(_ record: MutantResult) {
        self.init(killedBy: record.killedBy, failedTestCount: record.failedTestCount, endedBy: record.endedBy)
    }
}
