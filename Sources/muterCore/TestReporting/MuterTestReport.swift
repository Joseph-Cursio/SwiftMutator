import Foundation

typealias FileName = String
public typealias FilePath = String

struct MuterTestReport {
    let globalMutationScore: Int
    let totalAppliedMutationOperators: Int
    let numberOfKilledMutants: Int
    /// How many mutants came to each verdict, as the progress lines count them: a crash is a kill. nil only in a report
    /// read back from one written before reports had it.
    let mutantsByOutcome: OutcomeCounts?
    let projectCodeCoverage: Int?
    let fileReports: [FileReport]
    let timeElapsed: String
    /// The tests that failed for the most killed mutants, and which are suspect. nil when no mutant a failed test
    /// killed has its tests recorded, and then left out of the JSON.
    let killingTestSummary: KillingTestSummary?
    /// The kills split between example tests and the property tests `propertyTests` picks out. nil without
    /// `propertyTests`, and then left out of the JSON.
    let propertyKillSummary: PropertyKillSummary?
    /// How far the survivors have been triaged (`TriageFile`). nil without a triage file with entries, and then left
    /// out of the JSON.
    let triageSummary: TriageSummary?
    /// What `--since` chose, when it did; left out of the JSON otherwise.
    let since: SinceScope?
    /// The shards of a `--shard` split the report covers, when it covers only some; left out of the JSON otherwise.
    let shards: ShardScope?
    /// The `--sample` the report's mutants are, when it left some out; left out of the JSON otherwise.
    let sample: SampleScope?
    /// The one mutant `--mutant` tested, by its key's description, which the score is of; left out of the JSON
    /// otherwise.
    let mutant: String?
    /// Where the results came from; left out of the JSON when not known.
    let run: RunDetails?
    /// What each operator the report's mutants used does, by its name. nil without mutants, and then left out of the
    /// JSON.
    let operatorExplanations: [String: String]?

    /// The report of `outcome`, with each mutant's line read by `readSource` from its original file.
    init(
        from outcome: MutationTestOutcome = .init(),
        readingSourcesWith readSource: @escaping ReadFile = dependency(\.readSourceFile)
    ) {
        let summary = KillingTestSummary(
            of: outcome.mutations, controlRuns: outcome.controlRuns, thresholds: outcome.suspectTestThresholds
        )
        killingTestSummary = summary
        propertyKillSummary = PropertyKillSummary(of: outcome.mutations, globs: outcome.propertyTests)
        globalMutationScore = mutationScore(from: outcome.mutations.map { $0.testSuiteOutcome })
        totalAppliedMutationOperators = outcome.mutations.count
        numberOfKilledMutants = outcome.mutations
            .count { $0.testSuiteOutcome == .failed || $0.testSuiteOutcome == .runtimeError }
        mutantsByOutcome = OutcomeCounts(outcome.mutations.map(\.testSuiteOutcome))
        projectCodeCoverage = outcome.coverage == .null ? nil : outcome.coverage.percent
        var sources = ReportSources(read: readSource, digests: outcome.sourceDigests)
        let triaged = MuterTestReport.triaged(
            MuterTestReport.fileReports(
                from: outcome,
                suspects: summary?.suspectIdentities ?? [],
                sources: &sources
            ),
            by: outcome.triage,
            following: !outcome.leavesOutSomeMutants
        )
        fileReports = triaged.fileReports
        triageSummary = triaged.summary
        timeElapsed = outcome.testDuration.formatted()
        since = outcome.since.map(SinceScope.init)
        shards = outcome.shards
        sample = SampleScope(
            outcome.sample,
            killed: numberOfKilledMutants,
            scored: outcome.mutations.count { $0.testSuiteOutcome != .buildError },
            tested: outcome.mutations.count,
            cutShort: outcome.sampleIsCutShort
        )
        mutant = outcome.mutant
        run = outcome.run
        let explained = outcome.mutations.map(\.point.mutationOperatorId).map { ($0.rawValue, $0.explanation) }
        operatorExplanations = explained.isEmpty ? nil : Dictionary(explained) { first, _ in first }
    }

    /// "One mutant chosen with --mutant (Sources/Bar.swift:12:9 SwapTernary): its score isn't the project's."
    static func oneMutantSentence(_ mutant: String) -> String {
        "One mutant chosen with --mutant (\(mutant)): its score isn't the project's."
    }
}

/// The part of the project a `--since` run mutated, as its reports say.
struct SinceScope: Codable, Equatable {
    let ref: String
    let mergeBase: String
    let changedLines: Bool

