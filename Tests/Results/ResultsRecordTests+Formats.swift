@testable import muterCore
import XCTest

extension ResultsRecordTests {
    // A format-1 reader would skip the resumed session's retired line, and report results it no longer stands by.
    func test_aResumedSessionsHeader_isInFormat2_andSaysWhatItReusedAndWhatWasLetThrough() {
        let state = MutationTestState(from: .make())
        // Every mutant line then names a log, which format 4 is for.
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], keepAllLogs: true
        )
        let header = { (session: Int, mutantsReused: Int?, waived: [String]?, forced: [String]?) in
            ResultsHeader(
                session: session,
                startedAt: self.startedAt,
                state: state,
                logDirectory: "/logs",
                configuration: state.muterConfiguration,
                baselineSeconds: 32.125,
                workers: 1,
                mutantsDiscovered: 3,
                mutantsToTest: 3,
                provenance: .fixture,
                mutantsReused: mutantsReused,
                waived: waived,
                forced: forced
            )
        }

        let first = header(1, nil, nil, nil)
        let resumed = header(2, 0, ["README.md"], ["toolchain.testCommandVersion"])

        XCTAssertEqual(first.formatVersion, ResultsCoding.formatVersion)
        XCTAssertEqual(resumed.formatVersion, ResultsCoding.resumedFormatVersion)
        XCTAssertEqual(resumed.session, 2)
        XCTAssertEqual(resumed.mutantsReused, 0)
        XCTAssertEqual(resumed.waived, ["README.md"])
        XCTAssertEqual(resumed.forced, ["toolchain.testCommandVersion"])
    }

    // A format-3 reader can't read a mutant line without `log`, and would skip it, so any session that may write one
    // is in format 4: one that tests mutants without `keepAllLogs`, but for `--mutant`'s, which keeps its log, and one
    // that copies reused lines without a log. Any other keeps to the format it had.
    func test_aSessionThatMayWriteALineWithoutALog_isInFormat4() {
        func header(
            _ session: Int, _ configuration: MuterConfiguration, _ mutant: MutantKey?, _ toTest: Int, _ copying: Bool
        ) -> Int {
            let state = MutationTestState(from: .make())
            state.muterConfiguration = configuration
            state.selectedMutant = mutant
            return ResultsHeader(
                session: session,
                startedAt: self.startedAt,
                state: state,
                logDirectory: "/logs",
                configuration: configuration,
                baselineSeconds: 32.125,
                workers: 1,
                mutantsDiscovered: 3,
                mutantsToTest: toTest,
                provenance: .fixture,
                copyingLinesWithoutLogs: copying
            ).formatVersion
        }

        let byDefault = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        let keepingAll = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], keepAllLogs: true)
        let mutant = MutantKey(path: "Sources/Sum.swift", mutationOperatorId: .ror, line: 3, column: 5, occurrence: 0)

        XCTAssertEqual(header(1, byDefault, nil, 3, false), ResultsCoding.omittedLogsFormatVersion)
        XCTAssertEqual(header(2, byDefault, nil, 3, false), ResultsCoding.omittedLogsFormatVersion)
        XCTAssertEqual(header(1, keepingAll, nil, 3, false), ResultsCoding.formatVersion)
        XCTAssertEqual(header(2, keepingAll, nil, 3, false), ResultsCoding.resumedFormatVersion)
        XCTAssertEqual(header(1, byDefault, mutant, 1, false), ResultsCoding.formatVersion, "--mutant keeps its log")
        XCTAssertEqual(header(2, byDefault, nil, 0, false), ResultsCoding.resumedFormatVersion, "nothing to test")
        XCTAssertEqual(header(1, keepingAll, nil, 0, true), ResultsCoding.omittedLogsFormatVersion)
        XCTAssertEqual(header(1, keepingAll, nil, 3, true), ResultsCoding.omittedLogsFormatVersion)
    }

    // A kill by a failed test its line names keeps no log by default, so its line has no `log`, which reads back.
    func test_aMutantRecordWithoutALog_leavesItOut_andReadsBack() throws {
        let record = MutantResult.make(killedBy: [.init(name: "sum()", location: nil)], keptLog: false)

        let written = try line(record)

        XCTAssertFalse(written.contains(#""log""#), written)
        XCTAssertEqual(try decode(MutantResult.self, from: written), record)
        let withALog = try line(MutantResult.make())
        XCTAssertTrue(withALog.contains(#""log":"RelationalOperatorReplacement @ Sum.swift-73-22.log""#), withALog)
    }

    // A reusing session that would keep no log for a result names none on its line.
    func test_aReusedResult_namesNoLog_unlessKeepingIt() {
        let tested = MutantResult.make(outcome: .failed, killedBy: [.init(name: "sum()", location: nil)])
        let reuse = { (keepingLog: Bool) in
            tested.reused(
                from: "/logs/a/results.jsonl",
                headers: [.make(session: 1)],
                in: 1,
                at: .init(utf8Offset: 4_000, switchID: "Sum_new"),
                despiteChanges: false,
                keepingLog: keepingLog
            )
        }

        XCTAssertEqual(reuse(true).log, tested.log)
        XCTAssertNil(reuse(false).log)
        XCTAssertNil(MutantResult.make(keptLog: false).reused(
            from: "/r.jsonl", headers: [], in: 1, at: .init(utf8Offset: 1, switchID: "s"), despiteChanges: false
        ).log, "a result with no log has none to keep")
    }

    func test_endDetail_namesTheAbortReason() {
        XCTAssertEqual(
            ResultsEnd.detail(for: MuterError.mutationTestingAborted(reason: .tooManyBuildErrors)),
            "tooManyBuildErrors"
        )
        XCTAssertEqual(
            ResultsEnd.detail(
                for: MuterError.mutationTestingAborted(reason: .mutantNotSwitchedOn(id: "Calc_1", description: "full"))
            ),
            "mutantNotSwitchedOn"
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
                for: MuterError.mutationTestingAborted(
                    reason: .simulatorUnavailable(worker: 3, line: "No matching device (X)", log: nil)
                )
            ),
            "simulatorUnavailable(worker: 3)"
        )
        XCTAssertEqual(
            ResultsEnd.detail(
                for: MuterError.mutationTestingAborted(
                    reason: .baselineTestFailed(log: "the log", mutatedFilePaths: [])
                )
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
