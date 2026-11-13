import Foundation

extension ResultsHeader {
    /// The header of a session that tests `state`'s mutants with `configuration`, the effective configuration: the
    /// default time limit applied, and failed-test lines judged by the baseline. `logDirectory` is the session's. A
    /// session after the first is a resumed one, which says what it reused, and what `--resume-ignoring` and
    /// `--force-resume` let through. It records its project tree as what changed since the last session's, in
    /// `ResultsCoding.projectDeltaFormatVersion`, or, when that session recorded none, in full, in
    /// `resumedFormatVersion`. A session that reuses an earlier run's results is a first session, which says the same,
    /// and the file it reused from. A session whose `mutant` lines may have no `log` is in `omittedLogsFormatVersion`,
    /// whichever session it is: one that tests mutants, but for `--mutant`'s one, without `keepAllLogs`, and one that
    /// copies reused results with no `log`, `copyingLinesWithoutLogs`.
    init(
        session: Int,
        startedAt: Date,
        state: AnyMutationTestState,
        logDirectory: String,
        configuration: MuterConfiguration,
        baselineSeconds: Double?,
        workers: Int,
        mutantsDiscovered: Int,
        mutantsToTest: Int,
        provenance: Provenance,
        testRunSeconds: Double? = nil,
        mutantsReused: Int? = nil,
        waived: [String]? = nil,
        forced: [String]? = nil,
        reusedFrom: String? = nil,
        copyingLinesWithoutLogs: Bool = false
    ) {
        let lastTree = session == 1 ? nil : state.resumeState?.lastHeader.project
        let projectDelta = state.projectTree.flatMap { tree in
            lastTree.map { ProjectTreeDelta(from: $0, to: tree) }
        }
        let omitsLogs = copyingLinesWithoutLogs
            || mutantsToTest > 0 && state.selectedMutant == nil && !state.muterConfiguration.keepsAllLogs
        self.init(
            formatVersion: Self.formatVersion(session: session, projectDelta: projectDelta, omitsLogs: omitsLogs),
            session: session,
            startedAt: startedAt,
            provenance: provenance,
            configuration: state.muterConfiguration,
            operators: state.mutationOperatorList.map(\.rawValue).sorted(),
            filesToMutate: state.filesToMutate,
            skipCoverage: state.runOptions.skipCoverage,
            usingTestPlan: state.runOptions.isUsingTestPlan,
            projectPath: state.projectDirectoryURL.path,
            mutatedProjectPath: state.mutatedProjectDirectoryURL.path,
            logDirectory: logDirectory,
            coverage: CoverageSummary(state.projectCoverage),
            newVersion: state.newVersion,
            baselineSeconds: baselineSeconds,
            testRunSeconds: testRunSeconds,
            timeoutSeconds: configuration.testSuiteTimeout,
            timeoutIsDefault: state.muterConfiguration.testSuiteTimeout == nil,
            workers: workers,
            stopsAtFirstFailure: configuration.stopsAtFirstFailure,
            failedTestLinesAreReliable: configuration.failedTestLinesAreReliable,
            failedTestLookalikes: configuration.failedTestLookalikes.isEmpty
                ? nil : configuration.failedTestLookalikes.sorted(),
            mutantsDiscovered: mutantsDiscovered,
            mutantsToTest: mutantsToTest,
            mutantsDropped: state.droppedMutants.isEmpty ? nil : state.droppedMutants.count,
            project: projectDelta == nil ? state.projectTree : nil,
            projectDelta: projectDelta,
            mutantsReused: mutantsReused,
            waived: waived,
            forced: forced,
            testBundlesRunDirectly: configuration.directTestRun != nil,
            configurationWorkedOut: state.muterConfiguration.workedOut,
            reusedFrom: reusedFrom,
            since: state.changeSelection,
            shard: state.shardSelection,
            sample: state.sampleSelection,
            testPlan: state.testPlan.map(TestPlanRecord.init),
            mutant: state.selectedMutant?.description,
            mutantsNotCovered: state.runOptions.skipCoverage ? nil : state.uncoveredMutants
        )
    }

    /// The format of session `session`'s header, which records `projectDelta` if it has one, and whose `mutant` lines
    /// may have no `log` if it `omitsLogs`.
    private static func formatVersion(session: Int, projectDelta: ProjectTreeDelta?, omitsLogs: Bool) -> Int {
        if omitsLogs {
            ResultsCoding.omittedLogsFormatVersion
        } else if session == 1 {
            ResultsCoding.formatVersion
        } else {
            projectDelta == nil ? ResultsCoding.resumedFormatVersion : ResultsCoding.projectDeltaFormatVersion
        }
    }
}
