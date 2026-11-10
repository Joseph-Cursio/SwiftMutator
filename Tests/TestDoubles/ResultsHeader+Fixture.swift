import Foundation
@testable import muterCore

extension Provenance {
    static var fixture: Provenance {
        Provenance(
            swiftMutator: .init(
                version: "1.0.0",
                executablePath: "/usr/local/bin/swift-mutator",
                executableSHA256: "9f2c"
            ),
            toolchain: .init(
                testCommandVersion: "Apple Swift version 6.4",
                testExecutableSHA256: nil,
                environment: ["SDKROOT": "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"]
            ),
            processIdentifier: 81_234,
            host: "host",
            arguments: ["-c", "mutation.conf.yml", "--skip-coverage"]
        )
    }
}

extension ResultsHeader {
    /// 2026-10-04T13:16:04.500Z: a whole number of milliseconds that a binary fraction holds exactly, so a header
    /// read back from a results file equals the one written.
    static let fixedStart = Date(timeIntervalSince1970: 1_791_119_764.5)

    static func make(
        formatVersion: Int = ResultsCoding.formatVersion,
        session: Int = 1,
        startedAt: Date = fixedStart,
        projectPath: String = "/project",
        mutatedProjectPath: String = "/project_mutated",
        coverage: CoverageSummary? = nil,
        newVersion: String = "",
        mutantsDiscovered: Int = 3,
        mutantsToTest: Int = 3,
        project: ProjectTree? = nil,
        projectDelta: ProjectTreeDelta? = nil,
        provenance: Provenance = .fixture,
        configuration: MuterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"]),
        operators: [String] = ["RelationalOperatorReplacement"],
        filesToMutate: [String] = [],
        skipCoverage: Bool = true,
        usingTestPlan: Bool = false,
        mutantsReused: Int? = nil,
        waived: [String]? = nil,
        forced: [String]? = nil,
        logDirectory: String = "/project_muter_logs/run",
        workers: Int = 1,
        timeoutSeconds: Double? = 96.5,
        reusedFrom: String? = nil,
        since: ChangeSelection? = nil,
        shard: ShardSelection? = nil,
        sample: SampleSelection? = nil,
        testPlan: TestPlanRecord? = nil,
        mutant: String? = nil
    ) -> ResultsHeader {
        ResultsHeader(
            formatVersion: formatVersion,
            session: session,
            startedAt: startedAt,
            provenance: provenance,
            configuration: configuration,
            operators: operators,
            filesToMutate: filesToMutate,
            skipCoverage: skipCoverage,
            usingTestPlan: usingTestPlan,
            projectPath: projectPath,
            mutatedProjectPath: mutatedProjectPath,
            logDirectory: logDirectory,
            coverage: coverage,
            newVersion: newVersion,
            baselineSeconds: 32.125,
            testRunSeconds: 19.3,
            timeoutSeconds: timeoutSeconds,
            timeoutIsDefault: true,
            workers: workers,
            stopsAtFirstFailure: false,
            failedTestLinesAreReliable: true,
            mutantsDiscovered: mutantsDiscovered,
            mutantsToTest: mutantsToTest,
            project: project,
            projectDelta: projectDelta,
            mutantsReused: mutantsReused,
            waived: waived,
            forced: forced,
            reusedFrom: reusedFrom,
            since: since,
            shard: shard,
            sample: sample,
            testPlan: testPlan,
            mutant: mutant
        )
    }
}

extension ShardSelection {
    static func make(
        index: Int = 1,
        count: Int = 2,
        mutantsInAllShards: Int = 6,
        mutantsPerShard: [Int]? = nil,
        allKeysSHA256: String = "a11"
    ) -> ShardSelection {
        ShardSelection(
            index: index,
            count: count,
            mutantsInAllShards: mutantsInAllShards,
            // As even as the total allows, the first shards taking what is left over.
            mutantsPerShard: mutantsPerShard ?? (0..<count).map {
                mutantsInAllShards / count + ($0 < mutantsInAllShards % count ? 1 : 0)
            },
            allKeysSHA256: allKeysSHA256
        )
    }
}

extension ChangeSelection {
    static func make(
        ref: String = "main",
        commit: String = "c0ffee0000000000000000000000000000000000",
        mergeBase: String = "ba5e000000000000000000000000000000000000",
        changedLines: Bool = false,
        files: [ChangedFile] = [],
        foldersNotCompared: [String] = []
    ) -> ChangeSelection {
        ChangeSelection(
            ref: ref,
            commit: commit,
            mergeBase: mergeBase,
            changedLines: changedLines,
            files: files,
            foldersNotCompared: foldersNotCompared
        )
    }
}

