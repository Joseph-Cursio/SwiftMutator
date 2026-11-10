import Foundation

/// How a results file's lines are written and read: JSON Lines, one record per line, each with a `kind`.
enum ResultsCoding {
    /// A first session's header's format. A format changes only for a change that a reader of the earlier one would
    /// misread. A new key, or a new kind a reader can skip, needs none: readers ignore keys and skip kinds they don't
    /// know.
    static let formatVersion = 1
    /// A resumed session's header's format: its file holds `retired` lines, which a format-1 reader would skip, so it
    /// would report results the run no longer stands by. A file that was never resumed stays in format 1, which older
    /// SwiftMutators read.
    static let resumedFormatVersion = 2
    /// A resumed session's header that records its project tree as what changed since the last session's
    /// (`ResultsHeader.projectDelta`). A format-2 reader would take it for a session with no tree, which `--reuse` and
    /// a merge of shards skip, rather than check.
    static let projectDeltaFormatVersion = 3
    /// A session's header whose `mutant` lines may have no `log`, as a mutant killed by a failed test its line names
    /// keeps none unless `keepAllLogs` is set. A format-3 reader would skip those lines, as it can't read them, and
    /// lose their results. A session that writes a `log` on every line keeps to the formats above.
    static let omittedLogsFormatVersion = 4
    /// The newest format this SwiftMutator reads. It refuses a file with a header in a newer one.
    static let newestFormatVersion = omittedLogsFormatVersion

    /// Sorted keys, so lines read and compare alike; slashes unescaped, so paths read as paths; never pretty-printed,
    /// so a record is one line, any line break in it escaped. Dates are ISO 8601 in UTC, to the millisecond.
    static var encoder: JSONEncoder {
        let lineEncoder = JSONEncoder()
        lineEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        lineEncoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(text(of: date))
        }
        return lineEncoder
    }

    /// Reads dates as `encoder` writes them, or without fractional seconds.
    static var decoder: JSONDecoder {
        let lineDecoder = JSONDecoder()
        lineDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return lineDecoder
    }

    /// Every line's first question: what kind of record it is.
    struct Kind: Decodable {
        let kind: String
    }

    /// `date` in UTC to the nearest millisecond, `2026-10-04T13:16:04.512Z`. Rounded here rather than by
    /// `ISO8601FormatStyle`, which truncates: a date read back from `.004` is a hair under it, and would be written
    /// back as `.003`.
    private static func text(of date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        let seconds = (milliseconds / 1_000).rounded(.down)
        let time = utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: seconds)
        )
        return String(
            format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld.%03ldZ",
            time.year ?? 0,
            time.month ?? 0,
            time.day ?? 0,
            time.hour ?? 0,
            time.minute ?? 0,
            time.second ?? 0,
            Int(milliseconds - seconds * 1_000)
        )
    }

    private static func date(from text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar
    }()
}

/// A run's coverage, as its report shows it.
struct CoverageSummary: Codable, Equatable {
    let percent: Int
    let filesWithoutCoverage: [String]
}

extension CoverageSummary {
    /// The summary of `coverage`; nil when the run has none, as when coverage couldn't be gathered.
    init?(_ coverage: Coverage) {
        guard coverage != .null else { return nil }
        self.init(percent: coverage.percent, filesWithoutCoverage: coverage.filesWithoutCoverage)
    }
}

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
    var testBundlesRunDirectly: Bool?
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
}

extension ResultsHeader {
    /// The session's mutants of code no test ran, as `mutantsNotCovered` records them: none with `skipCoverage`, and
    /// nil when the session doesn't record them, which isn't to say it has none.
    var knownMutantsNotCovered: [UncoveredMutant]? {
        mutantsNotCovered ?? (skipCoverage ? [] : nil)
    }
}

