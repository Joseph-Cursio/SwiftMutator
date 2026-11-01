import Foundation

/// What one session of mutation testing keeps as it goes: what it writes to its results file, each mutant's outcome,
/// tested or kept from an earlier session, and the worker clones it made. Only the task that runs the mutants and
/// records their outcomes uses it, except for its results file, which a stop at once ends from another thread.
final class TestingSession: @unchecked Sendable { // `file`, `mutantLines` and `ended` are behind `writing`
    /// 1 for a run's first session, as for one that reuses an earlier run's results; a resumed one is the next after the
    /// last its results file holds.
    let number: Int
    /// When mutation testing started, which its test duration is measured from.
    let startedAt: Date
    /// How long the earlier sessions' mutation testing took, all together: a resumed run's outcome adds it to this
    /// session's.
    let earlierTestDuration: TimeInterval
    /// Each job's key, in job order, known before the baseline runs.
    var keys: [MutantKey] = []
    /// Whether the baseline passed, and the timed test run after it, if any, ended, so the results have started. Until
    /// then, mutation testing that stops has nothing to report, and sends no early end: an abort says why.
    var baselinePassed = false
    /// Held while a line is written to the results file: a stop at once writes the end line from another thread
    /// (`end(waitingAtMost:_:)`), between two lines, never inside one, and counts only the lines before it.
    private let writing = NSLock()
    private var file: ResultsRecording?
    private var mutantLines = 0
    /// Whether the session has ended its file, with an end line unless a write failed, so that nothing more is written.
    private var ended = false
    /// How many of `outcomes` are earlier sessions' results that a resumed session kept rather than tested again, or an
    /// earlier run's that a session reusing them kept.
    var reused = 0
    /// The jobs, by index, whose result an earlier session recorded as a build error, which a resumed session tests
    /// again. It tests them one after another, where the first session tested other mutants between them, so one that
    /// fails to build again doesn't count toward the build errors in a row that stop mutation testing.
    var earlierBuildErrors: Set<Int> = []
    /// Whether a failure to write was already said, which is said once.
    var saidResultsUnwritable = false
    /// Each mutant's outcome by job index: a kept result's once the header is written, and a tested one's as it is
    /// recorded, so mutation testing that stops early still has them.
    var outcomes: [Int: MutationTestOutcome.Mutation] = [:]
    /// The worker clones made so far, removed however mutation testing ends.
    var clones: [URL] = []

    init(number: Int = 1, startedAt: Date, earlierTestDuration: TimeInterval = 0) {
        self.number = number
        self.startedAt = startedAt
        self.earlierTestDuration = earlierTestDuration
    }

    /// nil until the header is written, and for good if the file couldn't be created.
    var results: ResultsRecording? { writing.withLock { file } }
    /// How many mutants the session recorded, tested or kept from an earlier run, each in a line of its own unless a
    /// write failed.
    var recorded: Int { writing.withLock { mutantLines } }

    /// Makes `file` the session's results file, which its header is written to first.
    func startResults(in file: ResultsRecording) {
        writing.withLock { self.file = file }
    }

    /// Appends `line` to the results file, and counts it in `recorded` if it `isAMutant`, written or not. Returns
    /// whether the append worked, or nil if nothing was written: there is no file, a write failed before, or the
    /// session has ended.
    func append(_ line: () -> some Encodable, isAMutant: Bool = false) -> Bool? {
        writing.withLock {
            if isAMutant { mutantLines += 1 }
            guard let file, file.writeError == nil, !ended else { return nil }
            return file.append(line())
        }
    }

    /// Appends the mutant lines `lines` to the results file together, as `append` does for one, and counts them in
    /// `recorded`: a session that reuses an earlier run's results writes those it keeps.
    func append(contentsOf lines: [MutantResult]) -> Bool? {
        writing.withLock {
            mutantLines += lines.count
            guard let file, file.writeError == nil, !ended else { return nil }
            return file.append(contentsOf: lines)
        }
    }

    /// Writes the end line `makeEnd` makes from `recorded`, unless the session has ended, and closes the file. Returns
    /// what `append` would.
    @discardableResult
    func end(_ makeEnd: (_ recorded: Int) -> ResultsEnd) -> Bool? {
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
    private func endLocked(_ makeEnd: (_ recorded: Int) -> ResultsEnd) -> Bool? {
        guard let file, !ended else { return nil }
        ended = true
        defer { file.close() }
        guard file.writeError == nil else { return nil }
        return file.append(makeEnd(mutantLines))
    }

    /// The outcomes, tested and kept alike, in job order.
    var outcomesInJobOrder: [MutationTestOutcome.Mutation] {
        outcomes.sorted { $0.key < $1.key }.map(\.value)
    }
}
