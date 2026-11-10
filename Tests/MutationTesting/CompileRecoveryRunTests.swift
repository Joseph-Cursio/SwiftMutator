@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

/// A run whose baseline fails on mutants that don't compile: it builds without them, and tests the others.
final class CompileRecoveryRunTests: MuterTestCase {
    let path = "/project_mutated/Sources/Check.swift"
    private let code = """
    func check(_ value: Int) -> Bool {
        return value > 1
    }

    func other(_ value: Int) -> Bool {
        return value < 1
    }

    func third(_ value: Int) -> Bool {
        return value >= 1
    }

    """
    let state = MutationTestState()
    lazy var sut = PerformMutationTesting()
    /// `code`'s mutants, which `setUpWithError` discovers.
    var mapping = SchemataMutationMapping(filePath: "")
    var rewritten = ""
    private let written = Locked<[String]>([])
    private var writes: [String] { written.value }

    override func setUpWithError() throws {
        try super.setUpWithError()

        let source = SourceCodeInfo(path: path, code: Parser.parse(source: code))
        mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)
        rewritten = MuterRewriter(mapping).visit(source.code).description

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutationMapping = [mapping]
        state.preparedSources = [path: code]
    }

    override func setUp() {
        super.setUp()
        current.writeFile = { [written] code, _ in written.change { $0.append(code) } }
    }

    var ids: [String] { mapping.mutationSchemata.map(\.id) }

    func test_aMutantThatDoesntCompile_isRecordedAsABuildError_andTheOthersAreTested() async throws {
        let bad = try XCTUnwrap(ids.first)
        ioDelegate.baselineTestLogs = [try errorLog(for: bad), "Build complete!"]
        ioDelegate.testSuiteOutcomes = [.buildError, .passed] + Array(repeating: .failed, count: ids.count - 1)
        let sent = recordEvents(named: [.buildingAgainWithoutMutants, .mutantsLeftOutOfTheBuild, .newTestLogAvailable])

        let result = try await sut.run(with: state)

        // Twice for the baseline, and once for every other mutant.
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("benchmarkTests") }.count, 2)
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, ids.count - 1)
        XCTAssertFalse(ioDelegate.schematas.map(\.id).contains(bad))

        // Its line says it wasn't tested, in the existing format, with the header's counts for every mutant.
        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.count, ids.count)
        let line = try XCTUnwrap(records.first { $0.switchID == bad })
        XCTAssertEqual(line.outcome, .buildError)
        XCTAssertEqual(line.endedBy, .couldNotRun)
        XCTAssertNil(line.exitStatus)
        XCTAssertEqual(line.durationSeconds, 0)
        XCTAssertEqual(line.log, MutationTestLog.keptFileName(for: line.key))
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.mutantsDiscovered, ids.count)
        XCTAssertEqual(header.mutantsToTest, ids.count)
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).first?.recorded, ids.count)

        // Its log says why, the failed build's log stays, and the baseline's is the passing one.
        let log = try XCTUnwrap(fileManager.createdFiles["/logs/" + MutationTestLog.keptFileName(for: line.key)])
        XCTAssertTrue(String(lossyUTF8: log).contains("no such operator"))
        XCTAssertEqual(
            fileManager.createdFiles["/logs/failed build 1.log"],
            Data(try errorLog(for: bad).utf8)
        )

        // The outcome holds it, and the rest.
        guard case let .mutationTestOutcomeGenerated(outcome)? = result.first else {
            XCTFail("\(result)")
            return
        }
        XCTAssertEqual(outcome.mutations.count, ids.count)
        XCTAssertEqual(outcome.mutations.filter { $0.testSuiteOutcome == .buildError }.count, 1)

        // The neutral line comes before the warning, which comes before the progress starts, and doesn't count it.
        let names = sent().map(\.name)
        XCTAssertEqual(names.prefix(2), [.buildingAgainWithoutMutants, .mutantsLeftOutOfTheBuild])
        let leftOut = try XCTUnwrap(sent()[1].object as? MutantsLeftOut)
        XCTAssertEqual(leftOut.mutants.map(\.key), [line.key])
        XCTAssertEqual(leftOut.toTest, ids.count - 1)
        let progress = try XCTUnwrap(sent()[2].object as? MutationTestLog)
        XCTAssertEqual(progress.remainingMutationPointsCount, ids.count - 1)
    }

    // Five build errors in a row mean a mutant's run keeps failing to build. These never ran.
    func test_manyMutantsLeftOut_dontStopMutationTesting() async throws {
        let bad = try ids.prefix(ids.count - 1).map { try errorLine(for: $0) }.joined(separator: "\n")
        XCTAssertGreaterThanOrEqual(ids.count - 1, 5)
        ioDelegate.baselineTestLogs = [bad, "Build complete!"]
        // The one run that fails to build is one in a row, not one more than those left out.
        ioDelegate.testSuiteOutcomes = [.buildError, .passed, .buildError]

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            try resultsFiles.records(MutantResult.self).filter { $0.outcome == .buildError }.count,
            ids.count
        )
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).first?.reason, .finished)
    }

    func test_whenEveryMutantIsLeftOut_nothingIsTested_andEachHasItsLine() async throws {
        let bad = try ids.map { try errorLine(for: $0) }.joined(separator: "\n")
        ioDelegate.baselineTestLogs = [bad, "Build complete!"]
        ioDelegate.testSuiteOutcomes = [.buildError, .passed]
        let sent = recordEvents(named: [.mutantsLeftOutOfTheBuild, .newTestLogAvailable])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 0)
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.outcome), ids.map { _ in .buildError })
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).first?.reason, .finished)
        XCTAssertEqual(sent().map(\.name), [.mutantsLeftOutOfTheBuild])
        XCTAssertEqual((sent().first?.object as? MutantsLeftOut)?.toTest, 0)
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).first?.workers, 0)
    }

    // The project's own error: the failure stands, nothing is recorded, and no warning says mutants were at fault.
    func test_whenTheBuildStillFails_theBaselineFailureStands_withTheLastLog() async throws {
        let stays = "/project_mutated/Sources/Other.swift:3:1: error: the project's own"
        ioDelegate.baselineTestLogs = [try errorLog(for: try XCTUnwrap(ids.first)), stays]
        ioDelegate.testSuiteOutcomes = [.buildError, .buildError]
        let sent = recordEvents(named: [.buildingAgainWithoutMutants, .mutantsLeftOutOfTheBuild])

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .mutationTestingAborted(reason: .baselineTestFailed(log: stays, mutatedFilePaths: [path]))
        )

        XCTAssertEqual(sent().map(\.name), [.buildingAgainWithoutMutants])
        XCTAssertEqual(resultsFiles.lines, [])
    }

    func test_aTestPlansRun_stopsAtAFailedBuild() async throws {
        let log = try errorLog(for: try XCTUnwrap(ids.first))
        state.preparedSources = [:]
        ioDelegate.baselineTestLogs = [log]
        ioDelegate.testSuiteOutcomes = [.buildError]

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .mutationTestingAborted(reason: .baselineTestFailed(log: log, mutatedFilePaths: [path]))
        )

        XCTAssertTrue(writes.isEmpty)
    }

    // xcodebuild's build came first, and rewriting here would leave the tests it copied out of date.
    func test_xcodebuildsFailedBaseline_takesNoMutantOut() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["-destination", "platform=macOS", "test"]
        )
        let log = try errorLog(for: try XCTUnwrap(ids.first))
        ioDelegate.baselineTestLogs = [log, "Build complete!"]
        ioDelegate.testSuiteOutcomes = [.buildError, .passed] + Array(repeating: .failed, count: ids.count - 1)

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .mutationTestingAborted(reason: .baselineTestFailed(log: log, mutatedFilePaths: [path]))
        )

        XCTAssertTrue(writes.isEmpty)
    }

    func test_xcodebuildsBaseline_recordsThoseItsBuildTookOut() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["-destination", "platform=macOS", "test"]
        )
        let bad = try XCTUnwrap(ids.first)
        let error = CompilerError(filePath: path, line: 1, column: 1, message: "no such operator")
        state.mutantsLeftOut = [bad: LeftOutMutant(blame: .itself, errors: [error], buildLog: "failed build 1.log")]
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: ids.count - 1)

        _ = try await sut.run(with: state)

        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.first { $0.switchID == bad }?.outcome, .buildError)
        XCTAssertEqual(records.count, ids.count)
    }

    // One mutant's run ends in what it found, and the mutated project has no switch to run its tests with.
    func test_whenTheOneMutantOfAOneMutantRunIsLeftOut_itSaysSo() async throws {
        let schema = try XCTUnwrap(mapping.mutationSchemata.first)
        var one = try XCTUnwrap(mapping)
        one.keepOnly { $0.id == schema.id }
        state.mutationMapping = [one]
        let key = try XCTUnwrap(MutantKey.keys(for: [schema], under: state.mutatedProjectDirectoryURL).first)
        state.apply([.mutantSelected(key)])
        let oneRewritten = await ApplySchemata.rewritten(code, with: one)
        let place = try branchPlace(of: schema.id, in: oneRewritten)
        ioDelegate.baselineTestLogs = ["\(path):\(place.line):\(place.column): error: no such operator", "ok"]
        ioDelegate.testSuiteOutcomes = [.buildError, .passed]
        let sent = recordEvents(named: [.oneMutantTested])

        _ = try await sut.run(with: state)

        let run = try XCTUnwrap(sent().first?.object as? OneMutantRun)
        XCTAssertTrue(run.leftOutOfTheBuild)
        XCTAssertEqual(run.outcome, .buildError)
        XCTAssertEqual(run.logPath, "/logs/" + MutationTestLog.keptFileName(for: key))
        XCTAssertTrue(run.testLog.contains("no such operator"))
        XCTAssertEqual(Logger.verdict(of: run), "didn't compile, so its tests didn't run")
    }

    // A resumed session's own result for it stands, whatever the rewrite does: a mutant has one result.
    func test_aMutantWithAKeptResult_keepsIt_ifTheBuildLeavesItOut() throws {
        let job = try XCTUnwrap(mapping.mutationSchemata.first)
        let jobs = mapping.mutationSchemata.map {
            PerformMutationTesting.MutantJob(fileName: "Check.swift", schema: $0)
        }
        let kept = ResumePlan(
            reused: [0: MutantResult.make(switchID: job.id, outcome: .passed)],
            toRun: Array(1 ..< jobs.count),
            retestedBecause: [:],
            retired: [],
            noLongerDiscovered: 0
        )
        let leftOut = [job.id: LeftOutMutant(blame: .itself, errors: [], buildLog: "log")]
        let session = TestingSession(startedAt: Date())
        session.keys = MutantKey.keys(for: jobs.map(\.schema), under: state.mutatedProjectDirectoryURL)
        let sent = recordEvents(named: [.mutantsLeftOutOfTheBuild, .newMutationTestOutcomeAvailable])

        sut.keepLeftOut(leftOut, testing: kept, leaving: jobs.count - 1, of: jobs, in: session, state: state)

        XCTAssertEqual(session.leftOut, 0)
        XCTAssertTrue(session.outcomes.isEmpty)
        XCTAssertEqual(sent().count, 0)
        XCTAssertEqual(kept.leavingOut { leftOut[jobs[$0].schema.id] != nil }.toRun, Array(1 ..< jobs.count))
    }

    // With no switch to turn on, every property test would pass, and read as a kill by examples alone.
    func test_aKeptKillOfAMutantNotInTheBuild_isntRunAgainWithThePropertyTests() throws {
        let test = FailedTestLine.FailedTest(name: "example()", location: nil)
        let session = TestingSession(startedAt: Date())
        let kill = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .failed,
            killingTests: MutationTestOutcome.KillingTests(tests: [test], count: 1, isComplete: true)
        )
        session.outcomes = [0: kill, 1: kill]
        session.notInTheBuild = [0]

        XCTAssertEqual(PerformMutationTesting.propertyRerunCandidates(in: session, globs: ["Prop*"]), [1])
    }

    // A stop after they are recorded counts them apart from the mutants tested.
    func test_aStop_countsThemApart() async throws {
        let bad = try XCTUnwrap(ids.first)
        ioDelegate.baselineTestLogs = [try errorLog(for: bad), "Build complete!"]
        ioDelegate.testSuiteOutcomes = [.buildError, .passed] + Array(repeating: .failed, count: ids.count - 1)
        ioDelegate.whileRunningMutant = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let sent = recordEvents(named: [.mutationTestingEndedEarly])

        _ = await sut.runInItsOwnTask(with: state)

        let early = try XCTUnwrap(sent().first?.object as? EarlyEnd)
        XCTAssertEqual(early.leftOut, 1)
    }
}
