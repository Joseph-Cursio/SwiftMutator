import Foundation

/// Which of a run's survivors a baseline file already records, and which are new. A key moves with any line added
/// above its mutant, so a key alone settles nothing, and matching follows the triage file's scheme (`TriageMatches`):
/// what a mutant changes (its path, operator, `before` and `after`) and the line it changes, without the spaces around
/// it (`AppliedMutationOperator.changedLine`), read from its file only while that is as it was tested. Unlike a label,
/// a survivor is counted, not named, so identical twins are a multiset: two identical entries match two identical
/// survivors, and a third is new.
///
/// Only the run's mutants with a key take part, never a file's row for having no coverage, which has none:
/// 1. Each entry is paired with a run's survivor, or with a mutant the run didn't test: a build error, or one it
///    discovered and left out, as another shard's, one outside its sample, or one off its changed lines. First at the
///    entry's own key, when what it changes and its line agree; then, for those left, with any such mutant left that
///    has its path, operator, change and line, the nearest to its old line first. Only once every pairing by the line
///    is made, where either side's line isn't known, the line isn't compared: at the entry's own key, then the
///    nearest. Never by the key alone, nor by the line and column.
/// 2. Entries left are paired the same way with the run's killed mutants: those are fixed.
/// 3. Entries paired with a mutant the run didn't test, or with nothing, are not tested: their code changed or went,
///    or the run didn't test it.
/// 4. The run's survivors paired with nothing are new.
///
/// Survivors are paired before kills, so a survivor whose identical twin was killed doesn't count as both new and
/// fixed; and with the mutants left out, so an entry for one doesn't take an identical survivor the run tested, which
/// would hide that survivor, nor an identical kill, which would count it fixed. When the run left mutants out that
/// aren't known (`exactKeysOnly`), as `report` of a sample's results, an entry is paired only at its own key. A
/// renamed file's survivors are new, and its entries not tested: nothing maps an old path to a new one.
struct BaselineMatches: Equatable {
    /// A mutant the run discovered, as the matching sees it.
    struct TestedMutant: Equatable {
        enum Kind: Equatable {
            /// The tests didn't kill it: it survived, timed out, or no test ran its code.
            case survivor(BaselineSurvivor.Outcome)
            case killed
            /// It wasn't tested: a build error, or a mutant the run left out (`UnselectedMutant`).
            case notTested
        }

        let key: MutantKey
        let kind: Kind
        let before: String
        let after: String
        /// Its line, without the spaces around it; nil when not known.
        let line: String?
        /// Whether its line isn't known as its file changed since it was tested, or can't be read, so that a pairing
        /// without its line is counted. False when the file reads, and its change isn't on one line, which no edit
        /// to another line changes: such a mutant never has a line.
        let lineUnread: Bool

        init(
            key: MutantKey,
            kind: Kind,
            before: String,
            after: String,
            line: String? = nil,
            lineUnread: Bool? = nil
        ) {
            self.key = key
            self.kind = kind
            self.before = before
            self.after = after
            self.line = line?.trimmingCharacters(in: .whitespaces)
            self.lineUnread = lineUnread ?? (line == nil)
        }

        /// "Sources/Lint/Rules.swift:42:17 RelationalBoundary: < → <=".
        var described: String {
            "\(key): \(before) → \(after)"
        }

        /// Whether no test ran its code: one the run tested and judged not covered, or one of code coverage left out,
        /// which it didn't make.
        var isNotCovered: Bool {
            kind == .survivor(.notCovered)
        }

