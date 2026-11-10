import Foundation

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
            controlRuns: controlRuns,
            propertyReruns: propertyReruns
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
        controlRuns: [ControlRunResult],
        propertyReruns: [MutantKey: PropertyRerunResult] = [:]
    ) {
        let mutatedProjectDirectory = URL(fileURLWithPath: header.mutatedProjectPath, isDirectory: true)
        self.init(
            mutations: Self.mutations(of: records, under: header, propertyReruns: propertyReruns),
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
            controlRuns: controlRuns.map(Self.ControlRun.init),
            projectPath: header.projectPath,
            mutatedProjectPath: header.mutatedProjectPath,
            // A test plan's session records its rewritten copy, never the project.
            sourceDigests: header.usingTestPlan ? nil : header.project?.files
        )
        baselineScope = BaselineScope(header: header)
        filesToMutate = header.filesToMutate
        uncoveredMutants = header.knownMutantsNotCovered
    }

    /// The mutations of `records`, in the order a run tests them, under `header`'s project paths, each with its
    /// property rerun among `propertyReruns`.
    private static func mutations(
        of records: some Collection<MutantResult>,
        under header: ResultsHeader,
        propertyReruns: [MutantKey: PropertyRerunResult]
    ) -> [Mutation] {
        let projectDirectory = URL(fileURLWithPath: header.projectPath, isDirectory: true)
        let mutatedProjectDirectory = URL(fileURLWithPath: header.mutatedProjectPath, isDirectory: true)
        return records
            .map { (record: $0, order: JobOrder(of: $0, under: header.mutatedProjectPath)) }
            .sorted { $0.order < $1.order }
            .map { record, order in
                var mutation = Self.Mutation(
                    testSuiteOutcome: record.outcome.judged(activated: record.activated),
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
                mutation.propertyRerun = propertyReruns[record.key]?.rerun
                mutation.leftOutWithOthers = record.leftOutWithOthers
                mutation.activated = record.activated
                mutation.rerun = record.rerun
                return mutation
            }
    }
}
