import Foundation

/// One mutant in a report: where it is, what it changes, and what its tests did.
struct AppliedMutationOperator: Codable, Equatable {
    let mutationPoint: MutationPoint
    let mutationSnapshot: MutationOperator.Snapshot
    let testSuiteOutcome: TestSuiteOutcome
    /// The tests its run's log showed failing, as `MutationTestOutcome.Mutation` has them. Left out of the JSON
    /// when nil, so a survivor's is as it was before reports named them.
    let killingTests: MutationTestOutcome.KillingTests?
    /// Whether only suspect tests were recorded failing for it (`KillingTestSummary.isSuspectOnlyKill`). The JSON
    /// holds it as `true`, and leaves it out otherwise.
    let killedOnlyBySuspectTests: Bool
    /// Where it was tested, for a result the run reused from an earlier run (`--reuse`); left out of the JSON when
    /// nil.
    let reusedFrom: ReusedFrom?
    /// The line it changes, before and after, from its original file (`MutantDiff.change`); nil, and left out of
    /// the JSON, when the file can't be read, has changed since it was tested, or doesn't hold the change on one
    /// line.
    let sourceChange: SourceChange?
    /// Its file's path relative to the project, where `mutationPoint` gives its path in the mutated copy; nil, and
    /// left out of the JSON, for a file without coverage's row.
    let path: String?
    /// Its key's description, which `--mutant` takes: "Sources/Bar.swift:12:9 SwapTernary"; nil, and left out of
    /// the JSON, when not known.
    let key: String?
    /// How long its run took, to the millisecond; nil, and left out of the JSON, when not known.
    let durationSeconds: Double?
    /// Its label in the triage file, for a mutant that survived or timed out; nil, and left out of the JSON, for
    /// any other.
    var triage: TriageMark?

    enum CodingKeys: String, CodingKey {
        case mutationPoint
        case testSuiteOutcome
        case mutationSnapshot
        case killingTests
        case killedOnlyBySuspectTests
        case reusedFrom
        case sourceChange
        case path
        case key
        case durationSeconds
        case triage
    }

    init(
        mutationPoint: MutationPoint,
        mutationSnapshot: MutationOperator.Snapshot,
        testSuiteOutcome: TestSuiteOutcome,
        killingTests: MutationTestOutcome.KillingTests? = nil,
        killedOnlyBySuspectTests: Bool = false,
        reusedFrom: ReusedFrom? = nil,
        sourceChange: SourceChange? = nil,
        path: String? = nil,
        key: String? = nil,
        durationSeconds: Double? = nil,
        triage: TriageMark? = nil
    ) {
        self.mutationPoint = mutationPoint
        self.mutationSnapshot = mutationSnapshot
        self.testSuiteOutcome = testSuiteOutcome
        self.killingTests = killingTests
        self.killedOnlyBySuspectTests = killedOnlyBySuspectTests
        self.reusedFrom = reusedFrom
        self.sourceChange = sourceChange
        self.path = path
        self.key = key
        self.durationSeconds = durationSeconds
        self.triage = triage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mutationPoint = try container.decode(MutationPoint.self, forKey: .mutationPoint)
        testSuiteOutcome = try container.decode(TestSuiteOutcome.self, forKey: .testSuiteOutcome)
        mutationSnapshot = container.decode(
            MutationOperator.Snapshot.self,
            default: .null,
            forKey: .mutationSnapshot
        )
        // A report written before reports named killing tests has none.
        killingTests = try container.decodeIfPresent(MutationTestOutcome.KillingTests.self, forKey: .killingTests)
        killedOnlyBySuspectTests = try container.decodeIfPresent(Bool.self, forKey: .killedOnlyBySuspectTests) ?? false
        reusedFrom = try container.decodeIfPresent(ReusedFrom.self, forKey: .reusedFrom)
        sourceChange = try container.decodeIfPresent(SourceChange.self, forKey: .sourceChange)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        triage = try container.decodeIfPresent(TriageMark.self, forKey: .triage)
    }

