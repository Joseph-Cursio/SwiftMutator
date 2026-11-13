import Foundation

struct MutationTestLog {
    let mutationPoint: MutationPoint?
    let testLog: String
    let timePerBuildTestCycle: TimeInterval?
    let remainingMutationPointsCount: Int?
    /// How many workers test the remaining mutants at once. Only the baseline's log says.
    var workers = 1
    /// How long one run of a mutant's test command took with no mutant on, if it was timed. Only the baseline's log
    /// says.
    var testRunSeconds: TimeInterval?
    /// The name of the file the run's log folder keeps this log in, which the step that ran it keeps it under: a
    /// mutant's is `keptFileName(for:)` its key, or `rerunFileName(for:)` it for the run that tested it again, which
    /// its results line names too. A mutant's log that `isKept` drops has the name it would have had, though no file
    /// holds it.
    var keptFileName = Self.baselineFileName

    static let baselineFileName = "baseline run.log"

    /// The name of the file the run's log folder keeps the `number`th build's log in that failed on mutants that don't
    /// compile (`CompileRecovery`), which the next build, under its own name, would otherwise write over.
    static func failedBuildFileName(_ number: Int) -> String {
        "failed build \(number).log"
    }

    /// Whether a mutant's run with `outcome`, whose log showed the tests `killedBy` failing, keeps its log: every run
    /// but one killed by a failed test that its results line names, as `killedBy` and `firstFailedTestLine` stand in
    /// for that log. So a survivor, a crash, a timeout and a build error keep theirs, as does a kill whose line names
    /// no test. `keepingAll`, from `keepAllLogs`, keeps every log. Only a mutant's run goes by this: every other log
    /// is kept.
    static func isKept(
        outcome: TestSuiteOutcome,
        killedBy: [FailedTestLine.FailedTest]?,
        keepingAll: Bool
    ) -> Bool {
        keepingAll || outcome != .failed || (killedBy ?? []).isEmpty
    }

    /// The name of the file the run's log folder keeps the log of `key`'s run in:
    /// `<operator> @ <file name>-<line>-<column> <path hash>.log`, with ` (#<n>)` before `.log` for the nth of a
    /// repeated mutant, as the key's description numbers it. The hash is of its path, as the switch ID's is, so
    /// same-named files' mutants of one operator at the same place, such as in two executable targets' `main.swift`,
    /// keep a log each, even on a disk that ignores case.
    static func keptFileName(for key: MutantKey) -> String {
        let fileName = key.path.lastPathComponent
        let repeated = key.occurrence > 0 ? " (#\(key.occurrence + 1))" : ""
        return "\(key.mutationOperatorId.rawValue) @ \(fileName)-\(key.line)-\(key.column) \(key.path.stableHash)"
            + repeated + ".log"
    }

    /// The name of the file the run's log folder keeps the log of `key`'s second run in, when a session tests it
    /// again: `keptFileName(for:)` with ` (rerun)` before `.log`, so the first run's log is kept too.
    static func rerunFileName(for key: MutantKey) -> String {
        noting("rerun", in: keptFileName(for: key))
    }

    /// The name of the file the run's log folder keeps the log of a kill tested again alone in
    /// (`MutantResult.Rerun.onlySuspectTestsFailed`).
    static func suspectRerunFileName(for key: MutantKey) -> String {
        noting("alone", in: keptFileName(for: key))
    }

    /// The name of the file the run's log folder keeps the log of `key`'s property rerun in, the run of the property
    /// tests alone with its mutant on (`PropertyReruns`): `keptFileName(for:)` with ` (properties)` before `.log`.
    static func propertyRerunFileName(for key: MutantKey) -> String {
        noting("properties", in: keptFileName(for: key))
    }

    /// The name of the file the run's log folder keeps the log of run `run` of `key`'s property survivor reruns in
    /// (`PropertySurvivorReruns`): `keptFileName(for:)` with ` (properties, run 3)` before `.log`.
    static func propertySurvivorRerunFileName(for key: MutantKey, run: Int) -> String {
        noting("properties, run \(run)", in: keptFileName(for: key))
    }

    /// The name of the file the run's log folder keeps the log of a run in that the simulator failed to launch, and
    /// that ran again in its place: `logName`, the name of that second run's log, with ` (launch failed)` before
    /// `.log`.
    static func launchFailedFileName(for logName: String) -> String {
        noting("launch failed", in: logName)
    }

    /// The name of the file the run's log folder keeps the log of a run in that found its simulator gone, which no
    /// result names: `logName`, the name its log would have had, with ` (simulator gone)` before `.log`.
    static func simulatorGoneFileName(for logName: String) -> String {
        noting("simulator gone", in: logName)
    }

    /// `logName` with ` (<note>)` before its `.log`.
    private static func noting(_ note: String, in logName: String) -> String {
        String(logName.dropLast(".log".count)) + " (\(note)).log"
    }
}
