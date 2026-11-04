import Foundation

/// What a script needs of a run, in one small file: how it ended, its score and its counts by outcome, how long it
/// took, and where its results came from. A run writes it as `summary.json` beside its results file when it finishes
/// or stops once its baseline has passed; one whose baseline fails, or that is stopped before then, writes none. And
/// `swift-mutator report --summary` writes one from a results file.
struct RunSummary: Codable, Equatable {
    static let fileName = "summary.json"
    /// Raised when a key is taken out or changes its meaning; a new key doesn't raise it.
    static let formatVersion = 1

    var formatVersion = RunSummary.formatVersion
    /// "finished", "interrupted" or "aborted", as the results file's end line says; nil when a run's last session has
    /// no end line yet: it is still running, or was killed.
    let ended: ResultsEnd.Reason?
    /// Why it stopped early: the stopping signal's name, or the abort's short code, as the end line's `detail`.
    let endDetail: String?
    /// The headline score, as every report gives it; nil when no mutant was tested.
    let mutationScore: Int?
    /// The score without suspect tests (`KillingTestSummary`), when there are any; nil otherwise.
    let mutationScoreWithoutSuspectTests: Int?
    /// Whether `mutationScoreWithoutSuspectTests` is a lower bound; nil without it.
    let scoreWithoutSuspectsIsALowerBound: Bool?
    /// How many mutants have a result, which the score is of.
    let mutants: Int
    let mutantsByOutcome: OutcomeCounts
    /// How long mutation testing took, over every session, as the reports' "SwiftMutator took" gives it.
    let durationSeconds: Double
    /// The project's code coverage, percent; nil when it wasn't gathered.
    let codeCoverage: Int?
    /// The one mutant `--mutant` tested, by its key's description, whose score isn't the project's; nil otherwise.
    let mutant: String?
    /// The shards of a `--shard` split the summary covers, when it covers only some, so its score isn't the whole
    /// run's: the one a run tested, or those `report` merged; nil otherwise.
    let shards: ShardScope?
    /// The report `-o` saved, or `report -o` did; nil when none was saved.
    let report: String?
    let run: RunDetails?

    init(of outcome: MutationTestOutcome, ended: ResultsEnd.Reason?, endDetail: String? = nil, report: String?) {
        let outcomes = outcome.mutations.map(\.testSuiteOutcome)
        let score = outcomes.isEmpty ? nil : muterCore.mutationScore(from: outcomes)
        let suspects = KillingTestSummary(
            of: outcome.mutations,
            controlRuns: outcome.controlRuns,
            thresholds: outcome.suspectTestThresholds
        ).flatMap { $0.suspects.isEmpty ? nil : $0 }
        self.ended = ended
        self.endDetail = endDetail
        mutationScore = score
        mutationScoreWithoutSuspectTests = score.flatMap { score in
            suspects.map { $0.scoreWithoutSuspects(mutationScore: score) }
        }
        scoreWithoutSuspectsIsALowerBound = score == nil ? nil : suspects?.scoreWithoutSuspectsIsALowerBound
        mutants = outcomes.count
        mutantsByOutcome = OutcomeCounts(outcomes)
        durationSeconds = (outcome.testDuration * 1000).rounded() / 1000
        codeCoverage = outcome.coverage == .null ? nil : outcome.coverage.percent
        mutant = outcome.mutant
        shards = outcome.shards
        self.report = report
        run = outcome.run
    }

    /// Its JSON, pretty-printed with sorted keys, so two summaries diff cleanly.
    var json: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Where a run writes it: beside `resultsFile`, in the first session's log folder, which a resumed run's later
    /// sessions write it to again; without a results file, in `loggingDirectory`; nowhere without either.
    static func path(besideResultsFile resultsFile: String?, loggingDirectory: String) -> String? {
        let folder = resultsFile.map { ($0 as NSString).deletingLastPathComponent } ?? loggingDirectory
        return folder.isEmpty ? nil : (folder as NSString).appendingPathComponent(fileName)
    }
}
