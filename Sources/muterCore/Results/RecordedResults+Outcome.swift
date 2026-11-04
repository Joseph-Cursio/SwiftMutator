import Foundation

/// Where a mutant comes in a session's jobs. Discovery sorts files by path (`mergeByFilePath`) and each file's mutants
/// by `InFile` (`SchemataMutationMapping.mutationSchemata`); a key's repeats come in the order they were found, which
/// their occurrences number. A results file holds mutants in the order they finished; this gives back the order the
/// run tested and reported them in.
struct JobOrder: Comparable {
    /// The absolute path, as discovery sorted it: a file outside the mutated project, whose path the results file
    /// keeps as it is, then keeps its place among the others.
    let filePath: String
    let inFile: InFile
    let occurrence: Int

    /// Where a mutant comes among its file's: by line and column, as numbers, then by operator. Not by switch ID,
    /// which holds them as text, so line 10 came before line 9, and whose format may change. Nor by offset, which
    /// counts the header and import SwiftMutator inserts: a result a resumed session kept holds the offset of the
    /// session that tested it, and the line and column, which don't move, fix the offset within a session anyway.
    struct InFile: Comparable {
        let line: Int
        let column: Int
        let mutationOperatorId: MutationOperator.Id

        static func < (lhs: InFile, rhs: InFile) -> Bool {
            (lhs.line, lhs.column, lhs.mutationOperatorId.rawValue)
                < (rhs.line, rhs.column, rhs.mutationOperatorId.rawValue)
        }
    }

    static func < (lhs: JobOrder, rhs: JobOrder) -> Bool {
        (lhs.filePath, lhs.inFile, lhs.occurrence) < (rhs.filePath, rhs.inFile, rhs.occurrence)
    }
}

extension JobOrder {
    /// Where `record`'s mutant came in the jobs of a session that mutated the project copy at `mutatedProjectPath`.
    init(of record: MutantResult, under mutatedProjectPath: String) {
        self.init(
            filePath: RepoRelativePath.resolve(record.path, under: mutatedProjectPath),
            inFile: InFile(line: record.line, column: record.column, mutationOperatorId: record.mutationOperatorId),
            occurrence: record.occurrence
        )
    }
}

extension RecordedResults {
    /// The outcome the run would have reported had it ended now: each mutant's last record, in the order the run
    /// tested them, under the latest session's project paths, coverage (or whether it skipped it) and update notice,
    /// with every session's test duration, and the run's details naming `resultsFile`, the file's path, if given. For
    /// a finished run, exactly the outcome its own report was made from.
    func mutationTestOutcome(resultsFile: String? = nil) -> MutationTestOutcome {
        // `read` refuses a file without a header.
        guard let header = headers.last else { return MutationTestOutcome() }
        var outcome = MutationTestOutcome(
            records: latest.values,
            under: header,
            testDuration: testDuration,
            shards: header.shard?.scopeAlone,
            sampleIsCutShort: latest.count < header.mutantsDiscovered,
            controlRuns: controlRuns
        )
        outcome.run = resultsFile.flatMap { RunDetails(of: [($0, headers)]) }
        return outcome
    }
}

extension MutationTestOutcome {
    /// The outcome of `records`, in the order a run tests them, under `header`'s project paths, coverage (or whether it
    /// skipped it), update notice, sample, `--mutant` and suspect-test thresholds, with `testDuration` and
    /// `controlRuns`, covering only `shards` of a split if given. The sample's results are `sampleIsCutShort` when some
    /// of the mutants its runs set out to test have none.
    init(
        records: some Collection<MutantResult>,
        under header: ResultsHeader,
        testDuration: TimeInterval,
        shards: ShardScope?,
        sampleIsCutShort: Bool,
        controlRuns: [ControlRunResult]
    ) {
        let projectDirectory = URL(fileURLWithPath: header.projectPath, isDirectory: true)
        let mutatedProjectDirectory = URL(fileURLWithPath: header.mutatedProjectPath, isDirectory: true)
        let mutations = records
            .map { (record: $0, order: JobOrder(of: $0, under: header.mutatedProjectPath)) }
            .sorted { $0.order < $1.order }
            .map { record, order in
                MutationTestOutcome.Mutation(
                    testSuiteOutcome: record.outcome,
                    mutationPoint: MutationPoint(
                        mutationOperatorId: record.mutationOperatorId,
                        filePath: order.filePath,
                        position: MutationPosition(
                            utf8Offset: record.utf8Offset,
                            line: record.line,
                            column: record.column
                        )
                    ),
                    mutationSnapshot: record.snapshot,
                    originalProjectDirectoryUrl: projectDirectory,
                    mutatedProjectDirectoryURL: mutatedProjectDirectory,
                    killingTests: .init(record),
                    reusedFrom: record.reusedFrom,
                    key: record.key,
                    durationSeconds: record.durationSeconds
                )
            }
        self.init(
            mutations: mutations,
            coverage: header.coverage.map {
                Coverage(percent: $0.percent, filesWithoutCoverage: $0.filesWithoutCoverage)
                    .limited(to: header.since, inCopyAt: mutatedProjectDirectory)
            } ?? .null,
            coverageSkipped: header.skipCoverage,
            testDuration: testDuration,
            newVersion: header.newVersion,
            since: header.since,
            shards: shards,
            sample: header.sample,
            sampleIsCutShort: sampleIsCutShort,
            mutant: header.mutant,
            suspectTestThresholds: header.configuration.suspectTestThresholds,
            propertyTests: header.configuration.propertyTests ?? [],
            controlRuns: controlRuns.map(MutationTestOutcome.ControlRun.init),
            projectPath: header.projectPath,
            mutatedProjectPath: header.mutatedProjectPath,
            // A test plan's session records its rewritten copy, never the project.
            sourceDigests: header.usingTestPlan ? nil : header.project?.files
        )
    }
}
