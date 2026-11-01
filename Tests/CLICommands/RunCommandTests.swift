import ArgumentParser
@testable import muterCore
import XCTest

/// The run command's options, and which error a run command shows, and how, once its work has ended under
/// `Interruptions`.
final class RunCommandTests: XCTestCase {
    func test_withoutASignal_theWorksErrorIsShown() {
        let ended = Interruptions.Ended(result: .failure(MuterError.noSourceFilesDiscovered), signal: nil)

        XCTAssertEqual(ended.errorToShow as? MuterError, .noSourceFilesDiscovered)
    }

    func test_workThatSucceeded_showsNoError_whetherOrNotASignalCame() {
        XCTAssertNil(Interruptions.Ended(result: .success(()), signal: nil).errorToShow)
        XCTAssertNil(Interruptions.Ended(result: .success(()), signal: SIGINT).errorToShow)
    }

    // Stopping has been said, and what the work threw then, such as the failure of a process the stop killed, says
    // nothing about the project.
    func test_afterASignal_anErrorTheStopMayHaveCaused_isNotShown() {
        let cancelled = Interruptions.Ended(result: .failure(CancellationError()), signal: SIGINT)
        let copyFailed = Interruptions.Ended(
            result: .failure(MuterError.projectCopyFailed(reason: "cp was killed")),
            signal: SIGTERM
        )

        XCTAssertNil(cancelled.errorToShow)
        XCTAssertNil(copyFailed.errorToShow)
    }

    // Mutation testing aborted, and its summary on standard error pointed at "the error below"; then a Ctrl-C came
    // while worker clones were removed. No signal causes an abort, so the abort came first.
    func test_anAbortBeforeASignal_isStillShown() {
        let aborts = [
            MuterError.mutationTestingAborted(reason: .tooManyBuildErrors),
            MuterError.mutationTestingAborted(
                reason: .workerBaselineTestFailed(worker: 1, directory: "/project_mutated_worker1", log: "error: x")
            ),
        ]

        for abort in aborts {
            let ended = Interruptions.Ended(result: .failure(abort), signal: SIGINT)
            XCTAssertEqual(ended.errorToShow as? MuterError, abort)
        }
    }

    // Two runs' options that differ in any field aren't the same options.
    func test_runOptionsEquality_coversEveryField() {
        XCTAssertNotEqual(Run.Options.make(createTestPlan: true), .make())
        XCTAssertNotEqual(Run.Options.make(resumeURL: URL(fileURLWithPath: "/logs/results.jsonl")), .make())
        XCTAssertNotEqual(Run.Options.make(reuseURL: URL(fileURLWithPath: "/logs/results.jsonl")), .make())
        XCTAssertNotEqual(Run.Options.make(resumeIgnoring: ["README.md"]), .make())
        XCTAssertNotEqual(Run.Options.make(forceResume: true), .make())
        XCTAssertNotEqual(Run.Options.make(verbose: true), .make())
        XCTAssertNotEqual(Run.Options.make(since: "main"), .make())
        XCTAssertNotEqual(Run.Options.make(since: "main", changedLinesOnly: true), .make(since: "main"))
    }

    // For one run, in place of the configuration's keys, on each command that tests mutants.
    func test_workersAndTimeout_reachTheRunOptions_ofEachCommandThatTests() throws {
        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--workers", "4", "--timeout", "90"]) as? Run)
        XCTAssertEqual(run.runOptions.workers, 4)
        XCTAssertEqual(run.runOptions.timeout, 90)
        let plan = try MuterCommand.parseAsRoot(["run-without-mutating", "--workers", "2", "--timeout", "12.5", "plan.json"])
        XCTAssertEqual(try XCTUnwrap(plan as? RunWithoutMutating).runOptions.workers, 2)
        XCTAssertEqual(try XCTUnwrap(plan as? RunWithoutMutating).runOptions.timeout, 12.5)
        let plain = try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions
        XCTAssertNil(plain.workers)
        XCTAssertNil(plain.timeout)
        XCTAssertNotEqual(Run.Options.make(workers: 2), .make())
        XCTAssertNotEqual(Run.Options.make(timeout: 30), .make())
        let help = Run.helpMessage(columns: 200)
        XCTAssertTrue(help.contains("\n  --workers <count>"), help)
        XCTAssertTrue(help.contains("\n  --timeout <seconds>"), help)
    }

