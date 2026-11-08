import Foundation

/// A `--baseline` run whose chosen code holds no mutant to test, but mutants of code no test ran (`UncoveredMutant`),
/// as a change that adds only a function no test calls, or only a file no test reaches, does. Those are compared with
/// the baseline file at once (`check`), as no mutant is left to run, and the run ends there, as one with nothing to
/// mutate does (`NothingToMutate`): it writes no report, results file or `summary.json`. It exits with the check's
/// status: 2 when too many of them are new, else 0. Without `--baseline` such a run has nothing to mutate.
struct OnlyUncoveredMutants: Error, Equatable, CustomStringConvertible {
    /// What chose the code: `--since`'s change, or nil for the files the run chose otherwise.
    let selection: ChangeSelection?
    /// How many mutants of code no test ran the code holds.
    let uncovered: Int
    let check: NewSurvivorsCheck

    var description: String {
        let code = selection.map { selection in
            "the code --since chose, since the merge base of \(selection.shownRef) and HEAD "
                + "(\(selection.shortMergeBase)),"
        } ?? "the code the run chose"
        let mutants = uncovered == 1 ? "1 mutant" : "\(uncovered) mutants"
        let opening = "ℹ️ No mutant is left to test in \(code) but it holds \(mutants) of code no test ran, compared "
            + "with the baseline file \(check.baseline)."
        return ([opening] + check.consoleLines).joined(separator: "\n")
    }
}