    init(_ selection: ChangeSelection) {
        ref = selection.ref
        mergeBase = selection.mergeBase
        changedLines = selection.changedLines
    }

    /// "Only the code changed since the merge base of main and HEAD (abc1234) was mutated."
    var sentence: String {
        "Only the \(changedLines ? "lines" : "files") changed since the merge base of \(ref) and HEAD "
            + "(\(mergeBase.prefix(7))) were mutated."
    }
}

/// The shards of a `--shard` split a report covers, as it says: the one a run tested, or those `report` merged when
/// some are missing.
struct ShardScope: Codable, Equatable {
    /// Sorted.
    let indices: [Int]
    let count: Int
    /// How many mutants were discovered in every shard together.
    let mutantsInAllShards: Int

    init(indices: [Int], count: Int, mutantsInAllShards: Int) {
        self.indices = indices.sorted()
        self.count = count
        self.mutantsInAllShards = mutantsInAllShards
    }

    /// The shard `selection` tested.
    init(_ selection: ShardSelection) {
        self.init(indices: [selection.index], count: selection.count, mutantsInAllShards: selection.mutantsInAllShards)
    }

    /// "shard 1 of 2", or "shards 1 and 3 of 4".
    var named: String {
        let indices = Logger.listed(indices.map(String.init))
        return (self.indices.count == 1 ? "shard " : "shards ") + "\(indices) of \(count)"
    }

    /// "Only the mutants in shard 1 of 2 were tested, of 2463 discovered in every shard." Of a `sampled` split, the
    /// shards split the sample, whose mutants they count: "…, of 500 in every shard of the sample."
    func sentence(sampled: Bool = false) -> String {
        "Only the mutants in \(named) were tested, of \(mutantsInAllShards) "
            + (sampled ? "in every shard of the sample." : "discovered in every shard.")
    }
}

extension MuterTestReport {
    /// The summary, when it found suspect tests: what the reports warn of, beside the headline score.
    var suspectSummary: KillingTestSummary? {
        killingTestSummary.flatMap { $0.suspects.isEmpty ? nil : $0 }
    }

    /// The sentence every report warns of suspect tests with. nil when there are none.
    var suspectWarning: String? {
        killingTestSummary?.warning(mutationScore: globalMutationScore)
    }
}

private extension TimeInterval {
    func formatted() -> String {
        let time = Int(self)
        let milliseconds = Int(truncatingRemainder(dividingBy: 1) * 1000)
        let seconds = time % 60
        let minutes = (time / 60) % 60
        let hours = (time / 3600)

        return String(
            format: "%0.2d:%0.2d:%0.2d.%0.3d",
            hours,
            minutes,
            seconds,
            milliseconds
        )

    }
}

extension MuterTestReport {
    struct FileReport: Codable {
        let fileName: FileName
        let path: FilePath
        /// Its path relative to the project, as every report shows it but the Xcode format; for a file outside the
        /// project, its absolute path. The JSON's `path`.
        let relativePath: String
        let mutationScore: Int
        var appliedOperators: [AppliedMutationOperator]

        enum CodingKeys: String, CodingKey {
            case fileName
            // The JSON's `path` is relative to the project; the absolute one isn't in it.
            case relativePath = "path"
            case mutationScore
            case appliedOperators
        }

        init(
            fileName: FileName,
            path: FilePath,
            relativePath: String? = nil,
            mutationScore: Int,
            appliedOperators: [AppliedMutationOperator]
        ) {
            self.fileName = fileName
            self.path = path
            self.relativePath = relativePath ?? fileName
            self.mutationScore = mutationScore
            self.appliedOperators = appliedOperators
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fileName = try container.decode(FileName.self, forKey: .fileName)
            mutationScore = try container.decode(Int.self, forKey: .mutationScore)
            appliedOperators = try container.decode([AppliedMutationOperator].self, forKey: .appliedOperators)
            path = ""
            // A report written before reports had it has the name alone.
            relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath) ?? fileName
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(fileName, forKey: .fileName)
            try container.encode(relativePath, forKey: .relativePath)
            try container.encode(mutationScore, forKey: .mutationScore)
            try container.encode(appliedOperators, forKey: .appliedOperators)
        }
    }
}

extension MuterTestReport.FileReport: Comparable {
    /// By path, as the run tests them.
    static func < (lhs: MuterTestReport.FileReport, rhs: MuterTestReport.FileReport) -> Bool {
        lhs.relativePath < rhs.relativePath
    }
}

