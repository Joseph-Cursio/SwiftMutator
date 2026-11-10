import ArgumentParser
@testable import muterCore
import XCTest

/// `--baseline`, `--max-new-survivors` and `--write-baseline`: on each command that reports, and what each refuses.
final class BaselineFlagTests: XCTestCase {
    // On each command that tests mutants, and on `report`; never `mutate-without-running`, which tests nothing.
    func test_theFlags_reachTheRunOptions_ofEachCommandThatTests_andTheHelp() throws {
        let arguments = ["--baseline", "muter.baseline.yml", "--max-new-survivors", "3", "--write-baseline", "b.yml"]
        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run"] + arguments) as? Run).runOptions
        XCTAssertEqual(run.baseline, "muter.baseline.yml")
        XCTAssertEqual(run.maxNewSurvivors, 3)
        XCTAssertEqual(run.writeBaseline, URL(argument: "b.yml")?.path)
        let plan = try MuterCommand.parseAsRoot(["run-without-mutating"] + arguments + ["plan.json"])
        XCTAssertEqual(try XCTUnwrap(plan as? RunWithoutMutating).runOptions.maxNewSurvivors, 3)
        let report = try XCTUnwrap(MuterCommand.parseAsRoot(["report", "r.jsonl"] + arguments) as? Report)
        XCTAssertEqual(report.reportOptions.baseline, "muter.baseline.yml")
        XCTAssertEqual(report.reportOptions.allowedNewSurvivors, 3)
        XCTAssertEqual(report.reportOptions.writeBaseline, URL(argument: "b.yml")?.path)
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["mutate-without-running", "--baseline", "b.yml"]))

        for help in [Run.helpMessage(columns: 200), RunWithoutMutating.helpMessage(columns: 200)]
            + [Report.helpMessage(columns: 200)] {
            for option in ["--baseline <path>", "--max-new-survivors <count>", "--write-baseline <path>"] {
                XCTAssertTrue(help.contains("\n  \(option)"), help)
            }
            XCTAssertTrue(help.contains("baseline file"), help)
        }
        XCTAssertFalse(MutateWithoutRunning.helpMessage(columns: 200).contains("--baseline"))
    }

    // `--baseline` alone allows no new survivor; without it, nothing is compared.
    func test_maxNewSurvivors_is0_withBaselineAlone_andNilWithout() throws {
        let alone = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--baseline", "b.yml"]) as? Run).runOptions
        XCTAssertEqual(alone.maxNewSurvivors, 0)
        let plain = try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions
        XCTAssertNil(plain.baseline)
        XCTAssertNil(plain.maxNewSurvivors)
        XCTAssertNil(plain.writeBaseline)
        XCTAssertNotEqual(Run.Options.make(baseline: "b.yml"), .make())
        XCTAssertNotEqual(Run.Options.make(writeBaseline: "b.yml"), .make())
    }

    func test_maxNewSurvivors_withoutBaseline_orNotAWholeNumber_isAUsageError() {
        for command in [["run"], ["report", "r.jsonl"], ["run-without-mutating", "plan.json"]] {
            assertUsageError(
                command + ["--max-new-survivors", "2"],
                "--max-new-survivors only applies with --baseline."
            )
        }
        for value in ["-1", "1.5", "x"] {
            assertUsageError(
                ["run", "--baseline", "b.yml", "--max-new-survivors=\(value)"],
                "The value '\(value)' is invalid for '--max-new-survivors <count>': give a whole number of "
                    + "survivors, 0 or more, such as 3."
            )
        }
    }

    // On each command that tests mutants, and on `report`, as `--max-new-survivors` is.
    func test_maxScoreDrop_andMaxDoubtfulKills_reachEachCommand_andTheHelp() throws {
        let arguments = ["--baseline", "b.yml", "--max-score-drop", "2.5", "--max-doubtful-kills", "0"]
        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run"] + arguments) as? Run).runOptions
        XCTAssertEqual(run.maxScoreDrop, 2.5)
        XCTAssertEqual(run.maxDoubtfulKills, 0)
        let plan = try XCTUnwrap(
            MuterCommand.parseAsRoot(["run-without-mutating"] + arguments + ["plan.json"]) as? RunWithoutMutating
        )
        XCTAssertEqual(plan.runOptions.maxScoreDrop, 2.5)
        XCTAssertEqual(plan.runOptions.maxDoubtfulKills, 0)
        let report = try XCTUnwrap(MuterCommand.parseAsRoot(["report", "r.jsonl"] + arguments) as? Report)
        XCTAssertEqual(report.reportOptions.maxScoreDrop, 2.5)
        XCTAssertEqual(report.reportOptions.maxDoubtfulKills, 0)
        XCTAssertNotEqual(Run.Options.make(baseline: "b.yml", maxScoreDrop: 2), .make(baseline: "b.yml"))
        XCTAssertNotEqual(Run.Options.make(maxDoubtfulKills: 0), .make())

        let plain = try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions
        XCTAssertNil(plain.maxScoreDrop)
        XCTAssertNil(plain.maxDoubtfulKills)
        // It counts what was tested, with or without a baseline file.
        let alone = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--max-doubtful-kills", "3"]) as? Run).runOptions
        XCTAssertEqual(alone.maxDoubtfulKills, 3)

        for help in [Run.helpMessage(columns: 200), RunWithoutMutating.helpMessage(columns: 200)]
            + [Report.helpMessage(columns: 200)] {
            for option in ["--max-score-drop <points>", "--max-doubtful-kills <count>"] {
                XCTAssertTrue(help.contains("\n  \(option)"), help)
            }
        }
    }

    func test_maxScoreDrop_withoutBaseline_orABadValue_isAUsageError() {
        for command in [["run"], ["report", "r.jsonl"], ["run-without-mutating", "plan.json"]] {
            assertUsageError(command + ["--max-score-drop", "2"], "--max-score-drop only applies with --baseline.")
        }
        for value in ["-1", "100.5", "1e2", "0.0000001", "x"] {
            assertUsageError(
                ["run", "--baseline", "b.yml", "--max-score-drop=\(value)"],
                "The value '\(value)' is invalid for '--max-score-drop <points>': give a number of points from 0 to "
                    + "100, with at most 6 decimals, such as 2 or 0.5."
            )
        }
        for value in ["-1", "1.5", "x"] {
            assertUsageError(
                ["report", "r.jsonl", "--max-doubtful-kills=\(value)"],
                "The value '\(value)' is invalid for '--max-doubtful-kills <count>': give a whole number of kills, 0 "
                    + "or more, such as 3."
            )
        }
    }

    // They are flags, not configuration, so a resume doesn't compare them: a resume may give them or not.
    func test_aResume_takesTheNewFlags() {
        XCTAssertNoThrow(
            try MuterCommand.parseAsRoot([
                "run", "--resume", "/logs/results.jsonl", "--baseline", "b.yml", "--max-score-drop", "2",
                "--max-doubtful-kills", "0",
            ])
        )
    }

    // A baseline file holds a whole run's survivors.
    func test_writeBaseline_withAnOptionThatLeavesMutantsOut_isAUsageError() {
        let limits = [
            (["--mutant", "Bar.swift:12:9"], "--mutant"),
            (["--shard", "1/2"], "--shard"),
            (["--sample", "40", "--seed", "1"], "--sample"),
            (["--since", "main"], "--since"),
            (["--files-to-mutate", "A.swift"], "--files-to-mutate"),
        ]
        for (arguments, option) in limits {
            assertUsageError(
                ["run", "--write-baseline", "b.yml"] + arguments,
                "--write-baseline can't be given with \(option): a baseline file holds a whole run's survivors."
            )
        }
        assertUsageError(
            ["run-without-mutating", "--write-baseline", "b.yml", "--mutant", "Bar.swift:12:9", "plan.json"],
            "--write-baseline can't be given with --mutant: a baseline file holds a whole run's survivors."
        )
        // 1/1 is the whole run.
        XCTAssertNoThrow(try MuterCommand.parseAsRoot(["run", "--write-baseline", "b.yml", "--shard", "1/1"]))
        // A limited run is compared on what it tested.
        XCTAssertNoThrow(try MuterCommand.parseAsRoot(["run", "--baseline", "b.yml", "--since", "main"]))
    }

    // It is read as the run starts, and replaced at the end: how a main-branch job updates it.
    func test_writeBaseline_mayBeTheBaselinesOwnFile_butNoReportsPath() throws {
        XCTAssertNoThrow(
            try MuterCommand.parseAsRoot(["run", "--baseline", "b.yml", "--write-baseline", "b.yml"])
        )
        assertUsageError(
            ["run", "-o", "/out/b.yml", "--write-baseline", "/out/b.yml"],
            "-o /out/b.yml and --write-baseline /out/b.yml would save to the same file: give each report a path of its "
                + "own."
        )
        assertUsageError(
            ["report", "r.jsonl", "--report", "markdown:/out/b.yml", "--write-baseline", "/out/b.yml"],
            "--report markdown:/out/b.yml and --write-baseline /out/b.yml would save to the same file: give each "
                + "report a path of its own."
        )
    }

    private func assertUsageError(
        _ arguments: [String],
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(arguments), file: file, line: line) { error in
            XCTAssertEqual(MuterCommand.exitCode(for: error), .validationFailure, file: file, line: line)
            XCTAssertEqual(MuterCommand.message(for: error), message, file: file, line: line)
        }
    }
}
