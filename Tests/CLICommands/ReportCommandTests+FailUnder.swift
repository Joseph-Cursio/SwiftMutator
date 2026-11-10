import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

extension ReportCommandTests {
    func test_failUnder_aScoreBelowIt_exits2_afterTheReport() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)

        await AssertThrowsError(try await report(resultsPath, "--fail-under", "50")) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
            XCTAssertEqual(MuterCommand.exitCode(for: error).rawValue, 2)
            XCTAssertEqual(MuterCommand.fullMessage(for: error), "")
        }
        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: expected)])
        XCTAssertEqual(standardError.linesPassed, [
            "Report of 3 of 3 mutants, from \(resultsPath): the run finished.",
            "Mutation score 33.3% is below the required 50%.",
        ])
    }

    // Exactly 33.33…%, which the threshold's one decimal shows as it is.
    func test_failUnder_aScoreAtOrAboveIt_exits0() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)

        try await report(resultsPath, "--fail-under", "33.3")

        XCTAssertEqual(standardError.linesPassed.last, "Mutation score 33.3% meets the required 33.3%.")
    }

    // The run's error wins (#110): the score of what it tested isn't the project's.
    func test_failUnder_ofARunThatStoppedOnAnError_isntChecked_andExitsAsTheRunDid() async throws {
        for (detail, status) in [("tooManyBuildErrors", ExitCode.abortedMidRun), ("MuterError", .stoppedOnAnError)] {
            let end = ResultsEnd.make(reason: .aborted, detail: detail)
            try write(ResultsHeader.make(), alpha3, end, to: resultsPath)

            await AssertThrowsError(try await report(resultsPath, "--fail-under", "100")) { error in
                XCTAssertEqual(error as? ExitCode, status, detail)
            }
            XCTAssertEqual(
                standardError.linesPassed.last,
                "The required 100% isn't checked: the run stopped on an error.",
                detail
            )
        }
    }

    // What was tested is checked, and the verdict says it is partial; the job that ran it already got its signal.
    func test_failUnder_ofARunThatDidntFinish_checksWhatWasTested() async throws {
        for end in [ResultsEnd.make(reason: .interrupted, detail: "SIGINT"), nil] {
            try write([ResultsHeader.make(), zeta9] + [end].compactMap(\.self), to: resultsPath)

            await AssertThrowsError(try await report(resultsPath, "--fail-under", "50")) { error in
                XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
            }
            XCTAssertEqual(
                standardError.linesPassed.last,
                "Mutation score 0.0% is below the required 50%. Only 1 of 3 mutants have results, as the run didn't "
                    + "finish."
            )
        }
    }

    // Stopped after its header, or still under way: mutants are known and none has a result, so nothing shows the
    // threshold is met. A CI job shaped like `run || true; report --fail-under 80` must not go green on it.
    func test_failUnder_ofARunThatDidntFinish_withNoResults_exits2() async throws {
        for end in [ResultsEnd.make(reason: .interrupted, detail: "SIGTERM"), nil] {
            try write([ResultsHeader.make()] + [end].compactMap(\.self), to: resultsPath)

            await AssertThrowsError(try await report(resultsPath, "--fail-under", "50")) { error in
                XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
            }
            XCTAssertEqual(
                standardError.linesPassed.last,
                "No mutant was tested, so nothing shows the required 50% is met. Only 0 of 3 mutants have results, as "
                    + "the run didn't finish."
            )
        }
    }

    // With no mutant to test, nothing falls short: a change that touches no Swift code doesn't fail.
    func test_failUnder_ofARunWithNothingToMutate_exits0() async throws {
        try write(ResultsHeader.make(mutantsDiscovered: 0, mutantsToTest: 0), to: resultsPath)

        try await report(resultsPath, "--fail-under", "50")

        XCTAssertEqual(
            standardError.linesPassed.last,
            "No mutant was tested, so no score falls short of the required 50%."
        )
    }

    // The merged score is the whole run's.
    func test_failUnder_ofMergedShards_checksTheMergedScore() async throws {
        let first = "\(directory)/1.jsonl"
        let second = "\(directory)/2.jsonl"
        try write(shardHeader(1, mutantsDiscovered: 2), zeta9, alpha3, ResultsEnd.make(), to: first)
        try write(shardHeader(2, mutantsDiscovered: 1), zeta10, ResultsEnd.make(), to: second)

        await AssertThrowsError(try await report(first, second, "--fail-under", "34")) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
        }
        XCTAssertEqual(standardError.linesPassed.last, "Mutation score 33.3% is below the required 34%.")

        try await report(first, second, "--fail-under", "33")
        XCTAssertEqual(standardError.linesPassed.last, "Mutation score 33.3% meets the required 33%.")
    }

    // As without the threshold: the merge lacks results, so the whole run didn't test every mutant.
    func test_failUnder_ofShardsThatLackResults_isntChecked_andExits4() async throws {
        try write(shardHeader(1, mutantsDiscovered: 2), zeta9, alpha3, ResultsEnd.make(), to: resultsPath)

        await AssertThrowsError(try await report(resultsPath, "--fail-under", "10")) { error in
            XCTAssertEqual(error as? ExitCode, .abortedMidRun)
        }
        XCTAssertEqual(
            standardError.linesPassed.last,
            "The required 10% isn't checked: the merged report lacks results."
        )
    }

    // Scripts read the verdict from the summary; the threshold checked, which needn't be the run's own.
    func test_failUnder_isRecordedInTheSummary() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let summaryPath = "\(directory)/summary.json"

        await AssertThrowsError(try await report(resultsPath, "--fail-under", "50", "--summary", summaryPath))

        let saved = try String(contentsOfFile: summaryPath, encoding: .utf8)
        let gate = try XCTUnwrap(parsedJSON(saved)["gate"] as? [String: AnyHashable], saved)
        XCTAssertEqual(gate, ["failUnder": 50, "passed": false, "score": 100.0 / 3])
        XCTAssertEqual(standardError.linesPassed.suffix(2), [
            "Summary saved to \(summaryPath)",
            "Mutation score 33.3% is below the required 50%.",
        ])
    }

    // `report` reads no configuration, so the run's own failUnder, which its header records, is never checked: only
    // `--fail-under` sets a threshold, so a plain `report` of a low score exits 0 whatever the run required.
    func test_failUnder_theRunsOwn_isntChecked_onlyTheFlag() async throws {
        let configuration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], failUnder: 80)
        let header = ResultsHeader.make(configuration: configuration)
        try write(header, zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let summaryPath = "\(directory)/summary.json"

        try await report(resultsPath, "--summary", summaryPath)

        let saved = try String(contentsOfFile: summaryPath, encoding: .utf8)
        let summary = try parsedJSON(saved)
        XCTAssertNil(summary["gate"], saved)
        let run = try XCTUnwrap(summary["run"] as? [String: AnyHashable], saved)
        XCTAssertEqual((run["configuration"] as? [String: AnyHashable])?["failUnder"] as? Double, 80, saved)
        XCTAssertEqual(standardError.linesPassed.last, "Summary saved to \(summaryPath)")
        XCTAssertFalse(standardError.linesPassed.contains { $0.contains("required") }, "\(standardError.linesPassed)")

        // The flag's threshold is checked in its place, below the run's own.
        try await report(resultsPath, "--fail-under", "30", "--summary", summaryPath)

        let savedSummary = try parsedJSON(String(contentsOfFile: summaryPath, encoding: .utf8))
        let gate = savedSummary["gate"] as? [String: AnyHashable]
        XCTAssertEqual(gate?["failUnder"] as? Double, 30)
        XCTAssertEqual(standardError.linesPassed.last, "Mutation score 33.3% meets the required 30%.")
    }

    func test_failUnder_withoutIt_theSummaryHasNoGate() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let summaryPath = "\(directory)/summary.json"

        try await report(resultsPath, "--summary", summaryPath)

        let saved = try String(contentsOfFile: summaryPath, encoding: .utf8)
        XCTAssertNil(try parsedJSON(saved)["gate"], saved)
        XCTAssertEqual(standardError.linesPassed.last, "Summary saved to \(summaryPath)")
    }
}
