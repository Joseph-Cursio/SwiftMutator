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
    /// The run's threshold for its score, its configuration's `failUnder` or `--fail-under`'s, which `ScoreGate`
    /// checks; nil without one, and for an outcome read from a results file, as `report` checks only its own flag.
    let failUnder: Double?
    /// The globs that pick out property tests (`PropertyTestPattern`), which the reports split the kills by
    /// (`PropertyKillSummary`): the run's configuration's, or its last session's as its header records it, unless
    /// `report --property-tests` gives others. Empty splits none.
    var propertyTests: [String]
    /// The reports a run saves besides `-f`'s: its configuration's `reports`, or `--report`'s, with their paths
    /// resolved. Empty for an outcome read from a results file, as `report` saves only those its own `--report` asks
    /// for.
    let reports: [ReportRequest]
    /// The labels people gave surviving mutants (`TriageFile`), which the reports show; nil without a file.
    var triage: TriageFile?
    /// The control runs, with no mutant on, of every session the outcome covers, in the order they're recorded.
    let controlRuns: [ControlRun]
    /// The project, and its mutated copy, by their absolute paths: what the reports give each file's path relative to.
    /// "" when not known.
    let projectPath: String
    let mutatedProjectPath: String
    /// Each project file's SHA-256 as it was tested, by its path relative to the project (`ProjectTree.files`): the
    /// reports show a mutant's line from its original file only while that file is as it was. nil when not recorded.
    var sourceDigests: [String: String]?
    /// Where the results came from, as the results file's headers record them (`RunDetails`); nil when there's no
    /// header, as for a run whose results file couldn't be made, or once a write to the file failed.
    var run: RunDetails?
    /// `--baseline`'s file, which `NewSurvivorsCheck` compares the run's survivors with, allowing `maxNewSurvivors` new
    /// ones; nil without it, and for an outcome read from a results file, as `report` checks only its own flags.
    var baseline: BaselineFile?
    var maxNewSurvivors = 0
    /// `--max-score-drop`: how many points the score may fall below `baseline`'s, which `ScoreDropCheck` compares;
    /// nil without it, and for an outcome read from a results file.
    var maxScoreDrop: Double?
    /// `--max-doubtful-kills`: how many kills the run's evidence may leave in doubt (`DoubtfulKillsCheck`); nil
    /// without it, and for an outcome read from a results file.
    var maxDoubtfulKills: Int?
    /// What a baseline file of these results records of their scope (`BaselineScope`): the run's, or as the results
    /// header records it; nil when not known.
    var baselineScope: BaselineScope?
    /// The files `--files-to-mutate` limited the run to, of which no baseline file is written; empty without it.
    var filesToMutate: [String] = []
    /// With `--baseline`, the mutants the run discovered and left out, as `--shard`, `--sample` or `--changed-lines`
    /// chose others, which a baseline file's entries for them are paired with (`BaselineMatches`); empty when it left
    /// none out. nil when they aren't known, as for an outcome read from a results file, which doesn't record them.
    var unselectedMutants: [UnselectedMutant]?
    /// The mutants of code no test ran, which the run made none of, of the code it chose (`UncoveredMutant`): a
    /// baseline file records them as survivors not covered, and `NewSurvivorsCheck` compares them, but no score counts
    /// them, nor any count a report shows. The run's, or as the results header records them; empty when there are none,
    /// as with `--skip-coverage`. nil when they aren't known: results an older SwiftMutator wrote, or the run of a test
    /// plan one made, don't record them, and a run of one mutant doesn't look for them.
    var uncoveredMutants: [UncoveredMutant]? = []
    /// The verdicts of the checks the run, or `report`, was asked for (`RunChecks`), made before any report is, so
    /// the Markdown report can show them; nil until then, and when none was asked for, so a report is as it was.
    var checks: RunChecks?

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
        failUnder: Double? = nil,
        propertyTests: [String] = [],
        reports: [ReportRequest] = [],
        triage: TriageFile? = nil,
        controlRuns: [ControlRun] = [],
        projectPath: String = "",
        mutatedProjectPath: String = "",
        sourceDigests: [String: String]? = nil,
        run: RunDetails? = nil
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
        self.failUnder = failUnder
        self.propertyTests = propertyTests
        self.reports = reports
        self.triage = triage
        self.controlRuns = controlRuns
        self.projectPath = projectPath
        self.mutatedProjectPath = mutatedProjectPath
        self.sourceDigests = sourceDigests
        self.run = run
    }
}

extension MutationTestOutcome: Equatable {}

extension MutationTestOutcome {
    /// Whether a file's mutants may be missing from these results although the code is there: `--mutant`, `--shard`,
    /// `--sample` and `--since --changed-lines` test some of a file's mutants, and a run that stopped has tested only
    /// some. A plain `--since` tests whole files. `sampleIsCutShort` is set for any run that stopped, sampled or not.
    var leavesOutSomeMutants: Bool {
        mutant != nil || shards != nil || sample != nil || since?.changedLines == true || sampleIsCutShort
    }

