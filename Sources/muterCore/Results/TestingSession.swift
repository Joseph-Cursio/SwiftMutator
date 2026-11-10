import Foundation

/// What became of a line `TestingSession` was asked to write to its results file.
enum ResultsWrite: Equatable {
    /// It was written.
    case written
    /// The write failed.
    case failed
    /// Nothing was written: there is no file, a write failed before, or the session has ended.
    case skipped

    /// `written` if `succeeded`, else `failed`.
    init(_ succeeded: Bool) {
        self = succeeded ? .written : .failed
    }
}

/// What one session of mutation testing keeps as it goes: what it writes to its results file, each mutant's outcome,
/// tested or kept from an earlier session, and the worker clones it made. Only the task that runs the mutants and
/// records their outcomes uses it, except for its results file, which a stop at once ends from another thread.
final class TestingSession: @unchecked Sendable { // `file`, `mutantLines` and `ended` are behind `writing`
    /// 1 for a run's first session, as for one that reuses an earlier run's results; a resumed one is the next after
    /// the last its results file holds.
    let number: Int
    /// When mutation testing started, which its test duration is measured from.
    let startedAt: Date
    /// How long the earlier sessions' mutation testing took, all together: a resumed run's outcome adds it to this
    /// session's.
    let earlierTestDuration: TimeInterval
    /// Each job's key, in job order, known before the baseline runs.
    var keys: [MutantKey] = []
    /// The header written to its results file, and that file, once written: where the reports say its results came
    /// from.
    var header: ResultsHeader?
    var resultsPath: String?
    /// Whether the baseline passed, and the timed test run after it, if any, ended, so the results have started. Until
    /// then, mutation testing that stops has nothing to report, and sends no early end: an abort says why.
    var baselinePassed = false
    /// Held while a line is written to the results file, and across the session's first lines, which are written
    /// together: a stop at once writes the end line from another thread (`end(waitingAtMost:_:)`), between two lines,
    /// never inside one or among the first lines, and counts only the lines before it.
    private let writing = NSLock()
    private var file: ResultsRecording?
    private var mutantLines = 0
    /// Whether the session has ended its file, with an end line unless a write failed, so that nothing more is written.
    private var ended = false
    /// How many of `outcomes` are earlier sessions' results that a resumed session kept rather than tested again, or an
    /// earlier run's that a session reusing them kept.
    var reused = 0
    /// How many of `outcomes` are mutants that didn't compile, so weren't in the build (`CompileRecovery`), and whose
    /// tests never ran.
    var leftOut = 0
    /// The jobs, by index, whose switch isn't in this session's build (`CompileRecovery`), whether their outcome is a
    /// build error or a result kept from an earlier session. Nothing can test them here.
    var notInTheBuild: Set<Int> = []
    /// The jobs, by index, whose result an earlier session recorded as a build error, which a resumed session tests
    /// again. It tests them one after another, where the first session tested other mutants between them, so one that
    /// fails to build again doesn't count toward the build errors in a row that stop mutation testing.
    var earlierBuildErrors: Set<Int> = []
    /// Whether a failure to write was already said, which is said once.
    var saidResultsUnwritable = false
    /// Each mutant's outcome by job index: a kept result's once the header is written, and a tested one's as it is
    /// recorded, so mutation testing that stops early still has them.
    var outcomes: [Int: MutationTestOutcome.Mutation] = [:]
    /// Whether any mutant's run in this session showed whether its block ran (`TestRun.activated`), so its test command
    /// passes the marker on and its test host can write there.
    var activationShown = false
    /// How many of this session's mutants' runs, built and run, showed neither.
    var runsShowingNoActivation = 0
    /// The jobs, by index, whose first run in this session failed without showing their block ran.
    var killsNotShownToRunTheirCode: [Int] = []
    /// The jobs, by index, whose first run in this session timed out without showing their block ran.
    var timeoutsNotShownToRunTheirCode: [Int] = []
    /// The control runs recorded so far, in the order they finished, written or not.
    var controlRuns: [ControlRunResult] = []
    /// The worker clones made so far, removed however mutation testing ends, with what's beside them. Workers that
    /// share a build have these names and no folders.
    var clones: [URL] = []
    /// The xcodebuild workers given a simulator each, in worker order, once their simulators have booted. Their
    /// `.xctestrun` files and derived data, but worker 0's `.xctestrun`, are removed however mutation testing ends.
    var xcodeWorkers: [MuterConfiguration.XcodeWorker] = []