/// The test plan a session tested: the path it was read from, absolute, the SHA-256 of its bytes, and which format and
/// SwiftMutator it was written in. A plan made again, or edited, has another SHA-256.
struct TestPlanRecord: Codable, Equatable {
    let path: String
    let sha256: String
    let formatVersion: Int
    /// Absent for a plan in format 0, which doesn't say.
    let swiftMutatorVersion: String?
}

extension TestPlanRecord {
    init(_ plan: LoadedTestPlan) {
        self.init(
            path: plan.path,
            sha256: plan.sha256,
            formatVersion: plan.formatVersion,
            swiftMutatorVersion: plan.swiftMutatorVersion
        )
    }
}

extension ResultsHeader {
    /// The header of a session that tests `state`'s mutants with `configuration`, the effective configuration: the
    /// default time limit applied, and failed-test lines judged by the baseline. `logDirectory` is the session's. A
    /// session after the first is a resumed one, which says what it reused, and what `--resume-ignoring` and
    /// `--force-resume` let through. It records its project tree as what changed since the last session's, in
    /// `ResultsCoding.projectDeltaFormatVersion`, or, when that session recorded none, in full, in
    /// `resumedFormatVersion`. A session that reuses an earlier run's results is a first session, which says the same,
    /// and the file it reused from. A session whose `mutant` lines may have no `log` is in `omittedLogsFormatVersion`,
    /// whichever session it is: one that tests mutants, but for `--mutant`'s one, without `keepAllLogs`, and one that
    /// copies reused results with no `log`, `copyingLinesWithoutLogs`.
    init(
        session: Int,
        startedAt: Date,
        state: AnyMutationTestState,
        logDirectory: String,
        configuration: MuterConfiguration,
        baselineSeconds: Double?,
        testRunSeconds: Double? = nil,
        workers: Int,
        mutantsDiscovered: Int,
        mutantsToTest: Int,
        provenance: Provenance,
        mutantsReused: Int? = nil,
        waived: [String]? = nil,
        forced: [String]? = nil,
        reusedFrom: String? = nil,
        copyingLinesWithoutLogs: Bool = false
    ) {
        let lastTree = session == 1 ? nil : state.resumeState?.lastHeader.project
        let projectDelta = state.projectTree.flatMap { tree in
            lastTree.map { ProjectTreeDelta(from: $0, to: tree) }
        }
        let omitsLogs = copyingLinesWithoutLogs
            || mutantsToTest > 0 && state.selectedMutant == nil && !state.muterConfiguration.keepsAllLogs
        let formatVersion = if omitsLogs {
            ResultsCoding.omittedLogsFormatVersion
        } else if session == 1 {
            ResultsCoding.formatVersion
        } else {
            projectDelta == nil ? ResultsCoding.resumedFormatVersion : ResultsCoding.projectDeltaFormatVersion
        }
        self.init(
            formatVersion: formatVersion,
            session: session,
            startedAt: startedAt,
            provenance: provenance,
            configuration: state.muterConfiguration,
            operators: state.mutationOperatorList.map(\.rawValue).sorted(),
            filesToMutate: state.filesToMutate,
            skipCoverage: state.runOptions.skipCoverage,
            usingTestPlan: state.runOptions.isUsingTestPlan,
            projectPath: state.projectDirectoryURL.path,
            mutatedProjectPath: state.mutatedProjectDirectoryURL.path,
            logDirectory: logDirectory,
            coverage: CoverageSummary(state.projectCoverage),
            newVersion: state.newVersion,
            baselineSeconds: baselineSeconds,
            testRunSeconds: testRunSeconds,
            timeoutSeconds: configuration.testSuiteTimeout,
            timeoutIsDefault: state.muterConfiguration.testSuiteTimeout == nil,
            workers: workers,
            stopsAtFirstFailure: configuration.stopsAtFirstFailure,
            failedTestLinesAreReliable: configuration.failedTestLinesAreReliable,
            failedTestLookalikes: configuration.failedTestLookalikes.isEmpty
                ? nil : configuration.failedTestLookalikes.sorted(),
            mutantsDiscovered: mutantsDiscovered,
            mutantsToTest: mutantsToTest,
            mutantsDropped: state.droppedMutants.isEmpty ? nil : state.droppedMutants.count,
            project: projectDelta == nil ? state.projectTree : nil,
            projectDelta: projectDelta,
            mutantsReused: mutantsReused,
            waived: waived,
            forced: forced,
            testBundlesRunDirectly: configuration.directTestRun == nil ? nil : true,
            reusedFrom: reusedFrom,
            since: state.changeSelection,
            shard: state.shardSelection,
            sample: state.sampleSelection,
            testPlan: state.testPlan.map(TestPlanRecord.init),
            mutant: state.selectedMutant?.description,
            mutantsNotCovered: state.runOptions.skipCoverage ? nil : state.uncoveredMutants
        )
    }
}

