/// A run's survivors, which `--write-baseline` saves and `--baseline` compares a later run's with
/// (`NewSurvivorsCheck`), so a pull request's job fails on a survivor it adds and not on those the project already
/// had. Meant to be committed as `muter.baseline.yml` at the project's root, which `ProjectTree` leaves out, as it does
/// `muter.triage.yml`, so committing a new one refuses no `--resume` and tests nothing again in a `--reuse`.
///
/// Only a whole run's results make one: one that leaves some mutants out would record their survivors as gone. It
/// records the score's counts too, as `ScoreGate` takes them, and what a later run must share for its mutants to be
/// comparable (`BaselineScope`). Saved sorted, so a commit's diff shows only what changed; read strictly, as a file a
/// person may edit by hand, so a misspelled key isn't taken for an absent one.
struct BaselineFile: Equatable {
    /// The name the README recommends, at the project's root.
    static let fileName = "muter.baseline.yml"
    /// Raised when a key is taken out or changes its meaning. A file of a newer format is refused, as its keys may
    /// mean what this SwiftMutator can't tell.
    static let formatVersion = 1
    /// The comment a saved file starts with, which loading it drops.
    static let introduction = "# Written by swift-mutator --write-baseline. Commit it, and compare runs with it with "
        + "--baseline."

    /// The score's counts, as `ScoreGate` takes them: the mutants killed, and those scored, including any taken out
    /// of the build with others, which count as not killed.
    struct Score: Codable, Equatable {
        let killed: Int
        let scored: Int
    }

    /// Where it was read from, or is saved to, as given.
    let path: String
    let formatVersion: Int
    /// The SwiftMutator version that tested the run, as its results header records it.
    let swiftMutator: String
    let score: Score
    let scope: BaselineScope
    let survivors: [BaselineSurvivor]

    init(
        path: String,
        swiftMutator: String,
        score: Score,
        scope: BaselineScope,
        survivors: [BaselineSurvivor],
        formatVersion: Int = Self.formatVersion
    ) {
        self.path = path
        self.formatVersion = formatVersion
        self.swiftMutator = swiftMutator
        self.score = score
        self.scope = scope
        self.survivors = survivors
    }

    /// The baseline file of `outcome`'s survivors, to save at `path`, whose scope is `scope`, tested by SwiftMutator
    /// `version`: every mutant it tested that the tests didn't kill, with its line from its original file while that
    /// is as it was tested (`ReportSources`), read by `readSource`.
    init(
        of outcome: MutationTestOutcome,
        scope: BaselineScope,
        version: String,
        path: String,
        readingSourcesWith readSource: @escaping ReadFile = dependency(\.readSourceFile)
    ) {
        let gate = ScoreGate(failUnder: 0, judging: outcome)
        let survivorsFound = BaselineMatches.TestedMutant.all(of: outcome, readingSourcesWith: readSource)
            .compactMap { mutant -> BaselineSurvivor? in
                guard case let .survivor(how) = mutant.kind else { return nil }
                return BaselineSurvivor(
                    mutant: mutant.key,
                    outcome: how,
                    before: mutant.before,
                    after: mutant.after,
                    line: mutant.line
                )
            }
        self.init(
            path: path,
            swiftMutator: version,
            score: Score(killed: gate.killed, scored: gate.scored),
            scope: scope,
            survivors: survivorsFound
        )
    }
}
