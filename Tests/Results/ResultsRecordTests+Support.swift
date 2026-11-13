@testable import muterCore
import XCTest

extension ResultsRecordTests {
    /// When the fixture's session started.
    /// 2026-10-04T13:16:04.500Z and 2026-10-04T13:18:02.125Z: whole numbers of milliseconds that binary fractions
    /// hold exactly, so records with them compare equal once read back.
    var startedAt: Date { Date(timeIntervalSince1970: 1_791_119_764.5) }
    /// When the fixture's session finished; see `startedAt`.
    var finishedAt: Date { Date(timeIntervalSince1970: 1_791_119_882.125) }
    /// The copy the fixture's mutants were tested in.
    var mutatedRoot: URL { URL(fileURLWithPath: "/project_mutated") }

    func line(_ record: some Encodable) throws -> String {
        try XCTUnwrap(String(data: ResultsCoding.encoder.encode(record), encoding: .utf8))
    }

    func decode<Record: Decodable>(_ type: Record.Type, from line: String) throws -> Record {
        try ResultsCoding.decoder.decode(type, from: Data(line.utf8))
    }

    /// `line` with a key no reader knows yet, holding a value of every JSON type.
    func withKeyAddedLater(to line: String) -> String {
        #"{"addedLater":{"list":[1,"two",null,true,{"three":3.5}]},"# + line.dropFirst()
    }

    func makeSchema() throws -> MutationSchema {
        try MutationSchema.make(
            filePath: "/project_mutated/Sources/Sum.swift",
            mutationOperatorId: .ror,
            position: MutationPosition(utf8Offset: 3_361, line: 73, column: 22),
            snapshot: .make(before: ">", after: "<", description: "changed > to <"),
            under: mutatedRoot
        )
    }

    /// The record of `run`, whose failed-test lines are reliable, as mutation testing makes it.
    func makeRecord(from run: TestRun, seconds: TimeInterval = 1) throws -> MutantResult {
        let schema = try makeSchema()
        return try MutantResult(
            key: XCTUnwrap(MutantKey.keys(for: [schema], under: mutatedRoot).first),
            schema: schema,
            finished: FinishedRun(index: 0, worker: 0, run: run, seconds: seconds),
            failures: MutantResult.failedTests(of: run),
            session: 1,
            finishedAt: finishedAt,
            log: "RelationalOperatorReplacement @ Sum.swift-73-22.log"
        )
    }

    /// The results file reference's example.
    func makeMutantRecord(
        outcome: TestSuiteOutcome = .failed,
        exitStatus: Int32? = 1,
        snapshot: MutationOperator.Snapshot = .make(before: ">", after: "<", description: "changed > to <"),
        killedBy: [FailedTestLine.FailedTest]? = [
            FailedTestLine.FailedTest(
                name: "detectsExecutableTargets()",
                location: "ExecutableTargetDetectorTests.swift:41:9"
            ),
        ],
        failedTestCount: Int? = 3,
        firstFailedTestLine: String? = "✘ Test detectsExecutableTargets() recorded an issue at "
            + "ExecutableTargetDetectorTests.swift:41:9: Expectation failed",
        fileSHA256: String? = nil
    ) -> MutantResult {
        MutantResult(
            session: 1,
            path: "Packages/Core/Sources/Core/ExecutableTargetDetector.swift",
            line: 73,
            column: 22,
            occurrence: 0,
            utf8Offset: 3_361,
            mutationOperatorId: .ror,
            switchID: "ExecutableTargetDetector_1202e16ea88d5e02_RelationalOperatorReplacement_73_22_3361",
            snapshot: snapshot,
            outcome: outcome,
            endedBy: .exited,
            exitStatus: exitStatus,
            durationSeconds: 31.207,
            worker: 2,
            finishedAt: finishedAt,
            killedBy: killedBy,
            failedTestCount: failedTestCount,
            firstFailedTestLine: firstFailedTestLine,
            log: "RelationalOperatorReplacement @ ExecutableTargetDetector.swift-73-22.log",
            fileSHA256: fileSHA256
        )
    }

    func makeHeader(
        coverage: CoverageSummary? = CoverageSummary(percent: 87, filesWithoutCoverage: ["Sources/Untested.swift"]),
        baselineSeconds: Double? = 32.104,
        testRunSeconds: Double? = 10.75,
        timeoutSeconds: Double? = 86,
        project: ProjectTree? = .init(
            listedBy: .git,
            files: ["Package.swift": "3f1a", "Sources/Core/Walker.swift": "c07e", "README.md": "link:9d42"],
            excluded: ["mutation-report.partial.txt", "mutation-report.txt"],
            treeSHA256: "e5b8"
        ),
        provenance: Provenance = .fixture,
        mutantsReused: Int? = nil,
        waived: [String]? = nil,
        forced: [String]? = nil
    ) -> ResultsHeader {
        ResultsHeader(
            formatVersion: ResultsCoding.formatVersion,
            session: 1,
            startedAt: startedAt,
            provenance: provenance,
            configuration: MuterConfiguration(
                executable: "/Users/me/.swiftly/bin/swift",
                arguments: ["test", "--skip", "ParallelListDriftDogfoodTests"],
                mutationTestWorkers: 4
            ),
            operators: ["ChangeLogicalConnector", "RelationalOperatorReplacement"],
            filesToMutate: [],
            skipCoverage: false,
            usingTestPlan: false,
            projectPath: "/Users/me/Project",
            mutatedProjectPath: "/Users/me/Project_mutated",
            logDirectory: "/Users/me/Project_muter_logs/Oct 4, 2026 at 1:16 PM",
            coverage: coverage,
            newVersion: "",
            baselineSeconds: baselineSeconds,
            testRunSeconds: testRunSeconds,
            timeoutSeconds: timeoutSeconds,
            timeoutIsDefault: true,
            workers: 4,
            stopsAtFirstFailure: false,
            failedTestLinesAreReliable: true,
            mutantsDiscovered: 2_497,
            mutantsToTest: 2_497,
            project: project,
            mutantsReused: mutantsReused,
            waived: waived,
            forced: forced
        )
    }

    func makeProjectTree() -> ProjectTree {
        let files = ["Sources/Sum.swift": "5a1c", "README.md": "0b9d"]
        return ProjectTree(listedBy: .walk, files: files, excluded: [], treeSHA256: ProjectTree.treeHash(of: files))
    }

    func makeEnd(
        endedAt: Date = Date(timeIntervalSince1970: 1_791_122_531.125),
        reason: ResultsEnd.Reason = .aborted,
        detail: String? = "tooManyBuildErrors"
    ) -> ResultsEnd {
        ResultsEnd(
            session: 1,
            endedAt: endedAt,
            reason: reason,
            detail: detail,
            testDurationSeconds: 2_766.493,
            recorded: 1_103
        )
    }
}