/// One mutant's result: its key, how its run ended, and the tests that killed it. Only a run that wasn't cancelled
/// has one, so `endedBy` is never `cancelled`. A mutant taken out of the build, as it doesn't compile, has one with no
/// run: a `buildError` that `couldNotRun`, in no time on no worker (`leftOutOfTheBuild`).
struct MutantResult: Codable, Equatable {
    var kind = "mutant"
    let session: Int
    /// The key's fields (`MutantKey`).
    let path: String
    let line: Int
    let column: Int
    let occurrence: Int
    /// The mutant's offset in the file as SwiftMutator prepared it.
    let utf8Offset: Int
    let mutationOperatorId: MutationOperator.Id
    /// `MutationSchema.id`, the ID that switched the mutant on: under `swift test`, the contents of the worker's
    /// active-mutant file; otherwise an environment variable of that name. Never a key.
    let switchID: String
    let snapshot: MutationOperator.Snapshot
    let outcome: TestSuiteOutcome
    let endedBy: TestRun.Ending
    /// Only for an `exited` run: its exit code, or the signal that ended it.
    let exitStatus: Int32?
    /// From launch to classification, to the millisecond.
    let durationSeconds: Double
    /// For SwiftPM, 0 is the mutated project, n is its clone `<project>_mutated_worker<n>.noindex`; for xcodebuild, n
    /// is the worker whose simulator, `.xctestrun` and derived data its run used.
    let worker: Int
    let finishedAt: Date
    /// For a killed, crashed or timed-out mutant: the tests its log shows failing, each once, in the order they first
    /// failed, at most `FailedTestLine.killedByLimit`, but for the header's `failedTestLookalikes`. The list is
    /// complete when `endedBy` is `exited` and `failedTestCount` is its length.
    let killedBy: [FailedTestLine.FailedTest]?
    /// How many distinct tests its log shows failing, uncapped.
    let failedTestCount: Int?
    /// The first line that shows one, without colour codes, capped.
    let firstFailedTestLine: String?
    /// The kept log's file name in the session's `logDirectory`. Absent for a mutant killed by a failed test its line
    /// names, whose `killedBy` and `firstFailedTestLine` stand in for its log, unless `keepAllLogs` is set or the run
    /// is `--mutant`'s (`MutationTestLog.isKept`); only in format 4 (`ResultsCoding.omittedLogsFormatVersion`).
    let log: String?
    /// SHA-256 of the mutant's original file.
    let fileSHA256: String?
    /// Only for a result a session reused from an earlier run's results file (`--reuse`) rather than tested: where it
    /// was tested. Its `session` is the reusing session's, and its `log` names the copy of its log in that session's
    /// `logDirectory`.
    var reusedFrom: ReusedFrom?
    /// On the line of a run that tested the mutant again in the same session, after the line of its first run, which
    /// it replaces as every later line of a key does: why, and at what load. Its `log` is a log of its own
    /// (`MutationTestLog.rerunFileName(for:)`, or `suspectRerunFileName(for:)` for a kill tested again alone). A result
    /// reused from such a line keeps it, with `reusedFrom`, though
    /// the reusing session didn't run the mutant.
    var rerun: Rerun?
    /// True on the line of a mutant taken out of the build with others (`LeftOutMutant.Blame`), as the compiler's error
    /// could be any of theirs, so it may compile: `--fail-under` counts it as not killed. Absent otherwise.
    var leftOutWithOthers: Bool?
    /// Whether the mutant's block ran in this run (`TestRun.activated`): true if it did, false if the run reached
    /// mutated code but not that block, which makes a `passed` run a mutant not covered. Absent when the run showed
    /// neither, as on a test host that can't write its marker, and on any line older than this key: nothing is known
    /// then. A run that tested the mutant again (`rerun`) records false for showing neither too, as its session showed
    /// that its runs can say.
    var activated: Bool?

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

extension MutantResult {
    /// The record of `schema`'s mutant, which didn't compile, so was taken out of the build, and whose tests never ran.
    /// Its `log` says why.
    static func leftOutOfTheBuild(
        key: MutantKey,
        schema: MutationSchema,
        session: Int,
        finishedAt: Date,
        log: String,
        fileSHA256: String?
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
            outcome: .buildError,
            endedBy: .couldNotRun,
            exitStatus: nil,
            durationSeconds: 0,
            worker: 0,
            finishedAt: finishedAt,
            killedBy: nil,
            failedTestCount: nil,
            firstFailedTestLine: nil,
            log: log,
            fileSHA256: fileSHA256
        )
    }

