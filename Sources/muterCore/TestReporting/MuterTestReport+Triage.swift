import Foundation

/// How a triage file's labels mark a report's survivors.
extension MuterTestReport {
    /// `fileReports` with each survivor `file` labels marked, and the summary of what `file` says; nil without a file,
    /// or one with no entries, so such a report is as it was.
    static func triaged(
        _ fileReports: [FileReport],
        by file: TriageFile?,
        following: Bool
    ) -> (fileReports: [FileReport], summary: TriageSummary?) {
        guard let file, !file.entries.isEmpty else { return (fileReports, nil) }
        var fileReports = fileReports
        // Where each mutant is in `fileReports`, and the mutants in that order.
        let places = fileReports.indices.flatMap { fileIndex in
            fileReports[fileIndex].appliedOperators.indices.map { (file: fileIndex, mutant: $0) }
        }
        let mutants = places.map { fileReports[$0.file].appliedOperators[$0.mutant] }
        let matches = TriageMatches(file.entries, against: mutants, following: following)

        var labels: [TriageLabel: Int] = [:]
        var noLongerSurviving: [TriageSummary.NoLongerSurviving] = []
        var notTested: [TriageSummary.NoLongerSurviving] = []
        for match in matches.matches {
            let mutant = mutants[match.index]
            guard mutant.takesATriageLabel else {
                let item = Self.noLongerSurviving(mutant, labelledBy: match.entry)
                if mutant.testSuiteOutcome == .buildError {
                    notTested.append(item)
                } else {
                    noLongerSurviving.append(item)
                }
                continue
            }
            labels[match.entry.label, default: 0] += 1
            let place = places[match.index]
            fileReports[place.file].appliedOperators[place.mutant].triage = TriageMark(
                label: match.entry.label,
                note: match.entry.note
            )
        }

        let notCovered = mutants.count(where: \.isANotCoveredMutant)
        // One that no longer survives is said once, there.
        let moved = matches.matches
            .filter { $0.moved && mutants[$0.index].takesATriageLabel }
            .map {
                TriageSummary.Moved(
                    from: $0.entry.mutant.description,
                    now: mutants[$0.index].key ?? $0.entry.mutant.description,
                    label: $0.entry.label
                )
            }
        let summary = TriageSummary(
            file: file.path,
            survivors: mutants.count(where: \.takesATriageLabel),
            notCovered: notCovered > 0 ? notCovered : nil,
            triaged: labels.values.reduce(0, +),
            byLabel: TriageLabel.allCases.map { .init(label: $0, mutants: labels[$0] ?? 0) },
            moved: moved,
            noLongerSurviving: noLongerSurviving,
            unmatched: matches.unmatched.map { .init(mutant: $0.mutant.description, label: $0.label) },
            notTested: notTested.isEmpty ? nil : notTested
        )
        return (fileReports, summary)
    }

    /// A label's `entry` on `mutant`, which didn't survive this time.
    private static func noLongerSurviving(
        _ mutant: AppliedMutationOperator,
        labelledBy entry: TriageEntry
    ) -> TriageSummary.NoLongerSurviving {
        TriageSummary.NoLongerSurviving(
            mutant: mutant.key ?? entry.mutant.description,
            label: entry.label,
            verdict: MutantVerdict(mutant.testSuiteOutcome).words(1),
            savedAs: entry.mutant.description
        )
    }
}