extension MuterTestReport {
    struct AppliedMutationOperator: Codable, Equatable {
        let mutationPoint: MutationPoint
        let mutationSnapshot: MutationOperator.Snapshot
        let testSuiteOutcome: TestSuiteOutcome
        /// The tests its run's log showed failing, as `MutationTestOutcome.Mutation` has them. Left out of the JSON
        /// when nil, so a survivor's is as it was before reports named them.
        let killingTests: MutationTestOutcome.KillingTests?
        /// true when only suspect tests were recorded failing for it (`KillingTestSummary.isSuspectOnlyKill`), and
        /// otherwise nil, so left out of the JSON.
        let killedOnlyBySuspectTests: Bool?
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
            killedOnlyBySuspectTests: Bool? = nil,
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

        public init(from decoder: Decoder) throws {
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
            killedOnlyBySuspectTests = try container.decodeIfPresent(Bool.self, forKey: .killedOnlyBySuspectTests)
            reusedFrom = try container.decodeIfPresent(ReusedFrom.self, forKey: .reusedFrom)
            sourceChange = try container.decodeIfPresent(SourceChange.self, forKey: .sourceChange)
            path = try container.decodeIfPresent(String.self, forKey: .path)
            key = try container.decodeIfPresent(String.self, forKey: .key)
            durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
            triage = try container.decodeIfPresent(TriageMark.self, forKey: .triage)
        }
    }
}

private extension MuterTestReport {
    /// Each file's report, by path, with each kill only `suspects` were recorded failing for marked, and each mutant's
    /// line from `sources`.
    static func fileReports(
        from outcome: MutationTestOutcome,
        suspects: Set<FailedTestLine.TestIdentity>,
        sources: inout ReportSources
    ) -> [FileReport] {
        let outcomes = outcome.mutations
        let scores = mutationScoresOfFiles(from: outcomes)
        let byFile = Dictionary(grouping: outcomes, by: \.point.filePath)

        let scoreOfFiles = byFile.keys.sorted().map { filePath in
            let mutations = byFile[filePath] ?? []
            let appliedOperators = mutations.map { mutation in
                AppliedMutationOperator(
                    mutationPoint: mutation.point,
                    mutationSnapshot: mutation.snapshot,
                    testSuiteOutcome: mutation.testSuiteOutcome,
                    killingTests: mutation.killingTests,
                    killedOnlyBySuspectTests: KillingTestSummary.isSuspectOnlyKill(mutation, suspects: suspects)
                        ? true : nil,
                    reusedFrom: mutation.reusedFrom,
                    sourceChange: sources.change(of: mutation),
                    path: mutation.relativePath,
                    key: mutation.key?.description,
                    durationSeconds: mutation.durationSeconds
                )
            }
            return FileReport(
                fileName: URL(fileURLWithPath: filePath).lastPathComponent,
                path: filePath,
                relativePath: mutations.first?.relativePath,
                mutationScore: scores[filePath] ?? 0,
                appliedOperators: appliedOperators
            )
        }

        let scoreOfFilesWithoutCoverage = outcome.coverage.filesWithoutCoverage.map { filePath in
            FileReport(
                fileName: URL(fileURLWithPath: filePath).lastPathComponent,
                path: filePath,
                relativePath: outcome.relativePath(of: filePath),
                mutationScore: 0,
                appliedOperators: [
                    .init(
                        mutationPoint: .null,
                        mutationSnapshot: .null,
                        testSuiteOutcome: .noCoverage
                    ),
                ]
            )
        }

        return scoreOfFiles + scoreOfFilesWithoutCoverage
    }
}

private extension MutationTestOutcome {
    /// `path`, a file's in the mutated copy or in the project, relative to it; a path in neither as it is.
    func relativePath(of path: String) -> String {
        for root in [mutatedProjectPath, projectPath] where !root.isEmpty {
            let relative = RepoRelativePath.of(path, under: URL(fileURLWithPath: root, isDirectory: true))
            if !relative.hasPrefix("/") {
                return relative
            }
        }
        return path
    }
}

/// The original files the reports show mutants' lines from, each read once, and none that has changed since it was
/// tested: a mutant's line is found by its place, which an edit since would move.
struct ReportSources {
    private let read: ReadFile
    /// Each file's SHA-256 as it was tested, by its path relative to the project; nil when not recorded. A file whose
    /// hash isn't known, as one the tree doesn't hold or records as a symbolic link (`ProjectTree.linkPrefix`), may be
    /// as it was: its change is taken only where it starts at the mutant's place.
    private let digests: [String: String]?
    private var texts: [String: (text: String, verified: Bool)?] = [:]

