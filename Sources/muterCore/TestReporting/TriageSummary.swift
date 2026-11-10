import Foundation

/// Which mutant each of a triage file's entries labels. A key moves with any edit above its mutant, and a different
/// mutant can come to have it, so a key alone settles nothing:
/// 1. An entry applies at its key when what it says its mutant changes is what the mutant there changes. An entry's
///    `before`, `after` or `line` that's missing, or a mutant whose line can't be read, isn't compared.
/// 2. Then an entry that holds its line follows its code: to the one mutant in its file with its operator, its change
///    and its line, when no entry applies at that mutant's key and no other follows to it. Being the one left once
///    other labels have taken their mutants isn't enough: that's a guess by elimination. Nor does an entry follow in
///    results that leave out some of a file's mutants (`following`), where the one found may be only the one tested.
/// 3. Any other entry labels nothing, so a label never lands on a different mutant on a guess.
///
/// A label at its key can't be told from an identical line that shifted onto that key: nothing tells them apart.
struct TriageMatches {
    struct Match: Equatable {
        let entry: TriageEntry
        /// Into the mutants matched against.
        let index: Int
        let moved: Bool
    }

    private(set) var matches: [Match] = []
    private(set) var unmatched: [TriageEntry] = []

    init(
        _ entries: [TriageEntry],
        against mutants: [MuterTestReport.AppliedMutationOperator],
        following: Bool = true
    ) {
        var places: [String: Int] = [:]
        for (index, mutant) in mutants.enumerated() {
            if let key = mutant.key {
                places[key] = index
            }
        }

        var claimed: Set<Int> = []
        var left: [TriageEntry] = []
        for entry in entries {
            if let index = places[entry.mutant.description], entry.describes(mutants[index]) {
                matches.append(Match(entry: entry, index: index, moved: false))
                claimed.insert(index)
            } else {
                left.append(entry)
            }
        }

        let followed = left.map { entry -> Int? in
            guard following, entry.line != nil else { return nil }
            let found = mutants.indices.filter { mutants[$0].key != nil && entry.follows(to: mutants[$0]) }
            guard found.count == 1, let only = found.first, !claimed.contains(only) else { return nil }
            return only
        }
        for (entry, index) in zip(left, followed) {
            if let index, followed.count(where: { $0 == index }) == 1 {
                matches.append(Match(entry: entry, index: index, moved: true))
            } else {
                unmatched.append(entry)
            }
        }
    }
}

private extension TriageEntry {
    /// Whether what this entry says its mutant changes is what `mutant` changes, as far as both are known.
    func describes(_ mutant: MuterTestReport.AppliedMutationOperator) -> Bool {
        (before.map { $0 == mutant.mutationSnapshot.before } ?? true)
            && (after.map { $0 == mutant.mutationSnapshot.after } ?? true)
            && (line.flatMap { line in mutant.changedLine.map { $0 == line } } ?? true)
    }

    /// Whether `mutant` is in this entry's file, by this entry's operator, and known to change this entry's line.
    func follows(to mutant: MuterTestReport.AppliedMutationOperator) -> Bool {
        mutant.path == self.mutant.path
            && mutant.mutationPoint.mutationOperatorId == self.mutant.mutationOperatorId
            && mutant.changedLine != nil
            && describes(mutant)
    }
}

extension MuterTestReport.AppliedMutationOperator {
    /// The line it changes, without the spaces around it, which an entry holds: moved code may be indented anew.
    var changedLine: String? {
        sourceChange?.before.trimmingCharacters(in: .whitespaces)
    }
}

/// A surviving mutant's label, as a report shows it.
struct TriageMark: Codable, Equatable {
    let label: TriageLabel
    let note: String?

    /// "equivalent: count can't exceed limit here", on one line.
    var text: String {
        let note = note?.split(whereSeparator: \.isNewline).joined(separator: " ")
        return label.words + (note.map { ": \($0)" } ?? "")
    }
}

/// How far the survivors have been triaged, and which labels no longer apply, as the plain text, HTML and JSON reports
/// show it. It changes no score.
struct TriageSummary: Codable, Equatable {
    /// How many of the labels that need attention the plain and HTML reports list, of each kind.
    static let shownLabels = 10

    struct LabelCount: Codable, Equatable {
        let label: TriageLabel
        let mutants: Int
    }

    /// A label that followed its code from the place its entry names.
    struct Moved: Codable, Equatable {
        let from: String
        let now: String
        let label: TriageLabel
    }

    /// A label on a mutant that didn't survive this time.
    struct NoLongerSurviving: Codable, Equatable {
        let mutant: String
        let label: TriageLabel
        /// What the mutant came to: "killed", or "build error".
        let verdict: String
        /// The key the triage file holds it by, which `triage --remove` takes without results: another than `mutant`'s
        /// when its code moved.
        let savedAs: String
    }

    /// A label that matches no mutant in the results.
    struct Unmatched: Codable, Equatable {
        let mutant: String
        let label: TriageLabel
    }

