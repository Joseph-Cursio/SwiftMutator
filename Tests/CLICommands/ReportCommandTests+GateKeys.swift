import ArgumentParser
@testable import muterCore
import XCTest

extension ReportCommandTests {
    // `report` reads no configuration, so the gate keys a run's header records are never checked, as its failUnder
    // isn't: a header whose `baseline:` names no file there neither refuses the report nor compares its survivors,
    // and only the flags check anything. So a merging job needs every gate as a flag.
    func test_theGateKeys_theRunsHeaderRecords_areNeverChecked_onlyTheFlags() throws {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            gates: RunGates(
                baseline: "\(directory)/missing.baseline.yml",
                maxNewSurvivors: 0,
                maxScoreDrop: 0,
                maxDoubtfulKills: 0
            )
        )
        let header = ResultsHeader.make(configuration: configuration)
        try write(header, zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let summaryPath = "\(directory)/summary.json"

        try report(resultsPath, "--summary", summaryPath)

        let saved = try String(contentsOfFile: summaryPath, encoding: .utf8)
        let summary = try parsedJSON(saved)
        XCTAssertNil(summary["newSurvivors"], saved)
        XCTAssertNil(summary["scoreDrop"], saved)
        XCTAssertNil(summary["doubtfulKills"], saved)
        let run = try XCTUnwrap(summary["run"] as? [String: AnyHashable], saved)
        let recorded = try XCTUnwrap(run["configuration"] as? [String: AnyHashable], saved)
        XCTAssertEqual(recorded["baseline"] as? String, "\(directory)/missing.baseline.yml", saved)
        XCTAssertEqual(standardError.linesPassed.last, "Summary saved to \(summaryPath)")

        // The flag's file is read, and refused when it isn't there.
        XCTAssertThrowsError(try report(resultsPath, "--baseline", "\(directory)/missing.baseline.yml")) { error in
            XCTAssertEqual(error as? ExitCode, .baselineRefused)
        }
        // And a count still needs the flag's file: the header's doesn't count.
        let count = ["report", resultsPath, "--max-new-survivors", "1"]
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(count)) { error in
            XCTAssertEqual(MuterCommand.message(for: error), "--max-new-survivors only applies with --baseline.")
        }
    }
}
