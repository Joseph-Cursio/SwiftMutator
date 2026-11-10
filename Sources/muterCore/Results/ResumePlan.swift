import Foundation

/// Which of a results file's results a resumed run keeps, and which of its jobs it tests. A recorded result is kept
/// for the job with its key only if that key's place and operator appear once in this run's discovery, it isn't a
/// build error, its file's hash is this run's, its mutation is the job's, and it isn't a timeout of a session that
/// tested more than one mutant at once and never tested it again at lower load, nor one under a shorter time limit
/// than this run's. A run that reuses an earlier run's
/// results (`--reuse`) keeps one only if, as well, it isn't a timeout, and what changed since leaves it standing
/// (`ReuseChanges`). Every other job is tested, counted by why. A mutant's `switchID` and `utf8Offset` are never
/// compared: both count the header and import SwiftMutator inserts, so they change with how it prepares the file, and
/// an edit of the file changes its hash anyway.
struct ResumePlan: Equatable {
    /// Why a job is tested.
    enum Reason: String, CaseIterable {
        /// No result of its key is recorded, or a `retired` line retired it.
        case notRecorded
        /// Its result was a build error, as every run that couldn't start is, and every mutant that didn't compile:
        /// resuming is how to try it again.
        case buildError
        /// Its file's hash isn't the one its result recorded, or one of them is missing.
        case fileChanged
        /// Its file is the same, but the mutation SwiftMutator makes there isn't.
        case mutationChanged
        /// Its place and operator appear more than once in this run's discovery, so its repeats share a switch ID and
        /// no result of theirs can be trusted.
        case repeated
        /// A resume: it timed out in a session that tested more than one mutant at once, which stopped before it
        /// tested the timeout again at lower load, or was older than that.
        case timeoutNotRerun
        /// A resume: it timed out under a shorter time limit than this run's, which `ResumeCheck` let through.
        case timeoutUnderShorterLimit
        /// A reuse: it timed out, which a run under less load may not.
        case timedOut
        /// Its run failed or timed out without its mutant's block running, and its session stopped before it tested it
        /// again.
        case codeNotShownRunning
        /// Its session stopped as none of its runs showed they read the mutants' switches, so nothing it recorded
        /// says anything of the mutant.
        case sessionShowedNoCodeRunning
        /// A reuse: a project file other than a test file changed, and no `--reuse-ignoring` glob let it through.
        case otherFileChanged
        /// A reuse: test files changed, and it survived, or no unchanged test that killed it still holds.
        case testsChanged
    }

    /// The results kept, by job index.
    let reused: [Int: MutantResult]
    /// The indices of the jobs to test, in job order.
    let toRun: [Int]
    /// How many of `toRun` are tested for each reason; a reason with none is absent.
    let retestedBecause: [Reason: Int]
    /// Every recorded key whose result isn't kept, sorted: those of the jobs tested again, those of mutants this run's
    /// discovery no longer finds, and those of mutants its sample leaves out. A resumed session's `retired` line lists
    /// them.
    let retired: [MutantKey]
    /// How many of `retired` are of mutants this run's discovery no longer finds: their results are dropped, and no
    /// job tests them again.
    let noLongerDiscovered: Int
    /// How many of `retired` are of mutants this run's discovery finds, but its sample leaves out, as when new mutants
    /// rank before them after a change: their results are dropped, and no job tests them.
    var outsideTheSample = 0

    /// This plan, without the jobs to test that `isLeftOut`, by index, as they aren't in the build. Only for what is to
    /// be tested: its results file records them, so the header and a resume's summary go by the whole plan.
    func leavingOut(_ isLeftOut: (Int) -> Bool) -> Self {
        Self(
            reused: reused,
            toRun: toRun.filter { !isLeftOut($0) },
            retestedBecause: retestedBecause,
            retired: retired,
            noLongerDiscovered: noLongerDiscovered,
            outsideTheSample: outsideTheSample
        )
    }