    init(read: @escaping ReadFile, digests: [String: String]?) {
        self.read = read
        self.digests = digests
    }

    /// The line `mutation` changes, before and after; nil when its file can't be read, has changed since it was
    /// tested, or doesn't hold the change on one line.
    mutating func change(of mutation: MutationTestOutcome.Mutation) -> SourceChange? {
        guard let source = text(of: mutation) else { return nil }
        return MutantDiff.change(
            original: source.text,
            snapshot: mutation.snapshot,
            mutationOperatorId: mutation.point.mutationOperatorId,
            line: mutation.point.position.line,
            column: mutation.point.position.column,
            atItsPlaceOnly: !source.verified
        )
    }

    /// `mutation`'s original file's text, and whether its hash is the one recorded; nil when it can't be read, isn't
    /// UTF-8, or has another hash than the one recorded.
    private mutating func text(of mutation: MutationTestOutcome.Mutation) -> (text: String, verified: Bool)? {
        let path = mutation.originalProjectPath
        if let source = texts[path] {
            return source
        }
        let source = read(path).flatMap { data -> (text: String, verified: Bool)? in
            let recorded = (digests?[mutation.relativePath]
                ?? digests?[mutation.relativePath.precomposedStringWithCanonicalMapping])
                .flatMap { $0.hasPrefix(ProjectTree.linkPrefix) ? nil : $0 }
            if let recorded, recorded != FileDigest.sha256(of: data) {
                return nil
            }
            return String(data: data, encoding: .utf8).map { ($0, recorded != nil) }
        }
        texts[path] = .some(source)
        return source
    }
}

extension MuterTestReport.AppliedMutationOperator {
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
}

extension MuterTestReport {
    /// The mutants the score counts as survivors, which are the ones to act on: those the tests passed with, and
    /// those that timed out. By path, line and column.
    var survivors: [(relativePath: String, appliedOperator: AppliedMutationOperator)] {
        fileReports
            .flatMap { report in
                report.appliedOperators.map { (relativePath: report.relativePath, appliedOperator: $0) }
            }
            .filter { [.passed, .timeout].contains($0.appliedOperator.testSuiteOutcome) }
            .sorted { lhs, rhs in
                let left = lhs.appliedOperator.mutationPoint.position
                let right = rhs.appliedOperator.mutationPoint.position
                return (lhs.relativePath, left.line, left.column) < (rhs.relativePath, right.line, right.column)
            }
    }

    /// The mutants whose code no test reached, whose tests passed without running it, by path, line and column. Never a
    /// file's row for having no coverage, which has no place in it.
    var notCovered: [(relativePath: String, appliedOperator: AppliedMutationOperator)] {
        fileReports
            .flatMap { report in
                report.appliedOperators.map { (relativePath: report.relativePath, appliedOperator: $0) }
            }
            .filter(\.appliedOperator.isANotCoveredMutant)
            .sorted { lhs, rhs in
                let left = lhs.appliedOperator.mutationPoint.position
                let right = rhs.appliedOperator.mutationPoint.position
                return (lhs.relativePath, left.line, left.column) < (rhs.relativePath, right.line, right.column)
            }
    }

    /// "Sources/Foo/Rules.swift:42:17": a mutant's place, by its file's path relative to the project.
    static func place(_ appliedOperator: AppliedMutationOperator, in relativePath: String) -> String {
        let position = appliedOperator.mutationPoint.position
        return "\(relativePath):\(position.line):\(position.column)"
    }

    /// "Mutation score: 83% (98 killed, 15 survived, 4 timed out)": what a run that saved its report, and `report`
    /// that saved one, says of it. "Mutation score: none, as no mutant was tested" when none was.
    static func scoreLine(of outcome: MutationTestOutcome) -> String {
        let outcomes = outcome.mutations.map(\.testSuiteOutcome)
        guard !outcomes.isEmpty else { return "Mutation score: none, as no mutant was tested" }
        return "Mutation score: \(mutationScore(from: outcomes))% (\(OutcomeCounts(outcomes).tally))"
    }
}

extension MuterTestReport: Equatable {}
extension MuterTestReport: Codable {
    enum CodingKeys: String, CodingKey {
        case globalMutationScore
        case totalAppliedMutationOperators
        case numberOfKilledMutants
        case mutantsByOutcome
        case projectCodeCoverage
        case fileReports
        case timeElapsed
        case killingTestSummary
        case propertyKillSummary
        case triageSummary
        case since
        case shards
        case sample
        case mutant
        case run
        case operatorExplanations
    }
}
