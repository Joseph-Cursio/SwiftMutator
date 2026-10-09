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
        XCTAssertNotEqual(Run.Options.make(resumeIgnoring: ["README.md"]), .make())
        XCTAssertNotEqual(Run.Options.make(forceResume: true), .make())
        XCTAssertNotEqual(Run.Options.make(verbose: true), .make())
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
        XCTAssertEqual(options.resumeIgnoring, [])
        XCTAssertFalse(options.forceResume)
    }

    // The help snapshot's test only runs once the acceptance tests' samples are made; this one always runs.
    func test_runHelp_namesTheResumeOptions() {
        let help = Run.helpMessage(columns: 200)

        XCTAssertTrue(
            help.contains("[--resume <results>] [--resume-ignoring <glob> ...] [--force-resume]"),
            help
        )
        XCTAssertTrue(help.contains("Continue a stopped run from its results file"), help)
        XCTAssertTrue(help.contains("* also matches /. Repeatable."), help)
        XCTAssertTrue(help.contains("reuse results although SwiftMutator, the toolchain or the SDK changed."), help)
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
        XCTAssertTrue(help.contains("[--skip-update-check] [--verbose]"), help)
        let verbose = "Lists how many mutants are in each file that has any, and the Swift files found, if the "
            + "command looks for them."
        XCTAssertTrue(help.contains(verbose), help)
    }

    // Refusing is an expected outcome, whose message says what to do; it isn't a bug to report.
    func test_aResumeRefusal_isShownWithoutTheBugReportBanner() {
        let refused = ResumeRefused(
            path: "/logs/results.jsonl",
            reasons: [.inUse(lastProcess: 81234, lastHost: "studio.local")],
            beforeTheCopy: true
        )

        XCTAssertEqual(Run.message(showing: refused), "\(refused)")
        let other = Run.message(showing: MuterError.noSourceFilesDiscovered)
        XCTAssertTrue(other.contains("SwiftMutator has encountered an error"), other)
        XCTAssertTrue(other.contains("\(MuterError.noSourceFilesDiscovered)"), other)
        XCTAssertTrue(other.contains("please open an issue"), other)
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