    /// The plan for the jobs whose keys are `keys` and whose mutations are `snapshots`, one each in job order, given
    /// the results file's `recorded` results (`RecordedResults.latest`) and the hashes of this run's project files by
    /// their paths relative to the project (`ProjectTree.files`), as keys' paths are. A reuse passes what changed since
    /// each of the file's sessions, by session: a result is judged by what changed since the session that recorded it.
    /// A resume passes how many workers each session tested on (`workers(of:)`), which says whether its timeouts were
    /// tested again, and the time limit each tested under (`limits(of:)`) with this run's configured one, `limit`, so
    /// that a longer one tests the timeouts again. A sampled run passes the keys of the mutants its sample leaves out
    /// (`leftOut`).
    static func make(
        keys: [MutantKey],
        snapshots: [MutationOperator.Snapshot],
        recorded: [MutantKey: MutantResult],
        fileHashes: [String: String],
        workers: [Int: Int] = [:],
        limits: [Int: Double] = [:],
        limit: Double? = nil,
        reusing changes: [Int: ReuseChanges]? = nil,
        leftOut: Set<MutantKey> = [],
        sessionsShowingNoCode: Set<Int> = []
    ) -> Self {
        let places = Dictionary(keys.map { (Place($0), 1) }, uniquingKeysWith: +)
        let sessionsShowingActivation = Set(recorded.values.filter { $0.activated != .unknown }.map(\.session))
        var keptResults: [Int: MutantResult] = [:]
        var indicesToRun: [Int] = []
        var reasons: [Reason: Int] = [:]
        for (index, key) in keys.enumerated() {
            let reason: Reason?
            if places[Place(key)] != 1 {
                reason = .repeated
            } else if let record = recorded[key] {
                // A reuse tests every timeout again, a resume those its session didn't, or tested under a shorter
                // limit.
                reason = reasonToRetest(record, fileHash: fileHashes[key.path], snapshot: snapshots[index])
                    ?? reasonToRetest(
                        record,
                        showingNoCodeIn: sessionsShowingNoCode,
                        showingActivation: sessionsShowingActivation
                    )
                    ?? (changes.map { reasonToRetest(record, after: $0[record.session]) }
                        ?? reasonToRetest(
                            record,
                            testedOn: workers[record.session],
                            under: limits[record.session],
                            now: limit
                        ))
                if reason == nil {
                    keptResults[index] = record
                }
            } else {
                reason = .notRecorded
            }
            if let reason {
                indicesToRun.append(index)
                reasons[reason, default: 0] += 1
            }
        }
        let kept = Set(keptResults.keys.map { keys[$0] })
        let discovered = Set(keys)
        return Self(
            reused: keptResults,
            toRun: indicesToRun,
            retestedBecause: reasons,
            retired: recorded.keys.filter { !kept.contains($0) }.sorted { $0.description < $1.description },
            noLongerDiscovered: recorded.keys.count { !discovered.contains($0) && !leftOut.contains($0) },
            outsideTheSample: recorded.keys.count { leftOut.contains($0) }
        )
    }

    /// Every job, as a run that isn't resumed tests them: nothing is reused, tested again or retired.
    static func everything(_ count: Int) -> Self {
        Self(reused: [:], toRun: Array(0..<count), retestedBecause: [:], retired: [], noLongerDiscovered: 0)
    }

    /// Why `record`, recorded for a job whose key appears once, doesn't hold for it, given its file's hash and its
    /// mutation now; nil if it holds. A record without a hash never holds, even if this run can't hash its file
    /// either: nothing shows the file is the same.
    private static func reasonToRetest(
        _ record: MutantResult,
        fileHash: String?,
        snapshot: MutationOperator.Snapshot
    ) -> Reason? {
        if record.outcome == .buildError {
            return .buildError
        }
        if record.fileSHA256 == nil || record.fileSHA256 != fileHash {
            return .fileChanged
        }
        if record.snapshot != snapshot {
            return .mutationChanged
        }
        return nil
    }

