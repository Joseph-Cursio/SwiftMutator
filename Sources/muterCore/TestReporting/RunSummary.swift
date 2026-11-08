import Foundation

/// What a script needs of a run, in one small file: how it ended, its score and its counts by outcome, how long it
/// took, and where its results came from. A run writes it as `summary.json` beside its results file when it finishes
/// or stops once its baseline has passed; one whose baseline fails, or that is stopped before then, writes none. And
/// `swift-mutator report --summary` writes one from a results file.
struct RunSummary: Codable, Equatable {
    static let fileName = "summary.json"
    /// Raised when a key is taken out or changes its meaning; a new key doesn't raise it. 2: `mutantsByOutcome`'s
    /// `survived` no longer holds mutants no test reached, which `notCovered` does.
    static let formatVersion = 2

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
    /// The report `-o` saved, or `report -o` did, or a stopped run's partial report beside it; nil when none was saved.
    let report: String?
    /// The other reports saved, in order: those `--report` or `reports:` asked for, or a stopped run's partial reports
    /// beside them, or those `report --report` saved; nil, and left out, when none was.
    let reports: [String]?
    let run: RunDetails?
    /// The verdict on the score against the threshold `--fail-under` or `failUnder` set (`ScoreGate`); nil without
    /// one.
    let gate: Gate?
    /// The verdict on the survivors against `--baseline`'s file (`NewSurvivorsCheck`); nil, and left out, without it.
    let newSurvivors: NewSurvivors?

    /// `{"failUnder": 80, "passed": false, "score": 71.42857142857143}`.
    struct Gate: Codable, Equatable {
        /// The threshold checked, a percent.
        let failUnder: Double
        /// The exact score it was compared with: the headline score, but with any mutant taken out of the build with
        /// others counted as not killed. nil when it wasn't checked, or nothing was scored.
        let score: Double?
        /// Whether it was met: the score is at or above it, or there was nothing to score; false when every mutant was
        /// a build error, or a run that didn't finish has no result yet; nil when it wasn't checked.
        let passed: Bool?
        /// Why it wasn't checked; nil when it was.
        let notChecked: ScoreGate.NotChecked?

        init(_ gate: ScoreGate) {
            failUnder = gate.failUnder
            passed = gate.passed
            score = passed == nil ? nil : gate.score
            if case let .notChecked(reason) = gate.verdict {
                notChecked = reason
            } else {
                notChecked = nil
            }
        }
    }

    /// `{"baseline": "muter.baseline.yml", "maxNewSurvivors": 0, "passed": false, "new": 2, "newMutants": [...],
    /// "newNotCovered": 1, "stillSurvive": 41, "fixed": 3, "notTested": 0, "matchedWithoutLine": 0}`.
    struct NewSurvivors: Codable, Equatable {
        /// The baseline file, as given.
        let baseline: String
        let maxNewSurvivors: Int
        /// Whether no more survivors are new than `maxNewSurvivors`; nil when they weren't compared.
        let passed: Bool?
        /// Why they weren't compared; nil when they were.
        let notChecked: NewSurvivorsCheck.NotChecked?
        /// How many survivors are new, and each by its key's description; 0 and empty when they weren't compared.
        let new: Int
        let newMutants: [String]
        /// How many of the new survivors no test ran the code of; 0 when they weren't compared.
        let newNotCovered: Int
        /// How many of the baseline file's survivors survive still, were killed, and matched nothing tested.
        let stillSurvive: Int
        let fixed: Int
        let notTested: Int
        /// How many were matched without their line, as their file had changed or couldn't be read.
        let matchedWithoutLine: Int

        init(_ check: NewSurvivorsCheck) {
            baseline = check.baseline
            maxNewSurvivors = check.maxNewSurvivors
            passed = check.passed
            switch check.verdict {
            case let .checked(comparison):
                notChecked = nil
                new = comparison.newSurvivors.count
                newMutants = comparison.newSurvivors.map(\.mutant)
                newNotCovered = comparison.newSurvivors.count(where: \.notCovered)
                stillSurvive = comparison.stillSurvive
                fixed = comparison.fixed
                notTested = comparison.notTested
                matchedWithoutLine = comparison.matchedWithoutLine
            case let .notChecked(reason):
                notChecked = reason
                new = 0
                newMutants = []
                newNotCovered = 0
                stillSurvive = 0
                fixed = 0
                notTested = 0
                matchedWithoutLine = 0
            }
        }
    }

    init(
        of outcome: MutationTestOutcome,
        ended: ResultsEnd.Reason?,
        endDetail: String? = nil,
        report: String?,
        reports: [String] = [],
        gate: ScoreGate? = nil,
        newSurvivors: NewSurvivorsCheck? = nil
    ) {
        let outcomes = outcome.mutations.map(\.testSuiteOutcome)
        let score = exactMutationScore(from: outcomes).map { Int($0) }
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
        self.reports = reports.isEmpty ? nil : reports
        run = outcome.run
        self.gate = gate.map(Gate.init)
        self.newSurvivors = newSurvivors.map(NewSurvivors.init)
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