    /// `seconds` to the millisecond, as a results line records a run's duration.
    static func recordedSeconds(_ seconds: Double) -> Double {
        (seconds * 1_000).rounded() / 1_000
    }
}

extension MutantResult {
    /// The record of `finished`, the run of `schema`'s mutant, whose log showed `failures` failing
    /// (`failedTests(of:ignoring:)`).
    init(
        key: MutantKey,
        schema: MutationSchema,
        finished: FinishedRun,
        failures: FailedTestLine.FailedTests?,
        session: Int,
        finishedAt: Date,
        log: String?,
        fileSHA256: String? = nil,
        rerun: Rerun? = nil
    ) {
        let run = finished.run
        self.init(
            session: session,
            path: key.path,
            line: key.line,
            column: key.column,
            occurrence: key.occurrence,
            utf8Offset: schema.position.utf8Offset,
            mutationOperatorId: schema.mutationOperatorId,
            switchID: schema.id,
            snapshot: schema.snapshot,
            outcome: run.outcome,
            endedBy: run.ending,
            exitStatus: run.ending == .exited ? run.exitStatus : nil,
            durationSeconds: Self.recordedSeconds(finished.seconds),
            worker: finished.worker,
            finishedAt: finishedAt,
            killedBy: failures?.tests,
            failedTestCount: failures?.count,
            firstFailedTestLine: failures?.firstLine,
            log: log,
            fileSHA256: fileSHA256,
            rerun: rerun
        )
        activated = run.activated
    }

    /// The tests a killed, crashed or timed-out run's log shows failing, but for `lookalikes`: those a passing
    /// baseline's lines showed failing, as such lines are the tests' own text, printed whatever the mutant. nil for
    /// any other run.
    static func failedTests(
        of run: TestRun,
        ignoring lookalikes: Set<FailedTestLine.TestIdentity> = []
    ) -> FailedTestLine.FailedTests? {
        guard [.failed, .runtimeError, .timeout].contains(run.outcome) else { return nil }
        return FailedTestLine.failedTests(inLog: run.testLog, ignoring: lookalikes)
    }
}