extension MutantResult {
    static func make(
        session: Int = 1,
        path: String = "Sources/Sum.swift",
        line: Int = 73,
        column: Int = 22,
        occurrence: Int = 0,
        utf8Offset: Int = 3_361,
        mutationOperatorId: MutationOperator.Id = .ror,
        switchID: String? = nil,
        snapshot: MutationOperator.Snapshot = .make(before: ">", after: "<", description: "changed > to <"),
        outcome: TestSuiteOutcome = .failed,
        endedBy: TestRun.Ending = .exited,
        finishedAt: Date = ResultsHeader.fixedStart.addingTimeInterval(31.25),
        killedBy: [FailedTestLine.FailedTest]? = nil,
        failedTestCount: Int? = nil,
        fileSHA256: String? = nil,
        reusedFrom: ReusedFrom? = nil,
        rerun: MutantResult.Rerun? = nil,
        keptLog: Bool = true
    ) -> MutantResult {
        MutantResult(
            session: session,
            path: path,
            line: line,
            column: column,
            occurrence: occurrence,
            utf8Offset: utf8Offset,
            mutationOperatorId: mutationOperatorId,
            switchID: switchID ?? "Sum_\(mutationOperatorId.rawValue)_\(line)_\(column)_\(utf8Offset)",
            snapshot: snapshot,
            outcome: outcome,
            endedBy: endedBy,
            exitStatus: endedBy == .exited ? (outcome == .passed ? 0 : 1) : nil,
            durationSeconds: 31.25,
            worker: 0,
            finishedAt: finishedAt,
            killedBy: killedBy,
            failedTestCount: failedTestCount ?? killedBy?.count,
            firstFailedTestLine: nil,
            log: keptLog ? "\(mutationOperatorId.rawValue) @ Sum.swift-\(line)-\(column).log" : nil,
            fileSHA256: fileSHA256,
            reusedFrom: reusedFrom,
            rerun: rerun
        )
    }
}

extension ResultsEnd {
    static func make(
        session: Int = 1,
        endedAt: Date = ResultsHeader.fixedStart.addingTimeInterval(100.5),
        reason: Reason = .finished,
        detail: String? = nil,
        testDurationSeconds: Double = 100.5,
        recorded: Int = 3
    ) -> ResultsEnd {
        ResultsEnd(
            session: session,
            endedAt: endedAt,
            reason: reason,
            detail: detail,
            testDurationSeconds: testDurationSeconds,
            recorded: recorded
        )
    }
}

/// `lines` as a results file holds them, each on a line of its own.
func resultsFileData(_ lines: [any Encodable]) throws -> Data {
    let encoder = ResultsCoding.encoder
    return try lines.reduce(into: Data()) { data, line in
        data += try encoder.encode(line) + Data("\n".utf8)
    }
}

extension ResumeState {
    /// The resume of the results file at `path`, which holds `lines`, opened as `file`; a reuse of it without one.
    static func make(
        lines: [any Encodable],
        file: ResultsRecording?,
        path: String = "/project_muter_logs/session 1/results.jsonl",
        provenance: Provenance = .fixture,
        forced: [String] = [],
        notices: [String] = []
    ) throws -> ResumeState {
        let recorded = try RecordedResults.read(resultsFileData(lines), path: path)
        guard let lastHeader = recorded.headers.last else {
            throw ResultsFileError.notAResultsFile(path: path)
        }
        return ResumeState(
            path: path,
            file: file,
            recorded: recorded,
            lastHeader: lastHeader,
            provenance: provenance,
            forced: forced,
            notices: notices
        )
    }
}

extension ControlRunResult {
    static func make(
        session: Int = 1,
        number: Int = 1,
        afterMutants: Int = 50,
        outcome: TestSuiteOutcome = .passed,
        worker: Int = 0,
        finishedAt: Date = ResultsHeader.fixedStart.addingTimeInterval(60),
        failedTests: [FailedTestLine.FailedTest]? = nil,
        failedTestCount: Int? = nil
    ) -> ControlRunResult {
        ControlRunResult(
            session: session,
            number: number,
            afterMutants: afterMutants,
            outcome: outcome,
            endedBy: .exited,
            exitStatus: outcome == .passed ? 0 : 1,
            durationSeconds: 6.9,
            worker: worker,
            finishedAt: finishedAt,
            failedTests: failedTests,
            failedTestCount: failedTestCount ?? failedTests?.count,
            firstFailedTestLine: nil,
            log: Self.logName(of: number)
        )
    }
}
