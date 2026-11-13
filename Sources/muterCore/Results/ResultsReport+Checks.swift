extension ResultsReport {
    /// The verdict on `outcome`'s survivors against `baseline`'s, not checked for the reason `unless` gives;
    /// `progress` is that of a run that didn't finish.
    func newSurvivorsCheck(
        _ baseline: BaselineFile,
        of outcome: MutationTestOutcome,
        unless notChecked: NewSurvivorsCheck.NotChecked?,
        progress: ScoreGate.Progress? = nil
    ) -> NewSurvivorsCheck {
        NewSurvivorsCheck(
            baseline: baseline,
            maxNewSurvivors: maxNewSurvivors,
            judging: outcome,
            version: MutationTestObserver.version(of: outcome),
            unless: notChecked,
            progress: progress
        )
    }

    /// With `maxScoreDrop`, the verdict on `outcome`'s score against `baseline`'s, not checked for the reason `unless`
    /// gives, nor for the results of a run that didn't finish, whose `progress` it says; nil without either.
    func scoreDropCheck(
        _ baseline: BaselineFile?,
        of outcome: MutationTestOutcome,
        unless notChecked: ScoreDropCheck.NotChecked?,
        progress: ScoreGate.Progress? = nil
    ) -> ScoreDropCheck? {
        guard let baseline, let maxScoreDrop else { return nil }
        return ScoreDropCheck(
            baseline: baseline,
            maxScoreDrop: maxScoreDrop,
            judging: outcome,
            unless: notChecked,
            progress: progress
        )
    }

    /// The triage file the report of `outcome` shows, which a broken one refuses: nothing is lost by fixing it and
    /// asking again.
    func triageFile(of outcome: MutationTestOutcome) throws -> TriageFile? {
        if let triagePath {
            guard let file = try TriageFile.load(at: triagePath, using: fileManager) else {
                throw MuterError.literal(reason: "There is no triage file at \(triagePath).")
            }
            return file
        }
        for folder in [outcome.projectPath, fileManager.currentDirectoryPath] where !folder.isEmpty {
            if let file = try TriageFile.load(at: TriageFile.path(in: folder), using: fileManager) {
                return file
            }
        }
        return nil
    }

    /// The paths of the `found` files, less each that a resumed session's note named and that is the same file as one
    /// given directly, or as one an earlier note named. A glob over a run's log folders, such as `<logs>/*/`, names its
    /// file through the first session's folder and through each resumed session's, which are one file however they
    /// are spelled, as `/tmp` and `/private/tmp` are. A file named twice directly is kept twice, so a shard's file
    /// given twice is still refused.
    static func withoutNotedRepeats(_ found: [(path: String, isNoted: Bool)]) -> [String] {
        found.indices.compactMap { index in
            let file = found[index]
            let isRepeat = file.isNoted && found.indices.contains { other in
                other != index && (!found[other].isNoted || other < index)
                    && ResultsFile.isSameFile(found[other].path, file.path)
            }
            return isRepeat ? nil : file.path
        }
    }
}