extension MutantResult {
    /// Why a session tested a mutant again, after its first run, and how many mutants it tested at once meanwhile.
    struct Rerun: Codable, Equatable {
        /// A first run that timed out: under the load of every worker, a slow test can pass the limit that it keeps
        /// to under less.
        static let timeout = "timeout"
        /// A first run that failed or timed out without showing its mutant's block ran, in a session whose other runs
        /// show they can: a flaky test or a crash at launch may have failed it.
        static let codeNotShownRunning = "codeNotShownRunning"
        /// A first run that failed with only suspect tests naming it, or with one a test too few other kills name, for
        /// finding out which: a kill a test really makes fails again alone, and one a flaky test made mostly doesn't.
        static let onlySuspectTestsFailed = "onlySuspectTestsFailed"

        /// Why, such as `timeout`. A string, not an enum, so that a reason a later SwiftMutator adds doesn't make the
        /// line unreadable: a reader would skip it, and the first run's result would stand in its place.
        let because: String
        /// How many mutants were tested at once while it was tested again.
        let workers: Int
        /// For `onlySuspectTestsFailed`: the tests that failed in the first run, whose line this one replaces, and what
        /// this run's log shows of each. So how far a test reaches is measured on first runs alone, and every report
        /// can tell what the rerun said from the results file.
        var alone: [TestAlone]?

        /// A test that failed in a mutant's first run, and what it did when the mutant was tested again alone.
        struct TestAlone: Codable, Equatable {
            /// It failed again, with the mutant's code shown running or showing nothing.
            static let failedAgain = "failedAgain"
            /// Its line shows it passing, or the whole run passed.
            static let passed = "passed"
            /// It failed again though the mutant's code didn't run, so it doesn't fail for the mutant.
            static let failedWithItsCodeNotRunning = "failedWithItsCodeNotRunning"

            let name: String
            let file: String?
            /// nil when the log shows nothing of it, as a crash or a time limit may leave it, or when the rerun's
            /// evidence is another file's (`withoutEvidence`). A string, as `because` is.
            let result: String?

            var identity: FailedTestLine.TestIdentity {
                .init(name: name, file: file)
            }
        }

        /// This rerun as a reuse keeps it: which tests failed first still measures their reach, but what they did alone
        /// was on code and tests that may since have changed, as a reused run's control runs are never counted.
        var withoutEvidence: Self {
            var copy = self
            copy.alone = alone?.map { .init(name: $0.name, file: $0.file, result: nil) }
            return copy
        }
    }
}

/// Where a result that a session reused from an earlier run's results file (`--reuse`) was tested, and whether changes
/// were let through on the way: by the reusing session, by any session that resumed the run after it was tested, or by
/// an earlier reuse of it. Each of those sessions' headers says which (`waived`, `forced`).
struct ReusedFrom: Codable, Equatable {
    /// The results file it was tested in, and the session there that tested it.
    let resultsFile: String
    let session: Int
    /// true if `--resume-ignoring`, `--reuse-ignoring`, `--force-resume` or `--force-reuse` let a change through since
    /// it was tested, which the reports mark; absent otherwise.
    let despiteChanges: Bool?

    init(resultsFile: String, session: Int, despiteChanges: Bool) {
        self.resultsFile = resultsFile
        self.session = session
        self.despiteChanges = despiteChanges ? true : nil
    }

    /// Whether a change was let through since it was tested.
    var keptDespiteChanges: Bool {
        despiteChanges == true
    }
}