        /// Every mutant `outcome` tested that has a key, in its order, then each of code no test ran, which it didn't
        /// make, as a survivor not covered (`MutationTestOutcome.uncoveredMutants`), then each it left out
        /// (`MutationTestOutcome.unselectedMutants`), with its line from its original file while that is as it was
        /// tested, read by `readSource`.
        static func all(
            of outcome: MutationTestOutcome,
            readingSourcesWith readSource: @escaping ReadFile = dependency(\.readSourceFile)
        ) -> [TestedMutant] {
            var sources = ReportSources(read: readSource, digests: outcome.sourceDigests)
            let tested = outcome.mutations.compactMap { mutation -> TestedMutant? in
                guard let key = mutation.key else { return nil }
                let kind: Kind = if let survived = BaselineSurvivor.Outcome(mutation.testSuiteOutcome) {
                    .survivor(survived)
                } else if [.failed, .runtimeError].contains(mutation.testSuiteOutcome) {
                    .killed
                } else {
                    .notTested
                }
                let line = sources.change(of: mutation)?.before
                return TestedMutant(
                    key: key,
                    kind: kind,
                    before: mutation.snapshot.before,
                    after: mutation.snapshot.after,
                    line: line,
                    lineUnread: line == nil
                        && !sources.reads(mutation.originalProjectPath, relativePath: mutation.relativePath)
                )
            }
            let untested = (outcome.uncoveredMutants ?? []).map { mutant in
                (
                    UnselectedMutant(
                        key: mutant.key,
                        snapshot: mutant.snapshot,
                        originalProjectPath: RepoRelativePath.resolve(mutant.path, under: outcome.projectPath)
                    ),
                    Kind.survivor(.notCovered)
                )
            } + (outcome.unselectedMutants ?? []).map { ($0, Kind.notTested) }
            return tested + untested.map { mutant, kind in
                let line = sources.change(
                    in: mutant.originalProjectPath,
                    relativePath: mutant.key.path,
                    snapshot: mutant.snapshot,
                    mutationOperatorId: mutant.key.mutationOperatorId,
                    line: mutant.key.line,
                    column: mutant.key.column
                )?.before
                return TestedMutant(
                    key: mutant.key,
                    kind: kind,
                    before: mutant.snapshot.before,
                    after: mutant.snapshot.after,
                    line: line,
                    lineUnread: line == nil && !sources.reads(mutant.originalProjectPath, relativePath: mutant.key.path)
                )
            }
        }
    }

    /// The run's survivors no entry matched, in the run's order.
    private(set) var newSurvivors: [TestedMutant] = []
    /// The entries a run's survivor matched.
    private(set) var stillSurvive = 0
    /// The entries a killed mutant matched.
    private(set) var fixed: [BaselineSurvivor] = []
    /// The entries that matched nothing the run tested.
    private(set) var notTested: [BaselineSurvivor] = []
    /// How many pairings, of survivors and of kills, didn't compare the line, as one side's isn't known for its file:
    /// not those of a change on no one line, which never has one.
    private(set) var matchedWithoutLine = 0

    /// Pairs `entries` with `mutants`; with `exactKeysOnly`, each only at its own key, as the run left out mutants
    /// that `mutants` doesn't hold.
    init(_ entries: [BaselineSurvivor], against mutants: [TestedMutant], exactKeysOnly: Bool = false) {
        let survivorsAndUntested = mutants.indices.filter { mutants[$0].kind != .killed }
        let kills = mutants.indices.filter { mutants[$0].kind == .killed }

        var paired = Self.pair(
            Array(entries.indices),
            of: entries,
            with: survivorsAndUntested,
            of: mutants,
            exactKeysOnly: exactKeysOnly
        )
        let pairedWithASurvivor = paired.filter { mutants[$0.mutant].kind != .notTested }
        stillSurvive = pairedWithASurvivor.count
        let pairedMutants = Set(paired.map(\.mutant))
        newSurvivors = survivorsAndUntested
            .filter { mutants[$0].kind != .notTested && !pairedMutants.contains($0) }
            .map { mutants[$0] }

        let pairedEntries = Set(paired.map(\.entry))
        let fixes = Self.pair(
            entries.indices.filter { !pairedEntries.contains($0) },
            of: entries,
            with: kills,
            of: mutants,
            exactKeysOnly: exactKeysOnly
        )
        fixed = fixes.map(\.entry).sorted().map { entries[$0] }
        paired = pairedWithASurvivor + fixes
        matchedWithoutLine = paired.filter(\.withoutLine).count
        let resolved = Set(paired.map(\.entry))
        notTested = entries.indices.filter { !resolved.contains($0) }.map { entries[$0] }
    }

    /// An entry, by its index, and the mutant it was paired with, by its; and whether they were paired without the
    /// line, as one side's line isn't known for its file.
    private struct Pairing {
        let entry: Int
        let mutant: Int
        let withoutLine: Bool
    }

