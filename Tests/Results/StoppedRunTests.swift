@testable import muterCore
import XCTest

/// The results file of a run that stopped before its first mutant (`ResultsStopped`): what `StoppedRunRecorder` writes,
/// and how it reads back.
final class StoppedRunTests: MuterTestCase {
    private let started = Date(timeIntervalSince1970: 1_000_000)
    private let stopped = Date(timeIntervalSince1970: 1_000_090)
    private let logs = "/project_muter_logs/Nov 8, 2026 at 9:00 AM"
    private let failure = "Test Case '-[CalcTests.CalcTests testAdd]' failed (0.002 seconds)."

    private func recorder(testsMutants: Bool = true, logDirectory: String? = nil) -> StoppedRunRecorder {
        let recorder = StoppedRunRecorder()
        recorder.start(at: started, logDirectory: logDirectory ?? logs, testsMutants: testsMutants)
        recorder.update(projectPath: "/project", resuming: nil)
        return recorder
    }

    private func written() throws -> [ResultsStopped] {
        try resultsFiles.records(ResultsStopped.self)
    }

    // A failed baseline's record names the step, its log and the tests that failed, alone in a file of its own.
    func test_aFailedBaseline_isRecorded_withItsLogAndFailedTests() throws {
        let path = recorder().record(
            .aborted(.baselineTestFailed(log: "Building\n\(failure)\n", mutatedFilePaths: [])), at: stopped
        )

        XCTAssertEqual(path, "\(logs)/results.jsonl")
        XCTAssertEqual(resultsFiles.directories, [logs])
        XCTAssertEqual(try resultsFiles.kinds(), ["stopped"])
        let expected = ResultsStopped(
            startedAt: started,
            stoppedAt: stopped,
            step: .baseline,
            reason: .failed,
            detail: "baselineTestFailed",
            limitSeconds: nil,
            log: "baseline run.log",
            failedTests: [FailedTestLine.FailedTest(name: "-[CalcTests.CalcTests testAdd]", location: nil)],
            failedTestCount: 1,
            projectPath: "/project",
            logDirectory: logs,
            resuming: nil
        )
        XCTAssertEqual(try written(), [expected])
    }

    func test_eachStepPastItsLimit_isRecordedAsTimedOut_withTheLimitAndItsLogsName() throws {
        let reasons: [(MutationTestingAbortReason, ResultsStopped.Step, String?)] = [
            (.buildTimeoutReached(step: .buildForTesting, seconds: 900, output: "", log: "\(logs)/failed build 2.log"),
             .buildForTesting, "buildTimeoutReached"),
            (.buildTimeoutReached(step: .baseline, seconds: 600, output: failure, log: "\(logs)/baseline run.log"),
             .baseline, "buildTimeoutReached"),
            (.buildTimeoutReached(
                step: .workerBaseline(worker: 2, directory: "/p_worker2"), seconds: 600, output: "", log: nil
             ), .workerBaselines, "buildTimeoutReached(worker: 2)"),
        ]
        for (reason, step, detail) in reasons {
            recorder().record(.aborted(reason), at: stopped)
            let record = try XCTUnwrap(written().last)
            XCTAssertEqual(record.step, step)
            XCTAssertEqual(record.reason, .timedOut)
            XCTAssertEqual(record.detail, detail)
        }
        let records = try written()
        XCTAssertEqual(records.map(\.limitSeconds), [900, 600, 600])
        XCTAssertEqual(records.map(\.log), ["failed build 2.log", "baseline run.log", nil])
        XCTAssertEqual(records.map(\.failedTestCount), [0, 1, 0])
    }

    func test_aFailedBuildOrClone_isRecordedAsFailed() throws {
        let build = MutationTestingAbortReason.buildForTestingFailed(description: "", log: "\(logs)/failed build 1.log")
        recorder().record(.aborted(build), at: stopped)
        recorder().record(.aborted(.workerBaselineTestFailed(worker: 3, directory: "/w3", log: failure)), at: stopped)

        let records = try written()
        XCTAssertEqual(records.map(\.step), [.buildForTesting, .workerBaselines])
        XCTAssertEqual(records.map(\.reason), [.failed, .failed])
        XCTAssertEqual(records.map(\.log), ["failed build 1.log", "baseline run worker 3.log"])
        XCTAssertEqual(records.map(\.detail), ["buildForTestingFailed", "workerBaselineTestFailed(worker: 3)"])
        // A build runs no test.
        XCTAssertNil(records.first?.failedTests)
    }

