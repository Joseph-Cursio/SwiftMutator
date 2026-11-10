/// A `--baseline` run whose chosen code holds no mutant to test, but mutants of code no test ran (`UncoveredMutant`),
/// as a change that adds only a function no test calls, or only a file no test reaches, does. Those are compared with
/// the baseline file at once (`check`), as no mutant is left to run, and the run ends there, as one with nothing to
/// mutate does (`NothingToMutate`): it writes no report, results file or `summary.json`. It exits with the checks'
/// status: 2 when too many of them are new, else 0. Without `--baseline` such a run has nothing to mutate.
///
/// With `--max-score-drop` and `--max-doubtful-kills`, it says their verdicts too, after the survivors', as a run
/// does: no mutant was tested, so the score isn't compared, and says why, and there's no doubtful kill.
struct OnlyUncoveredMutants: Error, Equatable, CustomStringConvertible {
    /// What chose the code: `--since`'s change, or nil for the files the run chose otherwise.
    let selection: ChangeSelection?
    /// How many mutants of code no test ran the code holds.
    let uncovered: Int
    let check: NewSurvivorsCheck
    /// With `--max-score-drop`, the verdict on the score against the file's; nil without it.
    var scoreDrop: ScoreDropCheck?
    /// With `--max-doubtful-kills`, the verdict on the kills; nil without it.
    var doubtfulKills: DoubtfulKillsCheck?

    /// Every check the run made, which it exits with.
    var checks: RunChecks {
        RunChecks(newSurvivors: check, scoreDrop: scoreDrop, doubtfulKills: doubtfulKills)
    }

    var description: String {
        let code = selection.map { selection in
            "the code --since chose, since the merge base of \(selection.shownRef) and HEAD "
                + "(\(selection.shortMergeBase)),"
        } ?? "the code the run chose"
        let mutants = uncovered == 1 ? "1 mutant" : "\(uncovered) mutants"
        let opening = "ℹ️ No mutant is left to test in \(code) but it holds \(mutants) of code no test ran, compared "
            + "with the baseline file \(check.baseline)."
        let others: [[String]?] = [scoreDrop?.consoleLines, doubtfulKills?.consoleLines]
        let lines: [String] = check.consoleLines + others.compactMap(\.self).flatMap(\.self)
        return ([opening] + lines).joined(separator: "\n")
    }
}
