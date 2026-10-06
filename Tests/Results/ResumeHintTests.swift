@testable import muterCore
import XCTest

final class ResumeHintTests: XCTestCase {
    // Log folders are named like `Oct 6, 2026 at 9:12 AM`.
    func test_appendsResumeWithTheQuotedPath() throws {
        let resultsFile = "/logs/Bob's project_muter_logs/Oct 6, 2026 at 9:12 AM/results.jsonl"

        let command = ResumeHint.command(continuing: ["run", "--skip-coverage", "-o", "report.txt"], from: resultsFile)

        XCTAssertEqual(
            command,
            #"swift-mutator run --skip-coverage -o report.txt "#
                + #"--resume '/logs/Bob'\''s project_muter_logs/Oct 6, 2026 at 9:12 AM/results.jsonl'"#
        )
        XCTAssertEqual(
            try wordsAShellReads(in: command),
            ["swift-mutator", "run", "--skip-coverage", "-o", "report.txt", "--resume", resultsFile]
        )
    }

    // A resumed session's arguments name the results file it continued, or the log folder that holds it: the file the
    // next session continues takes its place.
    func test_replacesAnEarlierResume_inEitherSpelling() {
        let expected = "swift-mutator run -o report.txt --resume '/logs/results.jsonl'"

        XCTAssertEqual(
            ResumeHint.command(
                continuing: ["run", "--resume", "/logs/Oct 6, 2026 at 9:12 AM", "-o", "report.txt"],
                from: "/logs/results.jsonl"
            ),
            expected
        )
        XCTAssertEqual(
            ResumeHint.command(
                continuing: ["run", "--resume=/logs/results.jsonl", "-o", "report.txt"],
                from: "/logs/results.jsonl"
            ),
            expected
        )
        XCTAssertEqual(
            ResumeHint.command(
                continuing: ["run", "--resume", "/logs/a.jsonl", "--resume=/logs/b.jsonl", "-o", "report.txt"],
                from: "/logs/results.jsonl"
            ),
            expected
        )
    }

    // The header of the session that --force-resume let through records the build and toolchain it ran with, so the
    // next session needs no force. Files a waiver names can change again before it, as the docs go on being edited.
    func test_dropsForceResume_keepsResumeIgnoring() throws {
        let command = ResumeHint.command(
            continuing: [
                "run", "--resume", "/logs/results.jsonl", "--force-resume",
                "--resume-ignoring", "README.md", "--resume-ignoring=Docs/*",
            ],
            from: "/logs/results.jsonl"
        )

        XCTAssertEqual(
            command,
            "swift-mutator run --resume-ignoring README.md '--resume-ignoring=Docs/*' --resume '/logs/results.jsonl'"
        )
        let options = try XCTUnwrap(
            MuterCommand.parseAsRoot(Array(wordsAShellReads(in: command).dropFirst())) as? Run
        ).runOptions
        XCTAssertEqual(options.resumeURL?.path, "/logs/results.jsonl")
        XCTAssertEqual(options.resumeIgnoring, ["README.md", "Docs/*"])
        XCTAssertFalse(options.forceResume)
    }

    // Arguments are repeated as they were typed where a shell reads them as they are, so the command stays readable.
    func test_quotesOnlyArgumentsAShellWouldSplit() throws {
        let plain = [
            "run", "--skip-coverage", "-o", "out/report-1.json", "Sources/A.swift,Sources/B.swift", "a_b@c%d+e=f:g",
        ]
        let quoted = [
            "My Report.txt", "Bob's", "~/report.txt", "$HOME", "Docs/*", "a;b", "{a,b}", "two\nlines", "Résumé", "",
        ]

        let command = ResumeHint.command(continuing: plain + quoted, from: "/logs/results.jsonl")

        XCTAssertEqual(
            command,
            "swift-mutator run --skip-coverage -o out/report-1.json Sources/A.swift,Sources/B.swift a_b@c%d+e=f:g "
                + #"'My Report.txt' 'Bob'\''s' '~/report.txt' '$HOME' 'Docs/*' 'a;b' '{a,b}' "#
                + "'two\nlines' 'Résumé' '' --resume '/logs/results.jsonl'"
        )
        XCTAssertEqual(
            try wordsAShellReads(in: command),
            ["swift-mutator"] + plain + quoted + ["--resume", "/logs/results.jsonl"]
        )
    }

    // `run` is SwiftMutator's default subcommand: a run started without it is continued without it.
    func test_withoutTheRunSubcommand_stillContinues() throws {
        let command = ResumeHint.command(continuing: ["--skip-coverage"], from: "/logs/results.jsonl")

        XCTAssertEqual(command, "swift-mutator --skip-coverage --resume '/logs/results.jsonl'")
        XCTAssertEqual(
            ResumeHint.command(continuing: [], from: "/logs/results.jsonl"),
            "swift-mutator --resume '/logs/results.jsonl'"
        )
        let options = try XCTUnwrap(
            MuterCommand.parseAsRoot(Array(wordsAShellReads(in: command).dropFirst())) as? Run
        ).runOptions
        XCTAssertEqual(options.resumeURL?.path, "/logs/results.jsonl")
        XCTAssertTrue(options.skipCoverage)
    }
}
