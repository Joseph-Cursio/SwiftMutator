import Foundation

typealias FileName = String
/// A file's path, absolute or relative, as a string.
public typealias FilePath = String

struct MuterTestReport: Equatable, Codable {
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
    /// What testing survivors again with the property tests came to (`propertySurvivorReruns`). nil when none was, and
    /// then left out of the JSON.
    let propertySurvivorReruns: PropertySurvivorRerunSummary?
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
        propertySurvivorReruns = PropertySurvivorRerunSummary(of: outcome.mutations)
        globalMutationScore = mutationScore(from: outcome.mutations.map(\.testSuiteOutcome))
        totalAppliedMutationOperators = outcome.mutations.count
        numberOfKilledMutants = outcome.mutations
            .count { $0.testSuiteOutcome == .failed || $0.testSuiteOutcome == .runtimeError }
        mutantsByOutcome = OutcomeCounts(outcome.mutations.map(\.testSuiteOutcome))
        projectCodeCoverage = outcome.coverage == .null ? nil : outcome.coverage.percent
        var sources = ReportSources(read: readSource, digests: outcome.sourceDigests)
        let triaged = Self.triaged(
            Self.fileReports(
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

    /// The summary, when it found suspect tests: what the reports warn of, beside the headline score.
    var suspectSummary: KillingTestSummary? {
        killingTestSummary.flatMap { $0.suspects.isEmpty ? nil : $0 }
    }

    /// The sentence every report warns of suspect tests with. nil when there are none.
    var suspectWarning: String? {
        killingTestSummary?.warning(mutationScore: globalMutationScore)
    }

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

    /// Each file's report, by path, with each kill only `suspects` were recorded failing for marked, and each mutant's
    /// line from `sources`.
    private static func fileReports(
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
                    killedOnlyBySuspectTests: KillingTestSummary.isSuspectOnlyKill(mutation, suspects: suspects),
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
                mutationScore: scores[filePath] ?? 0,
                appliedOperators: appliedOperators,
                relativePath: mutations.first?.relativePath
            )
        }

        let scoreOfFilesWithoutCoverage = outcome.coverage.filesWithoutCoverage.map { filePath in
            FileReport(
                fileName: URL(fileURLWithPath: filePath).lastPathComponent,
                path: filePath,
                mutationScore: 0,
                appliedOperators: [
                    .init(
                        mutationPoint: .null,
                        mutationSnapshot: .null,
                        testSuiteOutcome: .noCoverage
                    ),
                ],
                relativePath: outcome.relativePath(of: filePath)
            )
        }

        return scoreOfFiles + scoreOfFilesWithoutCoverage
    }

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
        case propertySurvivorReruns
        case triageSummary
        case since
        case shards
        case sample
        case mutant
        case run
        case operatorExplanations
    }
}

private extension TimeInterval {
    func formatted() -> String {
        let time = Int(self)
        let milliseconds = Int(truncatingRemainder(dividingBy: 1) * 1_000)
        let seconds = time % 60
        let minutes = (time / 60) % 60
        let hours = (time / 3_600)

        return String(
            format: "%0.2d:%0.2d:%0.2d.%0.3d",
            hours,
            minutes,
            seconds,
            milliseconds
        )
    }
}

extension MutationTestOutcome {
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
