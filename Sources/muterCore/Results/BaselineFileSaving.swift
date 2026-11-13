import Rainbow

/// What became of the baseline file `--write-baseline` asked for, as the run's end, or `report`, says it.
enum BaselineFileSaving: Equatable {
    case saved(path: String)
    /// It couldn't be saved there, as a report that can't be isn't: a warning, which changes no exit status.
    case notSaved(path: String)
    /// None was made, for the reason given, in a clause: "the run stopped before it finished". Only a whole run's
    /// results make one, as one that left mutants out would record their survivors as gone.
    case leftOut(path: String, because: String)

    /// Saves the baseline file of `outcome`, tested by SwiftMutator `version`, at `path`, unless these results leave
    /// some mutants out, by `outcome.whyNoBaselineFile` or `stopped`, a clause that says why they stop short, or
    /// tested none, as every mutant was a build error: its survivors would be none, and every survivor of a later run
    /// new.
    static func save(
        _ outcome: MutationTestOutcome,
        to path: String,
        version: String,
        using fileManager: FileSystemManager,
        unless stopped: String? = nil
    ) -> Self {
        if let reason = stopped ?? outcome.whyNoBaselineFile {
            return .leftOut(path: path, because: reason)
        }
        let mutants = outcome.mutations.filter { $0.key != nil }
        if !mutants.isEmpty, mutants.allSatisfy({ $0.testSuiteOutcome == .buildError }) {
            return .leftOut(path: path, because: "every mutant was a build error, so none was tested")
        }
        guard let scope = outcome.baselineScope else {
            return .leftOut(path: path, because: "the results don't record their scope")
        }
        let file = BaselineFile(of: outcome, scope: scope, version: version, path: path)
        return file.save(using: fileManager) ? .saved(path: path) : .notSaved(path: path)
    }

    /// What a run says of it, with an emoji: "📌 Baseline file saved: muter.baseline.yml".
    var line: String {
        switch self {
        case let .saved(path): "📌 Baseline file saved: \(path.bold)"
        case .notSaved, .leftOut: "⚠️ " + plainLine
        }
    }

    /// What `report` says of it, on standard error, without an emoji.
    var plainLine: String {
        switch self {
        case let .saved(path):
            "Baseline file saved to \(path)"

        case let .notSaved(path):
            "Could not save the baseline file to \(path)"

        case let .leftOut(path, reason):
            "No baseline file was saved to \(path): \(reason), and a baseline file holds a whole run's survivors."
        }
    }
}