    /// As a synthesized encoding would, key by key in `CodingKeys`' order, each nil left out, but
    /// `killedOnlyBySuspectTests` only when it is true, as when it was nil otherwise.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mutationPoint, forKey: .mutationPoint)
        try container.encode(testSuiteOutcome, forKey: .testSuiteOutcome)
        try container.encode(mutationSnapshot, forKey: .mutationSnapshot)
        try container.encodeIfPresent(killingTests, forKey: .killingTests)
        if killedOnlyBySuspectTests {
            try container.encode(true, forKey: .killedOnlyBySuspectTests)
        }
        try container.encodeIfPresent(reusedFrom, forKey: .reusedFrom)
        try container.encodeIfPresent(sourceChange, forKey: .sourceChange)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(triage, forKey: .triage)
    }

    /// What the reports' tables say of a mutant not covered, whose tests ran, where a file's row says it was skipped.
    static let notCoveredWords = "not covered"

    /// Whether this is a mutant whose code no test reached, rather than a file's row for having no coverage.
    var isANotCoveredMutant: Bool {
        testSuiteOutcome == .noCoverage && key != nil
    }

    /// Whether a person can label it (`TriageSummary`): a mutant the tests didn't kill, which they can act on.
    var takesATriageLabel: Bool {
        [.passed, .timeout].contains(testSuiteOutcome) || isANotCoveredMutant
    }

    /// Its outcome, as the reports' tables say it.
    var outcomeWords: String {
        isANotCoveredMutant ? Self.notCoveredWords : testSuiteOutcome.asMutationTestOutcome
    }

    /// The line it changes, without the spaces around it, which an entry holds: moved code may be indented anew.
    var changedLine: String? {
        sourceChange?.before.trimmingCharacters(in: .whitespaces)
    }

    /// How many characters of a test's name the plain report's tables show, and the HTML report's Killed By column.
    static let killedByNameLimit = 60

    /// `name` as those tables show it: cut at `killedByNameLimit` characters, the last of them "…".
    static func shownName(_ name: String) -> String {
        name.count > killedByNameLimit ? String(name.prefix(killedByNameLimit - 1)) + "…" : name
    }

    /// The tests recorded failing for a mutant they killed, by a failed test or a crash. nil for any other mutant: a
    /// timeout's run records an empty list.
    var killedByTests: MutationTestOutcome.KillingTests? {
        [TestSuiteOutcome.failed, .runtimeError].contains(testSuiteOutcome) ? killingTests : nil
    }

    /// What the plain and HTML reports' Killed By column shows: the first test recorded failing, its name cut at 60
    /// characters with "…", then how many more failed, and whether only suspect tests did. Never empty: CLITable
    /// drops an empty line, which misaligns every row after it.
    var killedByCell: String {
        guard let killing = killedByTests else { return "-" }
        guard let first = killing.tests.first else { return "(none named)" }
        let more = killing.count > 1 ? " (+\(killing.count - 1))" : ""
        let suspectOnly = killedOnlyBySuspectTests ? " (suspect only)" : ""
        return Self.shownName(first.name) + more + suspectOnly
    }

    /// What the plain and HTML reports' Duration column shows: "2.4 s", to a tenth of a second; "-" when not known,
    /// as for a file without coverage's row. Never empty, as `killedByCell`.
    var durationCell: String {
        durationSeconds.map(Logger.seconds) ?? "-"
    }

    /// What the plain and HTML reports' Reused column shows: "yes" for a result reused from an earlier run, and
    /// "yes, despite changes" for one that changes were let through for since it was tested (`--reuse-ignoring`,
    /// `--force-reuse`, or their `--resume` counterparts); "-" for one this run tested. Never empty, as `killedByCell`.
    var reusedCell: String {
        guard let reusedFrom else { return "-" }
        return reusedFrom.despiteChanges ? "yes, despite changes" : "yes"
    }
}