extension MutantResult {
    /// `self`, recorded in the results file at `resultsFile` whose headers are `headers`, as the session `session`
    /// that reuses it writes it for the job at `utf8Offset` with `switchID`: the job's place in the file as
    /// SwiftMutator now prepares it, so the new file's report is the run's. The rest, how it was tested, is as
    /// recorded, and `reusedFrom` says where, and whether changes were let through since: by the sessions after its
    /// own, by an earlier reuse, or by the reusing session (`despiteChanges`). Unless `keepingLog`, it names no log, as
    /// the reusing session keeps none for it.
    func reused(
        from resultsFile: String,
        headers: [ResultsHeader],
        in session: Int,
        utf8Offset: Int,
        switchID: String,
        despiteChanges: Bool,
        keepingLog: Bool = true
    ) -> MutantResult {
        let later = headers.filter { $0.session > self.session }
        let origin = reusedFrom
        let letThrough = despiteChanges || origin?.keptDespiteChanges == true
            || later.contains { !($0.waived ?? []).isEmpty || !($0.forced ?? []).isEmpty }
        var copy = MutantResult(
            session: session,
            path: path,
            line: line,
            column: column,
            occurrence: occurrence,
            utf8Offset: utf8Offset,
            mutationOperatorId: mutationOperatorId,
            switchID: switchID,
            snapshot: snapshot,
            outcome: outcome,
            endedBy: endedBy,
            exitStatus: exitStatus,
            durationSeconds: durationSeconds,
            worker: worker,
            finishedAt: finishedAt,
            killedBy: killedBy,
            failedTestCount: failedTestCount,
            firstFailedTestLine: firstFailedTestLine,
            log: keepingLog ? log : nil,
            fileSHA256: fileSHA256,
            rerun: rerun?.withoutEvidence
        )
        copy.activated = activated
        copy.reusedFrom = ReusedFrom(
            resultsFile: origin?.resultsFile ?? resultsFile,
            session: origin?.session ?? self.session,
            despiteChanges: letThrough
        )
        return copy
    }
}

/// The keys of earlier sessions' results that a resumed session no longer stands by: those of the mutants it tests
/// again, of those its discovery no longer finds, and of those its sample no longer takes. A reader drops each key's
/// records before this line; a mutant line after it records the key again.
struct ResultsRetired: Codable, Equatable {
    var kind = "retired"
    let session: Int
    let keys: [MutantKey]
}

/// A session's last line, written when mutation testing stops however it can. A run killed by SIGKILL, or that
/// crashed, has none.
struct ResultsEnd: Codable, Equatable {
    enum Reason: String, Codable {
        case finished
        case aborted
        case interrupted
    }

    var kind = "end"
    let session: Int
    let endedAt: Date
    let reason: Reason
    /// Why it stopped early: the stopping signal's name (`"SIGINT"`) for an interruption a signal caused, or else a
    /// short code (`detail(for:)`).
    let detail: String?
    /// How long this session's mutation testing took. For a first session, exactly its `MutationTestOutcome`'s
    /// `testDuration`; a resumed session's outcome adds the earlier sessions'.
    let testDurationSeconds: Double
    /// How many mutant lines the session wrote: those of the mutants it tested, those of the mutants it took out of the
    /// build, which have no run behind them, those of the mutants it tested again, which have `rerun`, and in a session
    /// that reuses an earlier run's results, those of the results it kept, which have `reusedFrom`, and `rerun` too if
    /// a rerun gave them.
    let recorded: Int

    /// A short code for why mutation testing stopped with `error`, never a log: the abort reason's kind
    /// (`MutationTestingAbortReason.Kind`), with the worker or control run it names, or else the error's type. None
    /// for a cancellation, which `interrupted` says.
    static func detail(for error: Error) -> String? {
        if error is CancellationError {
            return nil
        }
        guard case let MuterError.mutationTestingAborted(reason) = error else {
            return String(describing: type(of: error))
        }
        let code = reason.kind.rawValue
        switch reason {
        case let .workerBaselineTestFailed(worker, _, _), let .simulatorUnavailable(worker, _, _),
             let .buildTimeoutReached(.workerBaseline(worker, _), _, _, _):
            return "\(code)(worker: \(worker))"

        case let .controlRunNotSwitchedOff(number, _):
            return "\(code)(number: \(number))"

        case .baselineTestFailed, .buildForTestingFailed, .buildTimeoutReached, .tooManyBuildErrors,
             .mutantNotSwitchedOn, .noMutantCodeShownRunning, .unknownError:
            return code
        }
    }
}