    func test_workersBelowOne_andATimeoutNotAboveZero_areUsageErrors() {
        assertUsageError(["run", "--workers", "0"], "--workers must be at least 1.")
        assertUsageError(["run", "--workers=-2"], "--workers must be at least 1.")
        assertUsageError(["run", "--timeout", "0"], "--timeout must be a number of seconds above 0.")
        assertUsageError(["run", "--timeout=-5"], "--timeout must be a number of seconds above 0.")
        assertUsageError(["run", "--timeout", "inf"], "--timeout must be a number of seconds above 0.")
        assertUsageError(["run", "--timeout", "nan"], "--timeout must be a number of seconds above 0.")
    }

    // --since chooses the files itself, and --changed-lines only narrows what it chose.
    func test_sinceOptions_needEachOther_andNotFilesToMutate() {
        assertUsageError(["run", "--changed-lines"], "--changed-lines only applies with --since.")
        assertUsageError(
            ["run", "--since", "main", "--files-to-mutate", "A.swift"],
            "--since and --files-to-mutate can't be given together."
        )
        assertUsageError(["run", "--since=--all"], "--since takes a git ref, such as main or origin/main, not an option.")
    }

    func test_sinceOptions_reachTheRunOptions_andTheHelp() throws {
        let options = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--since", "origin/main", "--changed-lines"]) as? Run)
            .runOptions
        XCTAssertEqual(options.since, "origin/main")
        XCTAssertTrue(options.changedLinesOnly)
        let plain = try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions
        XCTAssertNil(plain.since)
        XCTAssertFalse(plain.changedLinesOnly)
        let help = Run.helpMessage(columns: 200)
        XCTAssertTrue(help.contains("\n  --since <ref>"), help)
        XCTAssertTrue(help.contains("\n  --changed-lines"), help)
        XCTAssertTrue(help.contains("merge base of this git ref and HEAD"), help)
    }

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
        assertUsageError(["run", "--reuse", "/logs/results.jsonl", "--force-resume"], "--force-resume only applies with --resume.")
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

    // Each command that runs mutation testing takes it, as it takes --skip-coverage.
    func test_verbose_reachesTheRunOptions_ofEachRunCommand_andTheHelp() throws {
        XCTAssertTrue(try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--verbose"]) as? Run).runOptions.verbose)
        XCTAssertFalse(try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions.verbose)
        let mutate = try MuterCommand.parseAsRoot(["mutate-without-running", "--verbose"])
        XCTAssertTrue(try XCTUnwrap(mutate as? MutateWithoutRunning).runOptions.verbose)
        let runPlan = try MuterCommand.parseAsRoot(["run-without-mutating", "--verbose", "plan.json"])
        XCTAssertTrue(try XCTUnwrap(runPlan as? RunWithoutMutating).runOptions.verbose)
        let help = Run.helpMessage(columns: 200)
        XCTAssertTrue(help.contains("\n  --verbose "), help)
        let verbose = "Lists how many mutants are in each file that has any, and the Swift files found, if the "
            + "command looks for them."
        XCTAssertTrue(help.contains(verbose), help)
    }

    // Refusing is an expected outcome, whose message says what to do; it isn't a bug to report.
    func test_aRefusal_isShownWithoutTheBugReportBanner() {
        let refused = ResumeRefused(
            path: "/logs/results.jsonl",
            reasons: [.inUse(lastProcess: 81234, lastHost: "studio.local")],
            beforeTheCopy: true
        )

        XCTAssertEqual(Run.message(showing: refused), "\(refused)")
        let inUse = MutatedProjectLockError.inUse(mutatedProject: "/code/x_mutated", process: 81234)
        XCTAssertEqual(Run.message(showing: inUse), "\(inUse)")
        let cannotLock = Run.message(showing: MutatedProjectLockError.cannotLock(path: "/x.lock", errno: EACCES))
        XCTAssertTrue(cannotLock.contains("SwiftMutator has encountered an error"), cannotLock)
        let other = Run.message(showing: MuterError.noSourceFilesDiscovered)
        XCTAssertTrue(other.contains("SwiftMutator has encountered an error"), other)
        XCTAssertTrue(other.contains("\(MuterError.noSourceFilesDiscovered)"), other)
        XCTAssertTrue(other.contains("please open an issue"), other)
    }

    // git couldn't answer, or there is nothing to mutate: each says what happened, and neither is a bug.
    func test_sinceOutcomes_areShownWithoutTheBugReportBanner() {
        let unknown = ChangeSelectionError.unknownRef("origin/main")
        XCTAssertEqual(Run.message(showing: unknown), "\(unknown)")
        let nothing = NothingToMutate(reason: .noSwiftFileChanged, selection: .make())
        XCTAssertEqual(Run.message(showing: nothing), "\(nothing)")
    }
}

private extension RunCommandTests {
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