    init(startedAt: Date, number: Int = 1, earlierTestDuration: TimeInterval = 0) {
        self.number = number
        self.startedAt = startedAt
        self.earlierTestDuration = earlierTestDuration
    }

    /// nil until the header is written, and for good if the file couldn't be created.
    var results: ResultsRecording? { writing.withLock { file } }

    /// Makes `file` the session's results file, and writes `firstLines`, its header first, in one write while no end
    /// line can come between them: a stop at once ends the session after them, or, before them, writes nothing. Returns
    /// what `append` would. With no `firstLines` it only makes `file` the session's.
    func startResults(in file: ResultsRecording, writing firstLines: [any Encodable]) -> ResultsWrite {
        writing.withLock {
            self.file = file
            guard file.writeError == nil, !ended else { return .skipped }
            guard !firstLines.isEmpty else { return .written }
            return ResultsWrite(file.append(contentsOf: firstLines))
        }
    }

    /// Appends `line` to the results file, and counts it in `recorded` if it `isAMutant`, written or not. Returns
    /// whether the append worked, or `skipped` if nothing was written: there is no file, a write failed before, or the
    /// session has ended.
    func append(_ line: () -> some Encodable, isAMutant: Bool = false) -> ResultsWrite {
        writing.withLock {
            if isAMutant { mutantLines += 1 }
            guard let file, file.writeError == nil, !ended else { return .skipped }
            return ResultsWrite(file.append(line()))
        }
    }

    /// Appends the mutant lines `lines` to the results file together, as `append` does for one, and counts them in
    /// `recorded`: a session that reuses an earlier run's results writes those it keeps.
    func append(contentsOf lines: [MutantResult]) -> ResultsWrite {
        writing.withLock {
            mutantLines += lines.count
            guard let file, file.writeError == nil, !ended else { return .skipped }
            return ResultsWrite(file.append(contentsOf: lines))
        }
    }

    /// Writes the end line `makeEnd` makes from `recorded`, unless the session has ended, and closes the file. Returns
    /// what `append` would.
    @discardableResult
    func end(_ makeEnd: (_ recorded: Int) -> ResultsEnd) -> ResultsWrite {
        writing.withLock { endLocked(makeEnd) }
    }

    /// `end`, from another thread, as SwiftMutator stops at once. Writes nothing if a line has been under way for
    /// `timeout` seconds, as on a disk that has stopped answering: SwiftMutator must still stop.
    func end(waitingAtMost timeout: TimeInterval, _ makeEnd: (_ recorded: Int) -> ResultsEnd) {
        guard writing.lock(before: Date().addingTimeInterval(timeout)) else { return }
        defer { writing.unlock() }
        endLocked(makeEnd)
    }

    /// While `writing` is held. Without a file there's nothing to end, as before the header.
    private func endLocked(_ makeEnd: (_ recorded: Int) -> ResultsEnd) -> ResultsWrite {
        guard let file, !ended else { return .skipped }
        ended = true
        defer { file.close() }
        guard file.writeError == nil else { return .skipped }
        return ResultsWrite(file.append(makeEnd(mutantLines)))
    }

    /// The outcomes, tested and kept alike, in job order.
    var outcomesInJobOrder: [MutationTestOutcome.Mutation] {
        outcomes.sorted { $0.key < $1.key }.map(\.value)
    }
}
