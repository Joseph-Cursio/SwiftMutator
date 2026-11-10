import ArgumentParser
import Foundation

/// `swift-mutator triage`: labels a mutant that survived, in `muter.triage.yml`, which the reports then show. A plain
/// command, as `report` is: it tests nothing, and changes no result and no score.
struct Triage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "triage",
        abstract: "Labels a surviving mutant in muter.triage.yml, which the reports show. It changes no score."
    )

    @Argument(
        help: ArgumentHelp(
            "The mutant, as path:line[:column] [Operator], such as 'Sources/Foo/Bar.swift:12:9 SwapTernary'.",
            valueName: "mutant"
        )
    )
    var mutant: String

    @Option(
        name: .customLong("results"),
        help: ArgumentHelp(
            "The results file, or a log folder of the run, that the mutant survived in. Needed for --label. With "
                + "--remove, the mutant is the place these results show it at, not the place the file holds it at.",
            valueName: "results"
        )
    )
    var results: String?

    @Option(
        name: .customLong("label"),
        help: ArgumentHelp("What the survivor is: \(TriageLabel.listed).", valueName: "label"),
        transform: { text in
            guard let label = TriageLabel(rawValue: text) else {
                throw ValidationError("give \(TriageLabel.listed).")
            }
            return label
        }
    )
    var label: TriageLabel?

    @Option(name: .customLong("note"), help: ArgumentHelp("Why, kept with the label.", valueName: "text"))
    var note: String?

    @Flag(
        name: .customLong("remove"),
        help: "Remove the mutant's label instead. Without --results, the mutant is named as the file holds it."
    )
    var remove = false

    @Option(
        name: .customLong("file"),
        help: ArgumentHelp(
            "The triage file, if not muter.triage.yml in the run's project, or in the current folder.",
            valueName: "path"
        )
    )
    var file: String?

    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.printer)
    private var printer: Printer

    private enum CodingKeys: String, CodingKey {
        case mutant
        case results
        case label
        case note
        case remove
        case file
    }

    init() {}

    func validate() throws {
        _ = try MutantReference.parse(mutant)
        if remove {
            guard label == nil, note == nil else {
                throw ValidationError("--remove takes only a mutant, --results and --file.")
            }
        } else {
            guard label != nil, results != nil else {
                throw ValidationError("give --label and --results to label a mutant, or --remove to remove a label.")
            }
        }
    }

    func run() async throws {
        let reference = try MutantReference.parse(mutant)
        if remove {
            try removeLabel(of: reference)
        } else if let label, let results {
            try addLabel(label, to: reference, from: results)
        }
    }

    /// What a results file says of its mutants, and the triage file that goes with them.
    private struct Results {
        let outcome: MutationTestOutcome
        let mutants: [MuterTestReport.AppliedMutationOperator]
    }

    private func read(_ results: String) throws -> Results {
        let path = try ResultsFile.locate(at: results, using: fileManager).path
        guard let data = fileManager.contents(atPath: path) else {
            throw ResultsFileError.unreadable(path: path)
        }
        let outcome = try RecordedResults.read(data, path: path).mutationTestOutcome(resultsFile: path)
        let mutants = MuterTestReport(from: outcome).fileReports.flatMap(\.appliedOperators)
        return Results(outcome: outcome, mutants: mutants)
    }

    /// Records `label` for the one mutant `reference` names among those that survived in `results`, in place of the
    /// label its code already has, wherever that label's entry says it was. Any other label is kept. Those that moved
    /// are saved at their new places, as a key they moved from may be the one this label now needs. A label that
    /// matches nothing, and whose key is now taken, is the one thing dropped, and is named.
    private func addLabel(_ label: TriageLabel, to reference: MutantReference, from results: String) throws {
        let run = try read(results)
        let found = try Self.oneMutant(reference, in: run)
        guard found.takesATriageLabel,
              let foundKey = found.key,
              let key = MutantKey(wholeDescription: foundKey)
        else {
            let verdict = MutantVerdict(found.testSuiteOutcome).words(1)
            throw MuterError.literal(
                reason: "\(found.key ?? reference.description) didn't survive this run (\(verdict)): only a mutant "
                    + "that survived, timed out or no test reached takes a label."
            )
        }

        let triagePath = file ?? TriageFile.path(in: projectFolder(of: run.outcome))
        var triage = try TriageFile.load(at: triagePath, using: fileManager)
            ?? TriageFile(path: triagePath, entries: [])
        let matches = TriageMatches(triage.entries, against: run.mutants, following: !run.outcome.leavesOutSomeMutants)
        let others = matches.matches.filter { run.mutants[$0.index].key != foundKey }
        let kept = others.map { match -> TriageEntry in
            guard match.moved, let now = run.mutants[match.index].key.flatMap(MutantKey.init(wholeDescription:)) else {
                return match.entry
            }
            return match.entry.moved(to: now)
        }
        let taken = Set(kept.map(\.mutant)).union([key])
        let dropped = matches.unmatched.filter { taken.contains($0.mutant) }
        let labelled = TriageEntry(
            mutant: key,
            label: label,
            note: note?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            before: found.mutationSnapshot.before,
            after: found.mutationSnapshot.after,
            line: found.changedLine
        )
        triage.entries = kept + matches.unmatched.filter { !taken.contains($0.mutant) } + [labelled]
        try triage.save(using: fileManager)

        printer("\(key): \(label.words), in \(triagePath)")
        let moved = others.count(where: \.moved)
        if moved > 0 {
            let (labels, places) = moved == 1
                ? ("label that followed its code is", "its new place")
                : ("labels that followed their code are", "their new places")
            printer("ℹ️ \(moved) \(labels) saved at \(places).")
        }
        for entry in dropped {
            printer("⚠️ Dropped the label of \(entry.mutant) (\(entry.label.words)): it matched no mutant, and that "
                + "place is now another label's.")
        }
        if found.changedLine == nil {
            printer(
                "ℹ️ Its line couldn't be read, as its file changed since this run or its change spans lines, so "
                    + "this label stays at this place: it won't follow the code if the code moves."
            )
        }
    }

    /// Removes the one label `reference` names, then says what it was, so that removing the wrong one shows. With
    /// results, it names a mutant at the place they show, and the label on it, or else a label that matches no mutant
    /// in them. Without, it names the entry by its key, which is older than the place a report shows if the code moved.
    private func removeLabel(of reference: MutantReference) throws {
        let run = try results.map(read)
        let triagePath = file ?? TriageFile.path(in: run.map { projectFolder(of: $0.outcome) }
            ?? fileManager.currentDirectoryPath)
        guard var triage = try TriageFile.load(at: triagePath, using: fileManager) else {
            throw MuterError.literal(reason: "There is no triage file at \(triagePath).")
        }

        let named: [TriageEntry]
        if let run {
            let wanted = Self.relative(reference, in: run.outcome)
            let matches = TriageMatches(
                triage.entries,
                against: run.mutants,
                following: !run.outcome.leavesOutSomeMutants
            )
            let onMutants = matches.matches.filter { match in
                run.mutants[match.index].key.flatMap(MutantKey.init(wholeDescription:)).map(wanted.matches) ?? false
            }.map(\.entry)
            named = onMutants.isEmpty ? matches.unmatched.filter { wanted.matches($0.mutant) } : onMutants
        } else {
            let wanted = reference.relative(
                toFirstOf: [URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)]
            )
            named = triage.entries.filter { wanted.matches($0.mutant) }
        }

        guard let entry = named.first else {
            throw MuterError.literal(reason: "\(triagePath) has no label for \(reference).")
        }
        guard named.count == 1 else {
            let keys = named.map { "  \($0.mutant)" }.joined(separator: "\n")
            throw MuterError.literal(reason: "\(reference) names \(named.count) labelled mutants:\n\(keys)")
        }
        triage.entries.removeAll { $0.mutant == entry.mutant }
        try triage.save(using: fileManager)

        let details = [entry.label.words, entry.line, entry.note].compactMap(\.self).joined(separator: ", ")
        printer("\(entry.mutant): label removed from \(triagePath) (\(details))")
    }

    /// The folder the run's project was in, when it's still there, or else the current one, as for a results file
    /// from another machine.
    private func projectFolder(of outcome: MutationTestOutcome) -> String {
        (try? fileManager.contentsOfDirectory(atPath: outcome.projectPath)) != nil
            ? outcome.projectPath
            : fileManager.currentDirectoryPath
    }

    /// `reference` with an absolute path in the run's project, or in its copy, made relative as `--mutant` makes it.
    private static func relative(_ reference: MutantReference, in outcome: MutationTestOutcome) -> MutantReference {
        reference.relative(
            toFirstOf: [outcome.projectPath, outcome.mutatedProjectPath]
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }

    /// The one mutant in `run` that `reference` names, or why there isn't one.
    private static func oneMutant(
        _ reference: MutantReference,
        in run: Results
    ) throws -> MuterTestReport.AppliedMutationOperator {
        let wanted = relative(reference, in: run.outcome)
        let named = run.mutants.filter { mutant in
            mutant.key.flatMap(MutantKey.init(wholeDescription:)).map(wanted.matches) ?? false
        }
        guard let first = named.first else {
            throw MuterError.literal(reason: "These results have no mutant at \(reference).")
        }
        guard named.count == 1 else {
            let keys = named.compactMap(\.key).map { "  \($0)" }.joined(separator: "\n")
            throw MuterError.literal(reason: "\(reference) names \(named.count) mutants; give one of:\n\(keys)")
        }
        return first
    }
}

private extension String {
    /// This string, or nil if it's empty.
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