    /// Why neither a resume nor a reuse keeps `record`, whose file is unchanged, as what it says of its mutant's run
    /// doesn't hold: its session stopped as no run showed anything (`showingNoCode`), or stopped before it tested again
    /// a run that failed without showing its block ran. A line with no `activated` is such a run only in a session
    /// that `showingActivation` names; in any other it predates the key or can't show it, and stands.
    private static func reasonToRetest(
        _ record: MutantResult,
        showingNoCodeIn sessions: Set<Int>,
        showingActivation: Set<Int>
    ) -> Reason? {
        guard record.reusedFrom == nil else { return nil }
        if sessions.contains(record.session) {
            return .sessionShowedNoCodeRunning
        }
        guard [.failed, .runtimeError, .timeout].contains(record.outcome), record.rerun == nil else { return nil }
        let unproven = record.activated == .didNotRun
            || record.activated == .unknown && showingActivation.contains(record.session)
        return unproven ? .codeNotShownRunning : nil
    }

    /// The sessions of `sessions`, a results file's, that stopped as none of their runs showed they read the mutants'
    /// switches.
    static func showingNoCode(_ sessions: [RecordedResults.Session]) -> Set<Int> {
        let code = MutationTestingAbortReason.Kind.noMutantCodeShownRunning.rawValue
        return Set(sessions.filter { $0.end?.detail == code }.map(\.header.session))
    }

    /// The workers of each session in `headers`, a results file's, by its number: the last header's of a number, as
    /// `RecordedResults` reads a session's records with it.
    static func workers(of headers: [ResultsHeader]) -> [Int: Int] {
        Dictionary(headers.map { ($0.session, $0.workers) }) { _, last in last }
    }

    /// The time limit of each session in `headers`, a results file's, by its number, as `workers(of:)` takes them; a
    /// session that recorded none, having tested nothing, is absent.
    static func limits(of headers: [ResultsHeader]) -> [Int: Double] {
        Dictionary(
            headers.compactMap { header in header.timeoutSeconds.map { (header.session, $0) } }
        ) { _, last in last }
    }

    /// Why a resume doesn't keep `record`, which holds for its job by itself, tested on `workers` workers at once
    /// under a time limit of `limit` seconds, `limitNow` in this run: a timeout under a shorter limit than this run's
    /// configured one, or under an unknown limit; or one whose session tested more than one mutant at once, or whose
    /// header is missing, and that no later line tested again at lower load. Retesting a timeout can't lower the score,
    /// which counts it as a survivor.
    private static func reasonToRetest(
        _ record: MutantResult,
        testedOn workers: Int?,
        under limit: Double?,
        now limitNow: Double?
    ) -> Reason? {
        guard record.outcome == .timeout else { return nil }
        if let limitNow, limit.map({ limitNow > $0 }) ?? true {
            return .timeoutUnderShorterLimit
        }
        guard record.rerun == nil, (workers ?? 2) > 1 else { return nil }
        return .timeoutNotRerun
    }

    /// Why a reuse doesn't keep `record`, which holds for its job by itself, after `changes`, those since its session;
    /// nil if it keeps it. Without them, as for a session that recorded no project files, nothing shows what changed.
    private static func reasonToRetest(_ record: MutantResult, after changes: ReuseChanges?) -> Reason? {
        if record.outcome == .timeout {
            return .timedOut
        }
        guard let changes, changes.otherFiles.isEmpty else {
            return .otherFileChanged
        }
        guard !changes.testFiles.isEmpty else { return nil }
        switch record.outcome {
        case .failed, .runtimeError:
            return changes.killHolds(record) ? nil : .testsChanged

        default:
            return .testsChanged
        }
    }

    /// A key without its occurrence: where a mutant is, and which operator mutates it there.
    private struct Place: Hashable {
        let path: String
        let mutationOperatorId: MutationOperator.Id
        let line: Int
        let column: Int

        init(_ key: MutantKey) {
            path = key.path
            mutationOperatorId = key.mutationOperatorId
            line = key.line
            column = key.column
        }
    }
}
