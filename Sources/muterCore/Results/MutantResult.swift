import Foundation

/// One mutant's result: its key, how its run ended, and the tests that killed it. Only a run that wasn't cancelled
/// has one, so `endedBy` is never `cancelled`. A mutant taken out of the build, as it doesn't compile, has one with no
/// run: a `buildError` that `couldNotRun`, in no time on no worker (`leftOutOfTheBuild`).
struct MutantResult: Codable, Equatable {
    var kind = "mutant" // swiftlint:disable:this unused_declaration - results file key; Codable writes it
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
    @TrueOrAbsent var leftOutWithOthers = false
    /// Whether the mutant's block ran in this run (`TestRun.activated`): `ran` (true) if it did, `didNotRun` (false) if
    /// the run reached mutated code but not that block, which makes a `passed` run a mutant not covered. `unknown`
    /// (absent) when the run showed neither, as on a test host that can't write its marker, and on any line older than
    /// this key: nothing is known then. A run that tested the mutant again (`rerun`) records `didNotRun` for showing
    /// neither too, as its session showed that its runs can say.
    var activated: MutantActivation = .unknown

    var key: MutantKey {
        MutantKey(
            path: path,
            mutationOperatorId: mutationOperatorId,
            line: line,
            column: column,
            occurrence: occurrence
        )
    }

    /// The session that records a result, and when its run finished (`leftOutOfTheBuild`).
    struct Recording {
        let session: Int
        let finishedAt: Date
    }

    /// Where a job's mutant is in its file as SwiftMutator now prepares it, which a reused result is written for
    /// (`reused(from:headers:in:at:despiteChanges:keepingLog:)`).
    struct JobPlacement {
        /// The mutant's offset in the file (`utf8Offset`).
        let utf8Offset: Int
        /// The ID that switches it on (`switchID`).
        let switchID: String
    }

    /// The record of `schema`'s mutant, which didn't compile, so was taken out of the build, and whose tests never ran,
    /// as `recorded` records it. Its `log` says why.
    static func leftOutOfTheBuild(
        key: MutantKey,
        schema: MutationSchema,
        recorded: Recording,
        log: String,
        fileSHA256: String?
    ) -> Self {
        Self(
            session: recorded.session,
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
            finishedAt: recorded.finishedAt,
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

    /// `self`, recorded in the results file at `resultsFile` whose headers are `headers`, as the session `session`
    /// that reuses it writes it for the job at `placement`: the job's place in the file as SwiftMutator now prepares
    /// it, so the new file's report is the run's. The rest, how it was tested, is as
    /// recorded, and `reusedFrom` says where, and whether changes were let through since: by the sessions after its
    /// own, by an earlier reuse, or by the reusing session (`despiteChanges`). Unless `keepingLog`, it names no log, as
    /// the reusing session keeps none for it.
    func reused(
        from resultsFile: String,
        headers: [ResultsHeader],
        in session: Int,
        at placement: JobPlacement,
        despiteChanges: Bool,
        keepingLog: Bool = true
    ) -> Self {
        let later = headers.filter { $0.session > self.session }
        let origin = reusedFrom
        let letThrough = despiteChanges || origin?.despiteChanges == true
            || later.contains { !($0.waived ?? []).isEmpty || !($0.forced ?? []).isEmpty }
        var copy = Self(
            session: session,
            path: path,
            line: line,
            column: column,
            occurrence: occurrence,
            utf8Offset: placement.utf8Offset,
            mutationOperatorId: mutationOperatorId,
            switchID: placement.switchID,
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
        /// evidence is another file's (`Rerun.withoutEvidence`). A string, as `Rerun.because` is.
        let result: String?

        var identity: FailedTestLine.TestIdentity {
            .init(name: name, file: file)
        }
    }

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

        /// This rerun as a reuse keeps it: which tests failed first still measures their reach, but what they did alone
        /// was on code and tests that may since have changed, as a reused run's control runs are never counted.
        var withoutEvidence: Self {
            var copy = self
            copy.alone = alone?.map { .init(name: $0.name, file: $0.file, result: nil) }
            return copy
        }
    }
}
