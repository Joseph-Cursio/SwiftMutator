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
    /// The shards of a `--shard` split it covers, when it covers only some: the one a run tested, or those `report`
    /// merged when some are missing; nil for a whole run.
    let shards: ShardScope?
    /// What `--sample` took; nil without it.
    let sample: SampleSelection?
    /// Whether the results of `sample` are cut short: a run, or a shard's, stopped before every mutant it set out to
    /// test had a result. They are then its first files', not a random part of the sample, so the score has no margin.
    /// A shard's results are a random part of it, as its hash doesn't depend on the seed.
    let sampleIsCutShort: Bool
    /// The one mutant `--mutant` tested, by its key's description; nil without it. Its score isn't the project's.
    let mutant: String?
    /// When a test is suspect: the run's configuration's, or its last session's as its header records it.
    let suspectTestThresholds: SuspectTestThresholds
    /// The control runs, with no mutant on, of every session the outcome covers, in the order they're recorded.
    let controlRuns: [ControlRun]
    /// The project, and its mutated copy, by their absolute paths: what the reports give each file's path relative to.
    /// "" when not known.
    let projectPath: String
    let mutatedProjectPath: String
    /// Each project file's SHA-256 as it was tested, by its path relative to the project (`ProjectTree.files`): the
    /// reports show a mutant's line from its original file only while that file is as it was. nil when not recorded.
    let sourceDigests: [String: String]?

    init(
        mutations: [Mutation] = [],
        coverage: Coverage = .null,
        coverageSkipped: Bool = false,
        testDuration: TimeInterval = 0,
        newVersion: String = "",
        since: ChangeSelection? = nil,
        shards: ShardScope? = nil,
        sample: SampleSelection? = nil,
        sampleIsCutShort: Bool = false,
        mutant: String? = nil,
        suspectTestThresholds: SuspectTestThresholds = .standard,
        controlRuns: [ControlRun] = [],
        projectPath: String = "",
        mutatedProjectPath: String = "",
        sourceDigests: [String: String]? = nil
    ) {
        self.mutations = mutations
        self.coverage = coverage
        self.coverageSkipped = coverageSkipped
        self.testDuration = testDuration
        self.newVersion = newVersion
        self.since = since
        self.shards = shards
        self.sample = sample
        self.sampleIsCutShort = sampleIsCutShort
        self.mutant = mutant
        self.suspectTestThresholds = suspectTestThresholds
        self.controlRuns = controlRuns
        self.projectPath = projectPath
        self.mutatedProjectPath = mutatedProjectPath
        self.sourceDigests = sourceDigests
    }
}

extension MutationTestOutcome: Equatable {}

extension MutationTestOutcome {
    /// This outcome, with `sourceDigests` in place of its own.
    func with(sourceDigests: [String: String]?) -> MutationTestOutcome {
        MutationTestOutcome(
            mutations: mutations,
            coverage: coverage,
            coverageSkipped: coverageSkipped,
            testDuration: testDuration,
            newVersion: newVersion,
            since: since,
            shards: shards,
            sample: sample,
            sampleIsCutShort: sampleIsCutShort,
            mutant: mutant,
            suspectTestThresholds: suspectTestThresholds,
            controlRuns: controlRuns,
            projectPath: projectPath,
            mutatedProjectPath: mutatedProjectPath,
            sourceDigests: sourceDigests
        )
    }
}

extension MutationTestOutcome {
    struct Mutation: Equatable {
        let testSuiteOutcome: TestSuiteOutcome
        let point: MutationPoint
        let snapshot: MutationOperator.Snapshot
        let originalProjectPath: String
        /// Its file's path relative to the project, as the reports show it: "Sources/Foo/Rules.swift". A file outside
        /// the mutated copy keeps its absolute path.
        let relativePath: String
        /// The tests its run's log showed failing, as its results line records them. nil when none were recorded: a
        /// survivor, a build error, or a mutant tested before SwiftMutator recorded them when the baseline printed a
        /// line shaped like a failed test.
        let killingTests: KillingTests?
        /// Where it was tested, for a result a run reused from an earlier run's results file (`--reuse`); nil for one
        /// the run tested, or kept from an earlier session of its own file.
        let reusedFrom: ReusedFrom?

        /// `killingTests` and `reusedFrom` have no default: the run, `swift-mutator report` and `--resume` must each
        /// pass theirs.
        ///
        /// The mutant's file in the original project is the one at its place in the copy, whatever either folder is
        /// called or wherever it is; a file outside the copy keeps its own path.
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

            relativePath = RepoRelativePath.of(mutationPoint.filePath, under: mutatedProjectDirectoryURL)
            originalProjectPath = RepoRelativePath.resolve(relativePath, under: originalProjectDirectoryUrl.path)
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

extension MutationTestOutcome {
    /// A control run, with no mutant on (`ControlRunResult`): how it ended, and the tests it recorded failing, nil when
    /// it passed or built nothing.
    struct ControlRun: Equatable {
        let outcome: TestSuiteOutcome
        let failedTests: KillingTests?

        init(outcome: TestSuiteOutcome, failedTests: KillingTests?) {
            self.outcome = outcome
            self.failedTests = failedTests
        }

        init(_ record: ControlRunResult) {
            self.init(
                outcome: record.outcome,
                failedTests: KillingTests(
                    killedBy: record.failedTests, failedTestCount: record.failedTestCount, endedBy: record.endedBy
                )
            )
        }
    }
}