    /// The triage file.
    let file: String
    /// The mutants that survived, timed out or no test reached, as the reports list them.
    let survivors: Int
    /// How many of them no test reached; nil without any.
    var notCovered: Int?
    /// Those with a label.
    let triaged: Int
    /// Every label, zeros included.
    let byLabel: [LabelCount]
    let moved: [Moved]
    let noLongerSurviving: [NoLongerSurviving]
    let unmatched: [Unmatched]
    /// Labels on mutants that were build errors, as those that didn't compile are: they weren't tested, so this says
    /// nothing of the label. nil without any.
    var notTested: [NoLongerSurviving]?
}

extension TriageSummary {
    static let introduction = "Labels people gave surviving mutants. They change no score."

    /// "Of the 15 mutants that survived or timed out, 9 are triaged in muter.triage.yml, and 6 aren't." With mutants
    /// not covered among them, "that survived, timed out or no test reached".
    var countSentence: String {
        let name = (file as NSString).lastPathComponent
        let untriaged = survivors - triaged
        let mutants = survivors == 1 ? "the 1 mutant" : "the \(survivors) mutants"
        let kinds = (notCovered ?? 0) > 0 ? "survived, timed out or no test reached" : "survived or timed out"
        return "Of \(mutants) that \(kinds), \(triaged) \(triaged == 1 ? "is" : "are") triaged in "
            + "\(name), and \(untriaged) \(untriaged == 1 ? "isn't" : "aren't")."
    }

    /// "By label: 4 missing test, 3 equivalent." nil when no survivor has one.
    var labelSentence: String? {
        let counts = byLabel.filter { $0.mutants > 0 }.map { "\($0.mutants) \($0.label.words)" }
        return counts.isEmpty ? nil : "By label: \(counts.joined(separator: ", "))."
    }

    /// Each label that needs attention, under a sentence that says what it means.
    var attentionParagraphs: [[String]] {
        [
            paragraph(
                moved,
                one: "label followed its code to a new place:",
                many: "labels followed their code to new places:"
            ) { "\($0.from) (\($0.label.words)) is now \($0.now)" },
            paragraph(
                noLongerSurviving,
                one: "label is on a mutant that no longer survives:",
                many: "labels are on mutants that no longer survive:"
            ) { item in
                let saved = item.savedAs == item.mutant ? "" : ", saved as \(item.savedAs)"
                return "\(item.mutant) (\(item.label.words)): \(item.verdict)\(saved)"
            },
            paragraph(
                notTested ?? [],
                one: "label is on a mutant that wasn't tested, as it was a build error, so it may still hold:",
                many: "labels are on mutants that weren't tested, as they were build errors, so they may still hold:"
            ) { "\($0.mutant) (\($0.label.words))" },
            paragraph(
                unmatched,
                one: "label matches no mutant in these results, as its code changed or it wasn't tested:",
                many: "labels match no mutant in these results, as their code changed or they weren't tested:"
            ) { "\($0.mutant) (\($0.label.words))" },
        ].compactMap(\.self)
    }

    /// "2 labels …:" and a line for each of `items`, up to `shownLabels`, then how many more; nil without any.
    private func paragraph<Item>(
        _ items: [Item],
        one: String,
        many: String,
        line: (Item) -> String
    ) -> [String]? {
        guard !items.isEmpty else { return nil }
        let hidden = items.count - Self.shownLabels
        return ["\(items.count) \(items.count == 1 ? one : many)"]
            + items.prefix(Self.shownLabels).map { "  " + line($0) }
            + (hidden > 0 ? ["  and \(hidden) more; the JSON report lists them all"] : [])
    }
}

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
                let item = TriageSummary.NoLongerSurviving(
                    mutant: mutant.key ?? match.entry.mutant.description,
                    label: match.entry.label,
                    verdict: MutantVerdict(mutant.testSuiteOutcome).words(1),
                    savedAs: match.entry.mutant.description
                )
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
        let summary = TriageSummary(
            file: file.path,
            survivors: mutants.count(where: \.takesATriageLabel),
            notCovered: notCovered > 0 ? notCovered : nil,
            triaged: labels.values.reduce(0, +),
            byLabel: TriageLabel.allCases.map { .init(label: $0, mutants: labels[$0] ?? 0) },
            // One that no longer survives is said once, there.
            moved: matches.matches.filter {
                $0.moved && mutants[$0.index].takesATriageLabel
            }.map {
                .init(
                    from: $0.entry.mutant.description,
                    now: mutants[$0.index].key ?? $0.entry.mutant.description,
                    label: $0.entry.label
                )
            },
            noLongerSurviving: noLongerSurviving,
            unmatched: matches.unmatched.map { .init(mutant: $0.mutant.description, label: $0.label) },
            notTested: notTested.isEmpty ? nil : notTested
        )
        return (fileReports, summary)
    }
}
