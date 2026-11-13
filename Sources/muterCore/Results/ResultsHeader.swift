import Foundation

/// A session's first line: where its results came from, and what they were tested with. Written once the baseline
/// passes, so a run whose baseline fails writes a file of its own that says only why (`ResultsStopped`), and a resumed
/// one adds no session to its file. A resumed session with nothing left to test runs no baseline, and writes it at
/// once.
struct ResultsHeader: Codable, Equatable {
    var kind = "header"
    /// `ResultsCoding.formatVersion` for a first session, `resumedFormatVersion` for a resumed one, or
    /// `projectDeltaFormatVersion` for a resumed one that records `projectDelta`; `omittedLogsFormatVersion` for any
    /// session whose `mutant` lines may have no `log`.
    let formatVersion: Int
    /// 1 for a run's first session; each resumed session adds the next to the same file.
    let session: Int
    /// When mutation testing started, which the session's test duration is measured from.
    let startedAt: Date
    let provenance: Provenance
    /// The configuration as loaded, under its own keys: not the effective one, which `timeoutSeconds`,
    /// `stopsAtFirstFailure` and `failedTestLinesAreReliable` describe.
    let configuration: MuterConfiguration
    /// The operators asked for, by name, sorted.
    let operators: [String]
    let filesToMutate: [String]
    let skipCoverage: Bool
    let usingTestPlan: Bool
    let projectPath: String
    let mutatedProjectPath: String
    /// The folder of the session's kept logs, which each of its mutants' `log` names a file in, when the mutant kept
    /// one. A resumed session has a folder of its own; the results file stays in the first session's.
    let logDirectory: String
    /// Absent when the run has no coverage, as its report then shows none.
    let coverage: CoverageSummary?
    /// The newer SwiftMutator version the update check found, or "", which the HTML report shows.
    let newVersion: String
    /// How long the baseline run took; nil when a resumed session had nothing left to test, and ran none.
    let baselineSeconds: Double?
    /// How long one run of a mutant's test command took with no mutant on, which the default time limit is based on;
    /// nil when none was timed: a time limit was configured, the build system is neither SwiftPM nor xcodebuild, the
    /// run didn't pass, or a resumed session had nothing left to test.
    let testRunSeconds: Double?
    /// The time limit for a mutant's run: the configured one, or else the default that the timed test run, or else the
    /// baseline, set, if one ran.
    let timeoutSeconds: Double?
    let timeoutIsDefault: Bool
    let workers: Int
    let stopsAtFirstFailure: Bool
    let failedTestLinesAreReliable: Bool
    /// The tests that lines of the passing baseline, or of an xcodebuild worker's check run, showed failing, which no
    /// mutant's `killedBy` names: those lines are the tests' own text. Sorted; absent when there are none.
    var failedTestLookalikes: [FailedTestLine.TestIdentity]?
    let mutantsDiscovered: Int
    let mutantsToTest: Int
    /// How many mutants discovery found and can't test, as their switches have nowhere to go, or an `#if` leaves their
    /// code out of the build; absent when none. Of all the code discovery looked at, with `--sample` and `--shard` too.
    var mutantsDropped: Int?
    /// The project's files, as the mutated copy held them before discovery rewrote it. In a session that tested a
    /// test plan, which copies nothing, the plan's copy as it was tested: rewritten, and with any fix made by hand,
    /// which a resume of its run compares the copy with. Absent from a session that an earlier SwiftMutator ran on a
    /// test plan. A resumed session's header records `projectDelta` in its place, from which a header read from a
    /// results file gets it again (`RecordedResults`).
    var project: ProjectTree?
    /// Only in a resumed session whose last session recorded a tree: its tree as what changed since that one, in
    /// place of `project`.
    var projectDelta: ProjectTreeDelta?
    /// Only in a resumed session, or one that reuses an earlier run's results: how many earlier results it kept rather
    /// than tested again.
    let mutantsReused: Int?
    /// Only in a resumed session, or one that reuses: the changed project files `--resume-ignoring` or
    /// `--reuse-ignoring` let through, by their paths.
    let waived: [String]?
    /// Only in a resumed session, or one that reuses: the build and toolchain differences `--force-resume` or
    /// `--force-reuse` let through, by their names in `provenance`.
    let forced: [String]?
    /// Only when mutants' tests ran without `swift test`, each test bundle started directly (see `DirectTestRun`).
    @TrueOrAbsent var testBundlesRunDirectly = false
    /// Only in a session that reuses an earlier run's results (`--reuse`): that run's results file. The results it
    /// kept follow the header, each with its `reusedFrom`.
    var reusedFrom: String?
    /// Only in a session run with `--since`: the files, and with `--changed-lines` the lines, it chose.
    var since: ChangeSelection?
    /// Only in a session run with `--shard`: which shard it tested, and what discovery found in every shard.
    /// `mutantsDiscovered` and `mutantsToTest` count this shard's mutants.
    var shard: ShardSelection?
    /// Only in a session run with `--sample`: the sample asked for, and how many mutants it held of how many were
    /// discovered. `mutantsDiscovered` and `mutantsToTest` count the sample's, or with `--shard` too, the shard's part
    /// of it.
    var sample: SampleSelection?
    /// Only in a session that tested a test plan: the plan it tested, which a resume of its run must test too.
    var testPlan: TestPlanRecord?
    /// Only in a session run with `--mutant`: the key of the one mutant it tested, as `MutantKey.description` gives it.
    /// No other run resumes or reuses its results, and its score isn't the project's.
    var mutant: String?
    /// The mutants of code no test ran, which the session made none of, of the code it chose (`UncoveredMutant`),
    /// sorted by key, which a baseline file records as survivors not covered, and `--baseline` compares; empty when
    /// there are none. Absent with `skipCoverage`, which has none, and when the session doesn't know them: in a session
    /// of one mutant, in one of a test plan that doesn't record them, and in any an older SwiftMutator wrote. Without
    /// `skipCoverage`, absent isn't none: `report` then writes no baseline file, and says so. A resumed session
    /// discovers them again.
    var mutantsNotCovered: [UncoveredMutant]?

    /// The session's mutants of code no test ran, as `mutantsNotCovered` records them: none with `skipCoverage`, and
    /// nil when the session doesn't record them, which isn't to say it has none.
    var knownMutantsNotCovered: [UncoveredMutant]? {
        mutantsNotCovered ?? (skipCoverage ? [] : nil)
    }
}
