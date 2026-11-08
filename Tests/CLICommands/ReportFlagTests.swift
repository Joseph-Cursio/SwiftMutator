import ArgumentParser
@testable import muterCore
import XCTest

/// `--report format:path`: the reports a command saves besides `-f`'s.
final class ReportFlagTests: XCTestCase {
    // On each command that tests mutants, in place of reports:, and on `report`; never `mutate-without-running`, which
    // makes no report. Repeatable, one request each, with its path resolved as -o's is.
    func test_report_reachesTheRunOptions_ofEachCommandThatReports_andTheHelp() throws {
        let arguments = ["--report", "markdown:/out/summary.md", "--report", "html:/out/a:b.html"]
        let expected = [
            ReportRequest(format: .markdown, path: "/out/summary.md"),
            ReportRequest(format: .html, path: "/out/a:b.html"),
        ]
        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run"] + arguments) as? Run)
        XCTAssertEqual(run.runOptions.reports, expected)
        let plan = try MuterCommand.parseAsRoot(["run-without-mutating"] + arguments + ["plan.json"])
        XCTAssertEqual(try XCTUnwrap(plan as? RunWithoutMutating).runOptions.reports, expected)
        XCTAssertNil(try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions.reports)
        let report = try XCTUnwrap(MuterCommand.parseAsRoot(["report", "r.jsonl"] + arguments) as? Report)
        XCTAssertEqual(report.reportOptions.reports, expected)
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["mutate-without-running"] + arguments))
        for help in [Run.helpMessage(columns: 200), RunWithoutMutating.helpMessage(columns: 200)]
            + [Report.helpMessage(columns: 200)] {
            XCTAssertTrue(help.contains("\n  --report <format:path>"), help)
            XCTAssertTrue(help.contains("plain, json, html, xcode, markdown"), help)
        }
        XCTAssertFalse(MutateWithoutRunning.helpMessage(columns: 200).contains("--report"))
    }

    func test_aRelativePath_isResolvedAgainstTheCurrentDirectory_asOutputsIs() throws {
        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--report", "markdown:summary.md"]) as? Run)

        XCTAssertEqual(
            run.runOptions.reports?.map(\.path),
            [FileManager.default.currentDirectoryPath + "/summary.md"]
        )
    }

    // A shell leaves `~` alone after `--output=` and in quotes; a report's missing folders are made, so a literal `~`
    // would become a folder of that name in the project.
    func test_aLeadingTilde_inOutputAndSummary_isTheHomeFolder() throws {
        let home = NSHomeDirectory()
        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--output=~/out/report.txt"]) as? Run)
        XCTAssertEqual(run.runOptions.reportOptions.path, home + "/out/report.txt")
        let report = try XCTUnwrap(
            MuterCommand.parseAsRoot(["report", "r.jsonl", "-o", "~/r.txt", "--summary", "~/s.json"]) as? Report
        )
        XCTAssertEqual(report.reportOptions.reportURL?.path, home + "/r.txt")
        XCTAssertEqual(report.summary?.path, home + "/s.json")
        let inAFolder = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "-o", "out/~/report.txt"]) as? Run)
        XCTAssertTrue(try XCTUnwrap(inAFolder.runOptions.reportOptions.path).hasSuffix("out/~/report.txt"))
    }

    func test_aValueThatIsntARequest_isAUsageError() {
        let refused = [
            ("summary.md", "name the format and then the path, as format:path, such as markdown:summary.md."),
            (":summary.md", "name the format and then the path, as format:path, such as markdown:summary.md."),
            (
                "pdf:summary.pdf",
                "start with one of the formats plain, json, html, markdown, stryker, sarif, as format:path, such as "
                    + "markdown:summary.md."
            ),
            ("markdown:", "give a path after the format, as format:path, such as markdown:summary.md."),
            ("xcode:report.txt", "save the Xcode format with -f xcode, as its warnings are printed while the run "
                + "goes, which only -f's report is; here give another format, such as markdown:summary.md."),
        ]
        for (value, reason) in refused {
            for command in [["run"], ["report", "r.jsonl"]] {
                assertUsageError(
                    command + ["--report=\(value)"],
                    "The value '\(value)' is invalid for '--report <format:path>': \(reason)"
                )
            }
        }
    }

    // Each report needs a file of its own, and a stopped run writes each one's partial report beside it, which
    // `report` never does.
    func test_twoReportsAtOnePath_areAUsageError() {
        let clashes = [
            (
                ["-o", "/out/r.md", "--report", "markdown:/out/r.md"],
                "-o /out/r.md and --report markdown:/out/r.md would save to the same file"
            ),
            (
                ["--report", "json:/out/r.json", "--report", "html:/out/./r.json"],
                "--report json:/out/r.json and --report html:/out/./r.json would save to the same file"
            ),
            (
                ["-o", "/out/r.txt", "--report", "markdown:/out/r.partial.txt"],
                "--report markdown:/out/r.partial.txt would save where -o /out/r.txt's partial report goes when a "
                    + "run stops"
            ),
            (
                ["--report", "markdown:/out/r.partial.md", "--report", "html:/out/r.md"],
                "--report markdown:/out/r.partial.md would save where --report html:/out/r.md's partial report goes "
                    + "when a run stops"
            ),
        ]
        for (index, (arguments, clash)) in clashes.enumerated() {
            for command in [["run"], ["run-without-mutating", "plan.json"], ["report", "r.jsonl"]] {
                // The last two are a partial report's path, which only a run writes.
                guard command[0] != "report" || index < 2 else {
                    XCTAssertNoThrow(try MuterCommand.parseAsRoot(command + arguments))
                    continue
                }
                assertUsageError(command + arguments, "\(clash): give each report a path of its own.")
            }
        }
        XCTAssertNoThrow(
            try MuterCommand.parseAsRoot(["run", "-o", "/out/r.txt", "--report", "markdown:/out/r.md"])
        )
    }

    // A stopped run's Continue command keeps them, as it does every option it doesn't rewrite.
    func test_theContinueCommand_keepsTheReports() {
        let command = ResumeHint.command(
            continuing: ["swift-mutator", "run", "--report", "markdown:/out/summary.md"],
            from: "/logs/results.jsonl",
            since: nil,
            chosenSeed: nil
        )

        XCTAssertTrue(command.contains("--report markdown:/out/summary.md"), command)
    }
}

private extension ReportFlagTests {
    /// Checks that parsing `arguments` fails validation with `message`.
    func assertUsageError(
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