    /// Why results whose `uncoveredMutants` aren't known make no baseline file, in a clause.
    static let uncoveredMutantsUnknown = "the results, of an older SwiftMutator or of a test plan it made, don't "
        + "record the mutants of code no test ran"

    /// Whether these results leave out mutants of a file they tested others of, and don't know which: those a shard,
    /// a sample or `--changed-lines` left out, when they aren't known (`unselectedMutants`). An entry of a baseline
    /// file is then compared only at its own key (`BaselineMatches`), as one for a mutant left out could take an
    /// identical one tested.
    var leavesOutUnknownMutants: Bool {
        unselectedMutants == nil && (shards != nil || sample != nil || since?.changedLines == true || sampleIsCutShort)
    }

    /// Why these results make no baseline file, which holds a whole run's survivors, in a clause: "the run tested
    /// only the files --since chose". nil for a whole run's. A plain `--since` and `--files-to-mutate` test whole
    /// files, but not every file, so an entry for a file they left out would be lost. Results that don't record the
    /// mutants of code no test ran (`uncoveredMutants`) would make a file without them, against which every one would
    /// be new.
    var whyNoBaselineFile: String? {
        if mutant != nil { return "the run tested one mutant (--mutant)" }
        if let shards { return "the results are only \(shards.named)'s" }
        if sample != nil { return "the run tested a sample (--sample)" }
        if since != nil { return "the run tested only the code --since chose" }
        if !filesToMutate.isEmpty { return "the run tested only the files --files-to-mutate chose" }
        if sampleIsCutShort { return "the run didn't test every mutant it discovered" }
        if uncoveredMutants == nil { return Self.uncoveredMutantsUnknown }
        return nil
    }
}

extension MutationTestOutcome {
    /// What a run ends with when some of its mutants were build errors, as those that don't compile are: they weren't
    /// tested, and neither the score nor a passing `--fail-under` says so. nil without any, and for one mutant's run,
    /// whose verdict says it.
    var buildErrorWarning: String? {
        let count = mutations.count { $0.testSuiteOutcome == .buildError }
        guard count > 0, mutant == nil else { return nil }
        return count == 1
            ? "1 mutant was a build error, so it wasn't tested, and the score leaves it out."
            : "\(count) mutants were build errors, so they weren't tested, and the score leaves them out."
    }

    /// What a run ends with when some of its kills' mutants never ran, as far as it tested them: another cause failed
    /// their tests, such as a flaky test or a crash at launch, and the score counts them as killed all the same. A
    /// stopped run may not have tested them again yet, which `--resume` does. nil without any, and for one mutant's
    /// run, whose log shows it.
    var unprovenKillWarning: String? {
        let count = mutations.count { [.failed, .runtimeError].contains($0.testSuiteOutcome) && $0.activated == false }
        guard count > 0, mutant == nil else { return nil }
        return count == 1
            ? "1 kill's code never ran, though its tests failed: a flaky test or a crash at launch may be to blame, "
            + "and the score counts it as killed. Its log is kept."
            : "\(count) kills' code never ran, though their tests failed: a flaky test or a crash at launch may be to "
            + "blame, and the score counts them as killed. Their logs are kept."
    }

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
        /// What identifies it across runs, as its results line records it, and `--mutant` takes it.
        let key: MutantKey?
        /// How long its run took, from launch to classification, to the millisecond, as its results line records it.
        let durationSeconds: Double?
        /// For a kill whose recorded tests include no property test: how the property tests alone came out with it on
        /// (`PropertyRerunResult`); nil when they weren't run again for it.
        var propertyRerun: PropertyRerun?
        /// Whether it was taken out of the build with others, as the compiler's error could be any of theirs
        /// (`LeftOutMutant.Blame`), so it may compile. As its results line records it.
        var leftOutWithOthers = false
        /// Whether its block ran in its run, as its results line records it (`TestRun.activated`); nil when that is
        /// unknown.
        var activated: Bool?
        /// Why its run was tested again, as its results line records it; nil for a first run.
        var rerun: MutantResult.Rerun?

        /// `killingTests`, `reusedFrom`, `key` and `durationSeconds` have no default: the run, `swift-mutator report`
        /// and `--resume` must each pass theirs.
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
            reusedFrom: ReusedFrom?,
            key: MutantKey?,
            durationSeconds: Double?
        ) {
            self.testSuiteOutcome = testSuiteOutcome
            point = mutationPoint
            snapshot = mutationSnapshot
            self.killingTests = killingTests
            self.reusedFrom = reusedFrom
            self.key = key
            self.durationSeconds = durationSeconds

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
        self.init(killedBy: failures?.tests, failedTestCount: failures?.total, endedBy: endedBy)
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
