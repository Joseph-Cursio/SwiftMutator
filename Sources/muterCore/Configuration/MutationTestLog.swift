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
    /// The name of the file the run's log folder keeps this log in: a mutant's is `keptFileName(for:)` its key, which
    /// its results line names too.
    var keptFileName = Self.baselineFileName
}

extension MutationTestLog {
    static let baselineFileName = "baseline run.log"

    /// The name of the file the run's log folder keeps the log of `key`'s run in:
    /// `<operator> @ <file name>-<line>-<column> <path hash>.log`, with ` (#<n>)` before `.log` for the nth of a
    /// repeated mutant, as the key's description numbers it. The hash is of its path, as the switch ID's is, so
    /// same-named files' mutants of one operator at the same place, such as in two executable targets' `main.swift`,
    /// keep a log each, even on a disk that ignores case.
    static func keptFileName(for key: MutantKey) -> String {
        let fileName = (key.path as NSString).lastPathComponent
        let repeated = key.occurrence > 0 ? " (#\(key.occurrence + 1))" : ""
        return "\(key.mutationOperatorId.rawValue) @ \(fileName)-\(key.line)-\(key.column) \(key.path.stableHash)"
            + repeated + ".log"
    }
}
