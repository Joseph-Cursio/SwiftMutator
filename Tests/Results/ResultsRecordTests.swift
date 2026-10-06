@testable import muterCore
import XCTest

final class ResultsRecordTests: XCTestCase {
    /// 2026-10-04T13:16:04.500Z and 2026-10-04T13:18:02.125Z: whole numbers of milliseconds that binary fractions
    /// hold exactly, so records with them compare equal once read back.
    private let startedAt = Date(timeIntervalSince1970: 1_791_119_764.5)
    private let finishedAt = Date(timeIntervalSince1970: 1_791_119_882.125)
    private let mutatedRoot = URL(fileURLWithPath: "/project_mutated")

    func test_aMutantRecordRoundTrips() throws {
        let record = makeMutantRecord(fileSHA256: "404db321")

        XCTAssertEqual(try decode(MutantResult.self, from: line(record)), record)
    }

    func test_aHeaderAndAnEndRecordRoundTrip() throws {
        let header = makeHeader()
        let headerWithoutAProject = makeHeader(project: nil)
        let end = makeEnd()

        XCTAssertEqual(try decode(ResultsHeader.self, from: line(header)), header)
        XCTAssertEqual(try decode(ResultsHeader.self, from: line(headerWithoutAProject)), headerWithoutAProject)
        XCTAssertEqual(try decode(ResultsEnd.self, from: line(end)), end)
    }

    func test_eachRecordSaysItsKind() throws {
        XCTAssertEqual(try decode(ResultsCoding.Kind.self, from: line(makeHeader())).kind, "header")
        XCTAssertEqual(try decode(ResultsCoding.Kind.self, from: line(makeMutantRecord())).kind, "mutant")
        XCTAssertEqual(try decode(ResultsCoding.Kind.self, from: line(makeEnd())).kind, "end")
    }

    func test_aRecordIsOneLine_evenWithLineBreaksInItsSnapshot() throws {
        let record = makeMutantRecord(
            snapshot: .make(
                before: "if a {\n    b()\r\n}",
                after: "if a {\n}\u{2028}",
                description: "removed\tb()\u{1B}[0m"
            ),
            firstFailedTestLine: "✘ Test sum() recorded an issue at SumTests.swift:12:5: \"a\nb\""
        )

        let data = try ResultsCoding.encoder.encode(record)

        XCTAssertFalse(data.contains(UInt8(ascii: "\n")))
        XCTAssertFalse(data.contains(UInt8(ascii: "\r")))
        XCTAssertFalse(data.contains(0x1B))
        XCTAssertEqual(try ResultsCoding.decoder.decode(MutantResult.self, from: data), record)
    }