    /// Pairs each of `left`, indices into `entries`, with one of `candidates`, indices into `mutants`, each once, in
    /// four passes: at the entry's own key, with the line; then by its change and its line; then, where a line isn't
    /// known, at its own key by its change alone; then by its change alone. Each pass is made for every entry before
    /// the next, so an entry without a line can't take a mutant that another entry's line matches. With
    /// `exactKeysOnly`, only at the entry's own key. Gives the pairings, in the order they were made.
    private static func pair(
        _ left: [Int],
        of entries: [BaselineSurvivor],
        with candidates: [Int],
        of mutants: [TestedMutant],
        exactKeysOnly: Bool
    ) -> [Pairing] {
        var byKey: [MutantKey: Int] = [:]
        for index in candidates {
            byKey[mutants[index].key] = index
        }
        let bySignature = Dictionary(grouping: candidates) { Signature(mutants[$0]) }
        var taken: Set<Int> = []
        var pairings: [Pairing] = []
        var unpaired = left
        for withLine in [true, false] {
            for atItsKey in exactKeysOnly ? [true] : [true, false] {
                unpaired = unpaired.filter { entryIndex in
                    let entry = entries[entryIndex]
                    let options = atItsKey
                        ? byKey[entry.mutant].map { [$0] } ?? []
                        : bySignature[Signature(entry)] ?? []
                    let distance = { (index: Int) in abs(mutants[index].key.line - entry.mutant.line) }
                    let nearest = options
                        .filter {
                            !taken.contains($0) && Signature(mutants[$0]) == Signature(entry)
                                && entry.matches(mutants[$0]) == withLine
                        }
                        .min { distance($0) < distance($1) }
                    guard let nearest else { return true }
                    taken.insert(nearest)
                    pairings.append(Pairing(
                        entry: entryIndex,
                        mutant: nearest,
                        withoutLine: !withLine && entry.countsWithoutLine(mutants[nearest])
                    ))
                    return false
                }
            }
        }
        return pairings
    }

    /// What a mutant changes, but for its line: its path, operator, `before` and `after`.
    private struct Signature: Hashable {
        let path: String
        let mutationOperatorId: MutationOperator.Id
        let before: String
        let after: String

        init(_ mutant: TestedMutant) {
            path = mutant.key.path
            mutationOperatorId = mutant.key.mutationOperatorId
            before = mutant.before
            after = mutant.after
        }

        init(_ entry: BaselineSurvivor) {
            path = entry.mutant.path
            mutationOperatorId = entry.mutant.mutationOperatorId
            before = entry.before
            after = entry.after
        }
    }
}

/// A mutant a run discovered and didn't test, as `--shard`, `--sample` or `--changed-lines` left it out, which
/// `BaselineMatches` pairs a baseline file's entry for it with, so that the entry can't take a mutant the run tested.
struct UnselectedMutant: Equatable {
    let key: MutantKey
    /// What it replaces, and what with.
    let snapshot: MutationOperator.Snapshot
    /// Its file in the original project, which its line is read from.
    let originalProjectPath: String
}

/// A mutant in code no test ran, which a run with coverage makes none of, as no test could kill it: in a region no test
/// ran (`MuterVisitor.uncoveredMappings`), or in a file coverage leaves out as a whole, as one at or below
/// `coverageThreshold`, such as a new file no test reaches. No score counts it, nor any count a report shows; only a
/// baseline file records it, as a survivor not covered, and `--baseline` compares it, so a pull request that adds code
/// no test runs adds survivors. Keyed as a whole run keys mutants, so it keeps its key when a test comes to run its
/// code. With `--skip-coverage` there are none: every mutant is made and tested.
///
/// The results file's header records them, as `mutantsNotCovered`, so `report` sees what the run saw.
struct UncoveredMutant: Codable, Equatable {
    /// The key's fields (`MutantKey`).
    let path: String
    let line: Int
    let column: Int
    let occurrence: Int
    let mutationOperatorId: MutationOperator.Id
    /// What it would replace, and what with.
    let snapshot: MutationOperator.Snapshot

    init(key: MutantKey, snapshot: MutationOperator.Snapshot) {
        path = key.path
        line = key.line
        column = key.column
        occurrence = key.occurrence
        mutationOperatorId = key.mutationOperatorId
        self.snapshot = snapshot
    }

    var key: MutantKey {
        MutantKey(
            path: path,
            mutationOperatorId: mutationOperatorId,
            line: line,
            column: column,
            occurrence: occurrence
        )
    }
}

private extension BaselineSurvivor {
    /// Whether `mutant` changes what this entry's mutant changed: true when their lines are known and agree too, false
    /// when either line isn't known, and nil when they differ. Its path and operator are the caller's to compare.
    func matches(_ mutant: BaselineMatches.TestedMutant) -> Bool? {
        guard before == mutant.before, after == mutant.after else { return nil }
        guard let line, let other = mutant.line else { return false }
        return line == other ? true : nil
    }

    /// Whether pairing with `mutant` without the line is counted: unless neither has one, as `mutant`'s change isn't
    /// on one line of a file that reads, which no file's state changes.
    func countsWithoutLine(_ mutant: BaselineMatches.TestedMutant) -> Bool {
        line != nil || mutant.line != nil || mutant.lineUnread
    }
}
