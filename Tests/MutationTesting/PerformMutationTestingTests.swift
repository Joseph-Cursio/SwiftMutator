@testable import muterCore
import TestingExtensions
import XCTest

final class PerformMutationTestingTests: MuterTestCase {
    let state = MutationTestState()

    private let expectedMutationPoint = MutationPoint(
        mutationOperatorId: .ror,
        filePath: "/tmp/project/file.swift",
        position: .firstPosition
    )

    lazy var sut = PerformMutationTesting()

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")

        state.mutationMapping = try [
            makeSchemataMapping(),
            makeSchemataMapping(),
        ]
    }

    func test_whenBaselinePasses_thenRunMutationTesting() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.mutantActivations = [.unknown, .unknown]

        let result = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls, [
            // Base line
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            // First mutation
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            // Second mutation
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
        ])

        let expectedTestOutcomes = [
            MutationTestOutcome.Mutation.make(
                testSuiteOutcome: .failed,
                point: .make(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/project/file.swift",
                    position: .null
                ),
                snapshot: .null,
                originalProjectDirectoryUrl: state.projectDirectoryURL,
                mutatedProjectDirectoryURL: state.mutatedProjectDirectoryURL,
                // The spy's "testLog" shows no failed test, and the baseline's shows none that makes lines unreliable.
                killingTests: .noneNamed,
                key: fileKey(0),
                durationSeconds: 0
            ),
            MutationTestOutcome.Mutation.make(
                testSuiteOutcome: .failed,
                point: .make(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/project/file.swift",
                    position: .null
                ),
                snapshot: .null,
                originalProjectDirectoryUrl: state.projectDirectoryURL,
                mutatedProjectDirectoryURL: state.mutatedProjectDirectoryURL,
                killingTests: .noneNamed,
                key: fileKey(1),
                durationSeconds: 0
            ),
        ]

        var expected = MutationTestOutcome(
            mutations: expectedTestOutcomes,
            projectPath: "/project",
            mutatedProjectPath: "/project_mutated"
        )
        // What a baseline file of the run records, as `report` of its results has it from their header.
        expected.baselineScope = LoadBaselineFile.scope(of: state)
        // Discovery didn't look for the mutants of code no test ran, with coverage on, so they aren't known.
        expected.uncoveredMutants = nil
        XCTAssertEqual(result, [.mutationTestOutcomeGenerated(expected)])
    }

    // Both mutants are in same-named files at the same place, so only the job's number tells their files apart. Two
    // runs under way at once must never share one: the first to finish removes it.
    func test_createLogFile() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            ioDelegate.testLogs,
            [
                "baseline run",
                "0_path_RelationalOperatorReplacement_0_0_0.log",
                "1_path_RelationalOperatorReplacement_0_0_0.log",
            ]
        )
    }

    // The progress bar's first estimate of the time left starts from this count. It used to come from state no step
    // sets, so the estimate was always 0 minutes.
    func test_theBaselinesLog_countsTheMutantsToTest() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.newTestLogAvailable])

        _ = try await sut.run(with: state)

        let baselineLog = try XCTUnwrap(sent().first?.object as? MutationTestLog)
        XCTAssertNil(baselineLog.mutationPoint)
        XCTAssertEqual(baselineLog.remainingMutationPointsCount, 2)
    }

    func test_whenBaselineFailsDueToTestingFailure() async throws {
        ioDelegate.testSuiteOutcomes = [.failed]

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            guard case let .mutationTestingAborted(reason: .baselineTestFailed(log, _)) = error else {
                XCTFail("Expected mutationTestingAborted, got \(error)")
                return
            }

            XCTAssertFalse(log.isEmpty)
        }

        XCTAssertEqual(
            ioDelegate.methodCalls,
            ["benchmarkTests(using:savingResultsIntoFileNamed:)", ]
        )
    }

    func test_whenBaselineFailsDueToBuildError() async throws {
        ioDelegate.testSuiteOutcomes = [.buildError]

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            guard case let .mutationTestingAborted(reason: .baselineTestFailed(log, _)) = error else {
                XCTFail("Expected mutationTestingAborted, got \(error)")
                return
            }

            XCTAssertFalse(log.isEmpty)
        }

        XCTAssertEqual(ioDelegate.methodCalls, [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
        ])
    }

    func test_whenBaselineFailsDueToRuntimeError() async throws {
        ioDelegate.testSuiteOutcomes = [.runtimeError]

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            guard case let .mutationTestingAborted(reason: .baselineTestFailed(log, _)) = error else {
                XCTFail("Expected mutationTestingAborted, got \(error)")
                return
            }

            XCTAssertFalse(log.isEmpty)
        }

        XCTAssertEqual(ioDelegate.methodCalls, [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
        ])
    }

    func test_whenBaselineFails_thenItsLogIsStillKept() async throws {
        state.loggingDirectory = "/logs"
        ioDelegate.baselineTestLog = "error: no such module 'Calc'"
        ioDelegate.testSuiteOutcomes = [.buildError]

        // Not as `.newTestLogAvailable`, which announces "Determined baseline for mutation testing" and starts the
        // progress bar, neither of which happened.
        let sent = recordEvents(named: [.newTestLogAvailable])

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { _ in }

        // The baseline's output is the only evidence of why SwiftMutator can't start, and nothing else records it.
        XCTAssertEqual(
            fileManager.createdFiles["/logs/baseline run.log"], Data("error: no such module 'Calc'".utf8)
        )
        XCTAssertEqual(ioDelegate.keptOutputs.map(\.output), ["/logs/running/baseline run"])
        XCTAssertEqual(ioDelegate.keptOutputs.map(\.path), ["/logs/baseline run.log"])
        XCTAssertEqual(sent().count, 0)
    }

    // Each log is written once: the file each run wrote is moved to the name its log is kept under, which a mutant's
    // results line gives. The spy moves none, so each is written from its text instead.
    func test_eachRunsOutput_isMovedToTheNameItsLogIsKeptUnder() async throws {
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantTestLogs = ["first mutant's log", "second mutant's log"]

        _ = try await sut.run(with: state)

        // The kill's log names no failed test, so it is kept too.
        let logs = try resultsFiles.records(MutantResult.self).map { try XCTUnwrap($0.log) }
        XCTAssertEqual(logs, [
            MutationTestLog.keptFileName(for: fileKey(0)), MutationTestLog.keptFileName(for: fileKey(1)),
        ])
        XCTAssertEqual(
            ioDelegate.keptOutputs.map(\.path), ["/logs/baseline run.log"] + logs.map { "/logs/" + $0 }
        )
        XCTAssertEqual(ioDelegate.keptOutputs.map(\.output), ioDelegate.testLogs)
        XCTAssertEqual(ioDelegate.keptOutputs.first?.output, "/logs/running/baseline run")
        XCTAssertEqual(fileManager.createdFiles["/logs/" + logs[1]], Data("second mutant's log".utf8))
    }

    // As a state that bypasses the handler has: each run's output, in the current directory, is discarded.
    func test_withNoLogFolder_eachRunsOutputIsDiscarded_andNoLogIsKept() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.keptOutputs.map(\.output), ioDelegate.testLogs)
        XCTAssertEqual(ioDelegate.keptOutputs.map(\.path), [nil, nil, nil])
        XCTAssertEqual(ioDelegate.keptOutputs.first?.output, "baseline run")
        XCTAssertEqual(fileManager.createdFiles.keys.sorted(), [])
    }

    func test_whenBaselineFails_thenTheAbortReasonCarriesTheMutatedFilePaths() async throws {
        ioDelegate.testSuiteOutcomes = [.buildError]

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            guard case let .mutationTestingAborted(reason: .baselineTestFailed(_, mutatedFilePaths)) = error else {
                XCTFail("Expected mutationTestingAborted, got \(error)")
                return
            }

            // Naming the files SwiftMutator rewrote is what lets the message tell a broken mutant apart from
            // a misconfigured test command.
            XCTAssertEqual(mutatedFilePaths, ["/some/path", "/some/path"])
        }
    }

    /// The outcome of each mutant the run's result reports, in job order.
    func outcomes(in result: [MutationTestState.Change]) -> [TestSuiteOutcome] {
        result.flatMap { change -> [TestSuiteOutcome] in
            guard case let .mutationTestOutcomeGenerated(outcome) = change else { return [] }
            return outcome.mutations.map(\.testSuiteOutcome)
        }
    }

    /// Records every event sent with one of `names`, in order, until the test ends.
    func recordEvents(named names: [RunEvent.Name]) -> () -> [RunEvent] {
        var sent: [RunEvent] = []
        let tokens = names.map { name in
            runEvents.observe(name) { sent.append($0) }
        }
        addTeardownBlock { tokens.forEach { $0.cancel() } }
        return { sent }
    }

    /// Runs mutation testing in a task of its own, so a test that cancels it mid-run doesn't cancel itself.
    func runInItsOwnTask() async -> Result<[MutationTestState.Change], Error> {
        await sut.runInItsOwnTask(with: state)
    }

    /// Cancels mutation testing when it sends `name`, from the task that sends it.
    func cancelMutationTesting(whenSent name: RunEvent.Name) {
        let observer = runEvents.observe(name) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
        addTeardownBlock { observer.cancel() }
    }

    /// The key of the nth mutant at the start of /tmp/project/file.swift, which is outside the mutated project.
    func fileKey(_ occurrence: Int) -> MutantKey {
        MutantKey(path: "/tmp/project/file.swift", mutationOperatorId: .ror, line: 0, column: 0, occurrence: occurrence)
    }

    func makeSchemataMapping() throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/tmp/project/file.swift",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: .firstPosition,
                        snapshot: .null
                    ),
                ]
            ),
            filePath: "/some/path"
        )
    }
}
