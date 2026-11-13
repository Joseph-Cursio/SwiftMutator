import ArgumentParser
@testable import muterCore
import XCTest

extension RunCommandTests {
    // They only say what a resume may reuse, so without one they're a mistake, which ArgumentParser shows with the
    // usage and exit status 64.
    func test_resumeIgnoringWithoutResume_isAUsageError() {
        assertUsageError(["run", "--resume-ignoring", "README.md"], "--resume-ignoring only applies with --resume.")
    }

    func test_forceResumeWithoutResume_isAUsageError() {
        assertUsageError(["run", "--force-resume"], "--force-resume only applies with --resume.")
        assertUsageError(["--force-resume", "--skip-coverage"], "--force-resume only applies with --resume.")
    }

    // Each pair says what its own option may reuse: a resume's waivers would let test files' changes through, which a
    // reuse's never do.
    func test_reuseOptions_onlyApplyWithReuse_andNotWithResume() {
        assertUsageError(["run", "--reuse-ignoring", "README.md"], "--reuse-ignoring only applies with --reuse.")
        assertUsageError(["run", "--force-reuse"], "--force-reuse only applies with --reuse.")
        assertUsageError(
            ["run", "--resume", "/logs/a.jsonl", "--reuse", "/logs/b.jsonl"],
            "--resume and --reuse can't be given together."
        )
        assertUsageError(
            ["run", "--reuse", "/logs/results.jsonl", "--resume-ignoring", "README.md"],
            "--resume-ignoring only applies with --resume."
        )
        assertUsageError(
            ["run", "--reuse", "/logs/results.jsonl", "--force-resume"],
            "--force-resume only applies with --resume."
        )
    }

    func test_reuseOptions_reachTheRunOptions() throws {
        let command = try MuterCommand.parseAsRoot([
            "run", "--reuse", "/logs/results.jsonl", "--reuse-ignoring", "README.md", "--force-reuse",
        ])

        let options = try XCTUnwrap(command as? Run).runOptions
        XCTAssertNil(options.resumeURL)
        XCTAssertEqual(options.reuseURL?.path, "/logs/results.jsonl")
        XCTAssertEqual(options.continuedFrom?.path, "/logs/results.jsonl")
        XCTAssertTrue(options.isReuse)
        XCTAssertEqual(options.resumeIgnoring, ["README.md"])
        XCTAssertTrue(options.forceResume)
    }

    func test_resumeOptions_reachTheRunOptions() throws {
        let command = try MuterCommand.parseAsRoot([
            "run", "--skip-coverage",
            "--resume", "/logs/results.jsonl",
            "--resume-ignoring", "README.md",
            "--resume-ignoring", "Docs/*",
            "--force-resume",
        ])

        let options = try XCTUnwrap(command as? Run).runOptions
        XCTAssertEqual(options.resumeURL?.path, "/logs/results.jsonl")
        XCTAssertEqual(options.resumeIgnoring, ["README.md", "Docs/*"])
        XCTAssertTrue(options.forceResume)
        XCTAssertTrue(options.skipCoverage)
    }

    func test_withoutResumeOptions_theRunIsNotResumed() throws {
        let options = try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions

        XCTAssertNil(options.resumeURL)
        XCTAssertNil(options.reuseURL)
        XCTAssertFalse(options.isReuse)
        XCTAssertEqual(options.resumeIgnoring, [])
        XCTAssertFalse(options.forceResume)
    }

    // A run of a test plan resumes as a run does, with the same options, and only resumes: an earlier run's results
    // aren't reused for a plan.
    func test_resumeOptions_reachTheRunOptions_ofRunWithoutMutating() throws {
        let command = try MuterCommand.parseAsRoot([
            "run-without-mutating", "muter-mappings.json",
            "--resume", "/logs/results.jsonl",
            "--resume-ignoring", "Sources/Sum.swift",
            "--force-resume",
            "--plan-ignoring", "*.md",
        ])

        let options = try XCTUnwrap(command as? RunWithoutMutating).runOptions
        XCTAssertEqual(options.testPlanURL?.lastPathComponent, "muter-mappings.json")
        XCTAssertEqual(options.resumeURL?.path, "/logs/results.jsonl")
        XCTAssertFalse(options.isReuse)
        XCTAssertEqual(options.resumeIgnoring, ["Sources/Sum.swift"])
        XCTAssertTrue(options.forceResume)
        XCTAssertEqual(options.planIgnoring, ["*.md"], "kept apart from --resume-ignoring")

        let unresumed = try XCTUnwrap(
            MuterCommand.parseAsRoot(["run-without-mutating", "muter-mappings.json"]) as? RunWithoutMutating
        ).runOptions
        XCTAssertNil(unresumed.resumeURL)
        XCTAssertEqual(unresumed.resumeIgnoring, [])
        XCTAssertFalse(unresumed.forceResume)
        XCTAssertThrowsError(
            try MuterCommand.parseAsRoot(["run-without-mutating", "muter-mappings.json", "--reuse", "/logs/r.jsonl"])
        )
    }

    func test_resumeOptionsWithoutResume_areUsageErrors_ofRunWithoutMutating() {
        assertUsageError(
            ["run-without-mutating", "muter-mappings.json", "--resume-ignoring", "Sources/*"],
            "--resume-ignoring only applies with --resume."
        )
        assertUsageError(
            ["run-without-mutating", "muter-mappings.json", "--force-resume"],
            "--force-resume only applies with --resume."
        )
    }

    func test_runWithoutMutatingHelp_namesTheResumeOptions_beforePlanIgnoring() {
        let help = RunWithoutMutating.helpMessage(columns: 200)

        let options = ["--resume <results>", "--resume-ignoring <glob>", "--force-resume", "--plan-ignoring <glob>"]
        let places = options.compactMap { help.range(of: "\n  \($0)")?.lowerBound }
        XCTAssertEqual(places.count, options.count, help)
        XCTAssertEqual(places, places.sorted(), help)
        XCTAssertFalse(help.contains("--reuse"), help)
    }

    // The help snapshot's test only runs once the acceptance tests' samples are made; this one always runs.
    func test_runHelp_namesTheResumeOptions() {
        let help = Run.helpMessage(columns: 200)

        // With as many options as `run` has, the usage line says only `<options>`, and the list names each.
        for option in ["--resume <results>", "--resume-ignoring <glob>", "--force-resume"] {
            XCTAssertTrue(help.contains("\n  \(option)"), option)
        }
        XCTAssertTrue(help.contains("Continue a stopped run from its results file"), help)
        XCTAssertTrue(help.contains("* also matches /. Repeatable."), help)
        XCTAssertTrue(help.contains("reuse results although SwiftMutator, the toolchain or the SDK changed."), help)
        for option in ["--reuse <results>", "--reuse-ignoring <glob>", "--force-reuse"] {
            XCTAssertTrue(help.contains("\n  \(option)"), option)
        }
        XCTAssertTrue(help.contains("Start a new run from an earlier run's results file"), help)
        XCTAssertTrue(help.contains("Test files are never waived."), help)
    }
}