    func test_keysAreSorted_andSlashesAreNotEscaped() throws {
        XCTAssertEqual(
            try line(makeMutantRecord()),
            [
                #"{"column":22,"durationSeconds":31.207,"endedBy":"exited","exitStatus":1,"failedTestCount":3,"#,
                #""finishedAt":"2026-10-04T13:18:02.125Z","#,
                #""firstFailedTestLine":"✘ Test detectsExecutableTargets() recorded an issue at "#,
                #"ExecutableTargetDetectorTests.swift:41:9: Expectation failed","#,
                #""killedBy":[{"location":"ExecutableTargetDetectorTests.swift:41:9","#,
                #""name":"detectsExecutableTargets()"}],"kind":"mutant","line":73,"#,
                #""log":"RelationalOperatorReplacement @ ExecutableTargetDetector.swift-73-22.log","#,
                #""mutationOperatorId":"RelationalOperatorReplacement","occurrence":0,"outcome":"failed","#,
                #""path":"Packages/Core/Sources/Core/ExecutableTargetDetector.swift","session":1,"#,
                #""snapshot":{"after":"<","before":">","description":"changed > to <"},"#,
                #""switchID":"ExecutableTargetDetector_RelationalOperatorReplacement_73_22_3361","#,
                #""utf8Offset":3361,"worker":2}"#,
            ].joined()
        )
        XCTAssertEqual(
            try line(makeEnd()),
            [
                #"{"detail":"tooManyBuildErrors","endedAt":"2026-10-04T14:02:11.125Z","kind":"end","#,
                #""reason":"aborted","recorded":1103,"session":1,"testDurationSeconds":2766.493}"#,
            ].joined()
        )

        let header = try line(makeHeader())
        XCTAssertTrue(header.contains(#""projectPath":"/Users/me/Project""#), header)
        XCTAssertFalse(header.contains(#"\/"#), header)
    }

    func test_datesKeepMilliseconds() throws {
        // No binary fraction is .004 exactly, so a date read back from it is a hair under it.
        let end = makeEnd(endedAt: Date(timeIntervalSince1970: 1_791_122_531.004))

        let written = try line(end)
        let readBack = try decode(ResultsEnd.self, from: written)

        XCTAssertTrue(written.contains(#""endedAt":"2026-10-04T14:02:11.004Z""#), written)
        XCTAssertEqual(readBack.endedAt.timeIntervalSince1970, 1_791_122_531.004, accuracy: 0.000_01)
        XCTAssertEqual(try line(readBack), written, "a date read back is written as it was")
    }

    func test_datesAreRoundedToTheNearestMillisecond() throws {
        XCTAssertTrue(
            try line(makeEnd(endedAt: Date(timeIntervalSince1970: 1_791_122_531.0006)))
                .contains(#""endedAt":"2026-10-04T14:02:11.001Z""#)
        )
        XCTAssertTrue(
            try line(makeEnd(endedAt: Date(timeIntervalSince1970: 1_791_122_531.9996)))
                .contains(#""endedAt":"2026-10-04T14:02:12.000Z""#)
        )
    }

    func test_datesWithoutFractionalSeconds_areRead() throws {
        let written = try line(makeEnd()).replacingOccurrences(of: "14:02:11.125Z", with: "14:02:11Z")

        XCTAssertEqual(
            try decode(ResultsEnd.self, from: written).endedAt,
            Date(timeIntervalSince1970: 1_791_122_531)
        )
    }

    func test_nilFieldsAreLeftOut() throws {
        let record = try line(
            makeMutantRecord(
                outcome: .passed,
                exitStatus: nil,
                killedBy: nil,
                failedTestCount: nil,
                firstFailedTestLine: nil
            )
        )
        let header = try line(
            makeHeader(
                coverage: nil,
                baselineSeconds: nil,
                timeoutSeconds: nil,
                project: nil,
                provenance: Provenance(
                    swiftMutator: .init(version: "1.0.0", executablePath: nil, executableSHA256: nil),
                    toolchain: .init(testCommandVersion: nil, testExecutableSHA256: nil, environment: [:]),
                    processIdentifier: 81234,
                    host: "host",
                    arguments: []
                )
            )
        )
        let end = try line(makeEnd(reason: .finished, detail: nil))
        let location = try line(FailedTestLine.FailedTest(name: "-[SumTests testSum]", location: nil))

        for key in ["exitStatus", "killedBy", "failedTestCount", "firstFailedTestLine", "fileSHA256"] {
            XCTAssertFalse(record.contains("\"\(key)\""), "\(key) in \(record)")
        }
        for key in [
            "coverage", "baselineSeconds", "timeoutSeconds", "executablePath", "executableSHA256",
            "testCommandVersion", "testExecutableSHA256", "mutationTestTimeout", "buildSystem", "project",
        ] {
            XCTAssertFalse(header.contains("\"\(key)\""), "\(key) in \(header)")
        }
        XCTAssertFalse(end.contains(#""detail""#), end)
        XCTAssertEqual(location, #"{"name":"-[SumTests testSum]"}"#)
        for written in [record, header, end] {
            XCTAssertFalse(written.contains("null"), written)
        }
    }

    func test_unknownKeysAreIgnored() throws {
        let record = makeMutantRecord()
        let header = makeHeader()
        let end = makeEnd()

        XCTAssertEqual(try decode(MutantResult.self, from: withKeyAddedLater(to: line(record))), record)
        XCTAssertEqual(try decode(ResultsHeader.self, from: withKeyAddedLater(to: line(header))), header)
        XCTAssertEqual(try decode(ResultsEnd.self, from: withKeyAddedLater(to: line(end))), end)
        XCTAssertEqual(
            try decode(
                MutantResult.self,
                from: line(record).replacingOccurrences(of: #""snapshot":{"#, with: #""snapshot":{"addedLater":1,"#)
            ),
            record
        )
    }

    func test_aMutantRecordFromARun() throws {
        let log = """
        ◇ Test run started.
        ✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: sum(1, 2) == 3
        ✘ Test product() recorded an issue at ProductTests.swift:8:9: Expectation failed
        ✘ Test sum() recorded an issue at SumTests.swift:13:5: Expectation failed
        ✘ Test run with 2 tests in 2 suites failed after 0.1 seconds with 3 issues.
        """
        let schema = try makeSchema()
        let key = try XCTUnwrap(MutantKey.keys(for: [schema, schema], under: mutatedRoot).last)

        let record = MutantResult(
            key: key,
            schema: schema,
            finished: FinishedRun(
                index: 4,
                worker: 2,
                run: TestRun(outcome: .failed, testLog: log, ending: .exited, exitStatus: 1),
                seconds: 31.2071
            ),
            configuration: MuterConfiguration(),
            session: 1,
            finishedAt: finishedAt,
            log: "RelationalOperatorReplacement @ Sum.swift-73-22.log"
        )

        XCTAssertEqual(
            record,
            MutantResult(
                session: 1,
                path: "Sources/Sum.swift",
                line: 73,
                column: 22,
                occurrence: 1,
                utf8Offset: 3361,
                mutationOperatorId: .ror,
                switchID: "Sum_RelationalOperatorReplacement_73_22_3361",
                snapshot: .make(before: ">", after: "<", description: "changed > to <"),
                outcome: .failed,
                endedBy: .exited,
                exitStatus: 1,
                durationSeconds: 31.207,
                worker: 2,
                finishedAt: finishedAt,
                killedBy: [
                    FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:12:5"),
                    FailedTestLine.FailedTest(name: "product()", location: "ProductTests.swift:8:9"),
                ],
                failedTestCount: 2,
                firstFailedTestLine: "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: sum(1, 2) == 3",
                log: "RelationalOperatorReplacement @ Sum.swift-73-22.log",
                fileSHA256: nil
            )
        )
    }

    func test_aMutantRecordFromARun_namesTheTestsACrashOrATimeoutShows() throws {
        let log = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Caught error\nFatal error: boom"

        let crash = try makeRecord(from: TestRun(outcome: .runtimeError, testLog: log, ending: .exited, exitStatus: 5))
        let timeout = try makeRecord(from: TestRun(outcome: .timeout, testLog: "◇ Test run started.", ending: .timedOut))

        XCTAssertEqual(crash.killedBy, [FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:12:5")])
        XCTAssertEqual(crash.failedTestCount, 1)
        XCTAssertEqual(timeout.killedBy, [])
        XCTAssertEqual(timeout.failedTestCount, 0)
        XCTAssertNil(timeout.firstFailedTestLine)
    }

    func test_aMutantRecordFromARun_namesNoTestsForASurvivorOrABuildError() throws {
        let log = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed"

        for outcome in [TestSuiteOutcome.passed, .buildError, .noCoverage] {
            let record = try makeRecord(from: TestRun(outcome: outcome, testLog: log, ending: .exited, exitStatus: 0))

            XCTAssertNil(record.killedBy, "\(outcome)")
            XCTAssertNil(record.failedTestCount, "\(outcome)")
            XCTAssertNil(record.firstFailedTestLine, "\(outcome)")
        }
    }

    func test_aMutantRecordFromARun_namesNoTestsWhenFailedTestLinesAreUnreliable() throws {
        let log = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed"

        let record = try makeRecord(
            from: TestRun(outcome: .failed, testLog: log, ending: .exited, exitStatus: 1),
            configuration: MuterConfiguration().withUnreliableFailedTestLines()
        )

        XCTAssertNil(record.killedBy)
        XCTAssertNil(record.failedTestCount)
        XCTAssertNil(record.firstFailedTestLine)
    }

    func test_aMutantRecordFromARun_roundsItsDurationToTheMillisecond_andHasAnExitStatusOnlyIfItExited() throws {
        let exited = try makeRecord(
            from: TestRun(outcome: .runtimeError, testLog: "", ending: .exited, exitStatus: 9),
            seconds: 1.23456
        )

        XCTAssertEqual(exited.durationSeconds, 1.235)
        XCTAssertEqual(exited.exitStatus, 9)
        XCTAssertEqual(exited.endedBy, .exited)
        for ending in [TestRun.Ending.timedOut, .stoppedAtFailedTest, .couldNotRun] {
            let record = try makeRecord(
                from: TestRun(outcome: .failed, testLog: "", ending: ending, exitStatus: 9),
                seconds: 0.0004
            )

            XCTAssertNil(record.exitStatus, "\(ending)")
            XCTAssertEqual(record.endedBy, ending)
            XCTAssertEqual(record.durationSeconds, 0)
        }
    }

    func test_aHeaderFromARunsState_keepsTheConfigurationAsLoaded_andTheEffectiveSettingsBesideIt() {
        let state = MutationTestState(
            from: .make(
                filesToMutate: ["Sum.swift"],
                mutationOperatorsList: [.ror, .logicalOperator],
                skipCoverage: true
            )
        )
        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = mutatedRoot
        state.newVersion = "9.9.9"
        state.projectCoverage = .make(percent: 87, filesWithoutCoverage: ["/project_mutated/Sources/Untested.swift"])
        let loaded = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            mutationTestWorkers: 4,
            stopAtFirstFailure: true
        )
        state.muterConfiguration = loaded
        let project = makeProjectTree()
        state.projectTree = project
        let effective = loaded.withUnreliableFailedTestLines().withDefaultTestSuiteTimeout(96.5)

        let header = ResultsHeader(
            session: 1,
            startedAt: startedAt,
            state: state,
            logDirectory: "/project_muter_logs/run",
            configuration: effective,
            baselineSeconds: 32.125,
            workers: 4,
            mutantsDiscovered: 7,
            mutantsToTest: 7,
            provenance: .fixture
        )

        XCTAssertEqual(
            header,
            ResultsHeader(
                formatVersion: 1,
                session: 1,
                startedAt: startedAt,
                provenance: .fixture,
                configuration: loaded,
                operators: ["ChangeLogicalConnector", "RelationalOperatorReplacement"],
                filesToMutate: ["Sum.swift"],
                skipCoverage: true,
                usingTestPlan: false,
                projectPath: "/project",
                mutatedProjectPath: "/project_mutated",
                logDirectory: "/project_muter_logs/run",
                coverage: CoverageSummary(percent: 87, filesWithoutCoverage: ["/project_mutated/Sources/Untested.swift"]),
                newVersion: "9.9.9",
                baselineSeconds: 32.125,
                timeoutSeconds: 96.5,
                timeoutIsDefault: true,
                workers: 4,
                stopsAtFirstFailure: false,
                failedTestLinesAreReliable: false,
                mutantsDiscovered: 7,
                mutantsToTest: 7,
                project: project
            )
        )
        XCTAssertEqual(header.kind, "header")
    }

    func test_aHeaderFromARunsState_withAConfiguredTimeLimit_aTestPlanAndNoCoverage() {
        let state = MutationTestState(from: .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json")))
        let loaded = MuterConfiguration(executable: "/usr/bin/swift", testSuiteTimeOut: 60, stopAtFirstFailure: true)
        state.muterConfiguration = loaded

        let header = ResultsHeader(
            session: 1,
            startedAt: startedAt,
            state: state,
            logDirectory: "/logs",
            configuration: loaded.withDefaultTestSuiteTimeout(96.5),
            baselineSeconds: 32.125,
            workers: 1,
            mutantsDiscovered: 3,
            mutantsToTest: 3,
            provenance: .fixture
        )

        XCTAssertEqual(header.timeoutSeconds, 60)
        XCTAssertFalse(header.timeoutIsDefault)
        XCTAssertTrue(header.usingTestPlan)
        XCTAssertNil(header.coverage)
        XCTAssertNil(header.project)
        XCTAssertTrue(header.stopsAtFirstFailure)
        XCTAssertTrue(header.failedTestLinesAreReliable)
    }

    func test_endDetail_namesTheAbortReason() {
        XCTAssertEqual(
            ResultsEnd.detail(for: MuterError.mutationTestingAborted(reason: .tooManyBuildErrors)),
            "tooManyBuildErrors"
        )
        XCTAssertEqual(
            ResultsEnd.detail(
                for: MuterError.mutationTestingAborted(
                    reason: .workerBaselineTestFailed(worker: 2, directory: "/project_mutated_worker2", log: "the log")
                )
            ),
            "workerBaselineTestFailed(worker: 2)"
        )
        XCTAssertEqual(
            ResultsEnd.detail(
                for: MuterError.mutationTestingAborted(reason: .baselineTestFailed(log: "the log", mutatedFilePaths: []))
            ),
            "baselineTestFailed"
        )
        XCTAssertEqual(
            ResultsEnd.detail(for: MuterError.mutationTestingAborted(reason: .unknownError(description: "the log"))),
            "unknownError"
        )
        XCTAssertEqual(ResultsEnd.detail(for: MuterError.noMutationPointsDiscovered), "MuterError")
        XCTAssertEqual(
            ResultsEnd.detail(for: PerformMutationTesting.WorkerDirectoryError(clone: mutatedRoot, status: 1)),
            "WorkerDirectoryError"
        )
        XCTAssertNil(ResultsEnd.detail(for: CancellationError()))
    }
}

private extension ResultsRecordTests {
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
            position: MutationPosition(utf8Offset: 3361, line: 73, column: 22),
            snapshot: .make(before: ">", after: "<", description: "changed > to <")
        )
    }

    func makeRecord(
        from run: TestRun,
        seconds: TimeInterval = 1,
        configuration: MuterConfiguration = MuterConfiguration()
    ) throws -> MutantResult {
        let schema = try makeSchema()
        return try MutantResult(
            key: XCTUnwrap(MutantKey.keys(for: [schema], under: mutatedRoot).first),
            schema: schema,
            finished: FinishedRun(index: 0, worker: 0, run: run, seconds: seconds),
            configuration: configuration,
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
            utf8Offset: 3361,
            mutationOperatorId: .ror,
            switchID: "ExecutableTargetDetector_RelationalOperatorReplacement_73_22_3361",
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
        timeoutSeconds: Double? = 96.312,
        project: ProjectTree? = .init(
            listedBy: .git,
            files: ["Package.swift": "3f1a", "Sources/Core/Walker.swift": "c07e", "README.md": "link:9d42"],
            excluded: ["mutation-report.partial.txt", "mutation-report.txt"],
            treeSHA256: "e5b8"
        ),
        provenance: Provenance = .fixture
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
            timeoutSeconds: timeoutSeconds,
            timeoutIsDefault: true,
            workers: 4,
            stopsAtFirstFailure: false,
            failedTestLinesAreReliable: true,
            mutantsDiscovered: 2497,
            mutantsToTest: 2497,
            project: project
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
            testDurationSeconds: 2766.493,
            recorded: 1103
        )
    }
}