    // A signal is recorded with the step the run was in, and the output that step was writing, if it is there.
    func test_aSignal_isRecordedWithTheStepTheRunWasIn_andItsOutput() throws {
        let following = recorder()
        following.enter(.timedTestRun)
        fileManager.fileExistsToReturn = [true]

        following.record(.interrupted(signal: SIGTERM), at: stopped)

        let record = try XCTUnwrap(written().first)
        XCTAssertEqual(record.step, .timedTestRun)
        XCTAssertEqual(record.reason, .interrupted)
        XCTAssertEqual(record.detail, "SIGTERM")
        XCTAssertEqual(record.log, "running/timed test run")
        XCTAssertEqual(fileManager.fileExistsAtPath, ["\(logs)/running/timed test run"])
        XCTAssertNil(record.failedTests)
        XCTAssertEqual(record.exitStatus, .abortedMidRun)
    }

    // Once only, and never once the results have started, which then record the stop, nor for an abort that isn't a
    // failed baseline's kind, a run that tests no mutant, or one with no log folder.
    func test_onlyARunStoppedBeforeItsResults_isRecorded_once() throws {
        let once = recorder()
        once.record(.interrupted(signal: SIGINT), at: stopped)
        once.record(.interrupted(signal: SIGINT), at: stopped)
        let startedRecorder = recorder()
        startedRecorder.resultsStart()
        startedRecorder.record(.interrupted(signal: SIGINT), at: stopped)
        recorder().record(.aborted(.tooManyBuildErrors), at: stopped)
        recorder(testsMutants: false).record(.interrupted(signal: SIGINT), at: stopped)
        recorder(logDirectory: "").record(.interrupted(signal: SIGINT), at: stopped)

        XCTAssertEqual(resultsFiles.directories, [logs])
        XCTAssertEqual(try written().count, 1)
    }

    // Once a stop at once has recorded the run, from the signal's thread, its results never start: the folder holds
    // one results file.
    func test_resultsDontStart_onceAStopIsRecorded() {
        let first = recorder()
        XCTAssertTrue(first.resultsStart())
        let stoppedFirst = recorder()
        stoppedFirst.record(.interrupted(signal: SIGINT), at: stopped)

        XCTAssertFalse(stoppedFirst.resultsStart())
    }

    func test_theRecordsPath_isSaid() {
        Logger().stoppedRunRecorded(path: "/logs/results.jsonl")

        XCTAssertEqual(printer.linesPassed, [
            "📝 Why the run stopped before its first mutant is in /logs/results.jsonl, which `report` reads.",
        ])
    }

    // Read back, it refuses the file, saying why, as a reader of an older SwiftMutator refuses a file with no header.
    func test_aStoppedRunsFile_readsAsStoppedBeforeItsFirstMutant() throws {
        recorder().record(.aborted(.baselineTestFailed(log: failure, mutatedFilePaths: [])), at: stopped)
        let data = Data((resultsFiles.lines.joined(separator: "\n") + "\n").utf8)

        XCTAssertThrowsError(try RecordedResults.read(data, path: "/logs/results.jsonl")) { error in
            guard case let ResultsFileError.stoppedBeforeFirstMutant(path, record) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(path, "/logs/results.jsonl")
            XCTAssertEqual(record.step, .baseline)
            XCTAssertEqual("\(error)".components(separatedBy: "\n"), [
                "The run in \(Logger.shellQuoted("/logs/results.jsonl")) stopped before its first mutant, so it has "
                    + "no result: the baseline run failed.",
                "Its log is \(logs)/baseline run.log.",
                "This test failed:",
                "  -[CalcTests.CalcTests testAdd]",
            ])
        }
    }

    // `report` says why and exits as the run did: 3 for a failed or timed-out step, 4 for a signal. Beside a file it
    // can report, it reports that one, and still exits as the stopped run did.
    func test_report_ofAStoppedRun_saysWhy_andExitsAsTheRunDid() throws {
        current.fileManager = FileManager.default
        let folder = try makeTemporaryDirectory()
        let failed = "\(folder)/failed.jsonl"
        let signalled = "\(folder)/signalled.jsonl"
        try resultsFileData([ResultsStopped.make(step: .baseline, reason: .failed, detail: "baselineTestFailed")])
            .write(to: URL(fileURLWithPath: failed))
        try resultsFileData([ResultsStopped.make(step: .coverageRun, reason: .interrupted, detail: "SIGINT")])
            .write(to: URL(fileURLWithPath: signalled))
        let report = ResultsReport(format: .plain, outputPath: nil)

        XCTAssertEqual(try report.make(from: [failed]), .baselineFailed)
        XCTAssertEqual(try report.make(from: [signalled]), .abortedMidRun)
        XCTAssertEqual(standardError.linesPassed, [
            "The run in \(Logger.shellQuoted(failed)) stopped before its first mutant, so it has no result: the "
                + "baseline run failed.",
            "The run in \(Logger.shellQuoted(signalled)) stopped before its first mutant, so it has no result: "
                + "SIGINT stopped it during the coverage run.",
        ])
        XCTAssertEqual(printer.linesPassed, [])
    }

    // Beside a file it can report, the stopped one is said and left out, the other reported, and `report` exits as the
    // stopped run did, without checking --fail-under, as for any run that stopped on an error.
    func test_report_ofAStoppedRunBesideAFinishedOne_exitsAsTheStoppedRunDid() throws {
        current.fileManager = FileManager.default
        let folder = try makeTemporaryDirectory()
        let failed = "\(folder)/failed.jsonl"
        let finished = "\(folder)/finished.jsonl"
        try resultsFileData([ResultsStopped.make(step: .baseline, reason: .failed, detail: "baselineTestFailed")])
            .write(to: URL(fileURLWithPath: failed))
        try resultsFileData([ResultsHeader.make(), ResultsEnd.make(recorded: 0)])
            .write(to: URL(fileURLWithPath: finished))

        let status = try ResultsReport(format: .plain, outputPath: nil, failUnder: 80).make(from: [failed, finished])

        XCTAssertEqual(status, .baselineFailed)
        XCTAssertTrue(standardError.linesPassed.first?.contains("stopped before its first mutant") == true)
        XCTAssertTrue(
            standardError.linesPassed.contains { $0.hasSuffix("isn't checked: the run stopped on an error.") },
            "\(standardError.linesPassed)"
        )
    }

    func test_whatARecordSays_ofEachReason() {
        let timedOut = ResultsStopped.make(step: .workerBaselines, reason: .timedOut, detail: "x(worker: 2)", limit: 90)
        let interrupted = ResultsStopped.make(step: .coverageRun, reason: .interrupted, detail: "SIGINT")
        let resumed = ResultsStopped.make(
            step: .preparing, reason: .interrupted, detail: "SIGHUP", resuming: "/a/r.jsonl"
        )

        XCTAssertEqual(timedOut.stoppedClause, "stopped before its first mutant, so it has no result: worker 2's "
            + "baseline run didn't end within 90 s (buildTimeout)")
        XCTAssertEqual(interrupted.stoppedClause, "stopped before its first mutant, so it has no result: SIGINT "
            + "stopped it during the coverage run")
        XCTAssertEqual(resumed.lines(path: "/b/results.jsonl").last, "It was resuming the run in "
            + "\(Logger.shellQuoted("/a/r.jsonl")), which it left as it was: --resume that file once this is fixed.")
        XCTAssertEqual(timedOut.exitStatus, .baselineFailed)
    }

    func test_aResumeOrReuseOfAStoppedRun_isRefused_sayingWhatToDo() {
        let stoppedRecord = ResultsStopped.make(step: .baseline, reason: .failed, detail: "baselineTestFailed")
        let resumed = ResultsStopped.make(step: .baseline, reason: .failed, detail: nil, resuming: "/a/r.jsonl")

        XCTAssertEqual(
            ResumeRefusal.stoppedBeforeFirstMutant(stoppedRecord).describe(reusing: false),
            "its run stopped before its first mutant, so it has no result: the baseline run failed.\n"
                + "Fix that, then start a new run, without --resume."
        )
        XCTAssertTrue(ResumeRefusal.stoppedBeforeFirstMutant(stoppedRecord).describe(reusing: true)
            .hasSuffix("Fix that, then start a run without --reuse."))
        XCTAssertTrue(ResumeRefusal.stoppedBeforeFirstMutant(resumed).describe(reusing: false)
            .hasSuffix("Fix that, then --resume \(Logger.shellQuoted("/a/r.jsonl")), the run it was resuming."))
    }
}

extension ResultsStopped {
    static func make(
        step: Step,
        reason: Reason,
        detail: String?,
        limit: Double? = nil,
        resuming: String? = nil
    ) -> ResultsStopped {
        ResultsStopped(
            startedAt: Date(timeIntervalSince1970: 0),
            stoppedAt: Date(timeIntervalSince1970: 60),
            step: step,
            reason: reason,
            detail: detail,
            limitSeconds: limit,
            log: nil,
            failedTests: nil,
            failedTestCount: nil,
            projectPath: "/project",
            logDirectory: "/logs",
            resuming: resuming
        )
    }
}
