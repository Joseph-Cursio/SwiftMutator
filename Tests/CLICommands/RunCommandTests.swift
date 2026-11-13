import ArgumentParser
@testable import muterCore
import XCTest

/// The run command's options, and which error a run command shows, and how, once its work has ended under
/// `Interruptions`.
final class RunCommandTests: XCTestCase {
    func test_withoutASignal_theWorksErrorIsShown() {
        let ended = Interruptions.Ended<Void>(result: .failure(MuterError.noSourceFilesDiscovered), signal: nil)

        XCTAssertEqual(ended.errorToShow as? MuterError, .noSourceFilesDiscovered)
    }

    func test_workThatSucceeded_showsNoError_whetherOrNotASignalCame() {
        XCTAssertNil(Interruptions.Ended(result: .success(()), signal: nil).errorToShow)
        XCTAssertNil(Interruptions.Ended(result: .success(()), signal: SIGINT).errorToShow)
    }

    // Stopping has been said, and what the work threw then, such as the failure of a process the stop killed, says
    // nothing about the project.
    func test_afterASignal_anErrorTheStopMayHaveCaused_isNotShown() {
        let cancelled = Interruptions.Ended<Void>(result: .failure(CancellationError()), signal: SIGINT)
        let copyFailed = Interruptions.Ended<Void>(
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
            let ended = Interruptions.Ended<Void>(result: .failure(abort), signal: SIGINT)
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
        XCTAssertNotEqual(Run.Options.make(shard: Shard(index: 1, count: 2)), .make())
        XCTAssertNotEqual(Run.Options.make(planIgnoring: ["Sources/*"]), .make())
        XCTAssertNotEqual(Run.Options.make(mutant: MutantReference(path: "Bar.swift", line: 12)), .make())
        XCTAssertNotEqual(Run.Options.make(failUnder: 80), .make())
        XCTAssertNotEqual(Run.Options.make(reports: [ReportRequest(format: .markdown, path: "/out/r.md")]), .make())
        XCTAssertNotEqual(Run.Options.make(reports: []), .make())
    }

    // Added to the configuration's `exclude`, on each command that discovers mutants.
    func test_exclude_reachesTheRunOptions_ofEachCommandThatDiscovers() throws {
        let run = try XCTUnwrap(
            MuterCommand.parseAsRoot(["run", "--exclude", "/Generated/", "--exclude", "!/Stubs/"]) as? Run
        )
        XCTAssertEqual(run.runOptions.exclude, ["/Generated/", "!/Stubs/"])
        let plan = try MuterCommand.parseAsRoot(["mutate-without-running", "--exclude", "Sources/**/Gen*.swift"])
        XCTAssertEqual(try XCTUnwrap(plan as? MutateWithoutRunning).runOptions.exclude, ["Sources/**/Gen*.swift"])
        XCTAssertEqual(try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions.exclude, [])
        XCTAssertTrue(Run.helpMessage(columns: 200).contains("\n  --exclude <pattern>"))
        assertUsageError(
            ["run", "--mutant", "Bar.swift:12:9", "--exclude", "/Generated/"],
            "--mutant can't be given with --exclude."
        )
    }

    // For one run, in place of the configuration's keys, on each command that tests mutants.
    func test_workersAndTimeout_reachTheRunOptions_ofEachCommandThatTests() throws {
        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--workers", "4", "--timeout", "90"]) as? Run)
        XCTAssertEqual(run.runOptions.workers, 4)
        XCTAssertEqual(run.runOptions.timeout, 90)
        let plan = try MuterCommand.parseAsRoot(
            ["run-without-mutating", "--workers", "2", "--timeout", "12.5", "plan.json"]
        )
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

    // On each command that builds: `mutate-without-running`'s coverage run builds too.
    func test_buildTimeout_reachesTheRunOptions_ofEachCommandThatBuilds() throws {
        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--build-timeout", "1800"]) as? Run)
        XCTAssertEqual(run.runOptions.buildTimeout, 1_800)
        let plan = try MuterCommand.parseAsRoot(["run-without-mutating", "--build-timeout", "900", "plan.json"])
        XCTAssertEqual(try XCTUnwrap(plan as? RunWithoutMutating).runOptions.buildTimeout, 900)
        let making = try MuterCommand.parseAsRoot(["mutate-without-running", "--build-timeout", "60.5"])
        XCTAssertEqual(try XCTUnwrap(making as? MutateWithoutRunning).runOptions.buildTimeout, 60.5)
        XCTAssertNil(try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions.buildTimeout)
        XCTAssertNotEqual(Run.Options.make(buildTimeout: 30), .make())
        let help = Run.helpMessage(columns: 200)
        XCTAssertTrue(help.contains("\n  --build-timeout <seconds>"), help)
    }

    func test_aBuildTimeoutNotAboveZero_orPastADay_isAUsageError() {
        let message = "--build-timeout must be a number of seconds above 0, and at most a day (86400)."
        for value in ["0", "-5", "inf", "nan", "86401"] {
            assertUsageError(["run", "--build-timeout=\(value)"], message)
        }
        assertUsageError(["mutate-without-running", "--build-timeout", "0"], message)
        XCTAssertNoThrow(try MuterCommand.parseAsRoot(["run", "--build-timeout", "86400"]))
    }

    func test_workersBelowOne_andATimeoutNotAboveZero_areUsageErrors() {
        assertUsageError(["run", "--workers", "0"], "--workers must be at least 1.")
        assertUsageError(["run", "--workers=-2"], "--workers must be at least 1.")
        assertUsageError(
            ["run", "--timeout", "0"],
            "--timeout must be a number of seconds above 0, and at most a day (86400)."
        )
        assertUsageError(
            ["run", "--timeout=-5"],
            "--timeout must be a number of seconds above 0, and at most a day (86400)."
        )
        assertUsageError(
            ["run", "--timeout", "inf"],
            "--timeout must be a number of seconds above 0, and at most a day (86400)."
        )
        assertUsageError(
            ["run", "--timeout", "nan"],
            "--timeout must be a number of seconds above 0, and at most a day (86400)."
        )
        assertUsageError(
            ["run", "--timeout", "86401"],
            "--timeout must be a number of seconds above 0, and at most a day (86400)."
        )
        XCTAssertNoThrow(try MuterCommand.parseAsRoot(["run", "--timeout", "86400"]))
    }

    // --since chooses the files itself, and --changed-lines only narrows what it chose.
    func test_sinceOptions_needEachOther_andNotFilesToMutate() {
        assertUsageError(["run", "--changed-lines"], "--changed-lines only applies with --since.")
        assertUsageError(
            ["run", "--since", "main", "--files-to-mutate", "A.swift"],
            "--since and --files-to-mutate can't be given together."
        )
        assertUsageError(
            ["run", "--since=--all"],
            "--since takes a git ref, such as main or origin/main, not an option."
        )
    }

    func test_sinceOptions_reachTheRunOptions_andTheHelp() throws {
        let options = try XCTUnwrap(
            MuterCommand.parseAsRoot(["run", "--since", "origin/main", "--changed-lines"]) as? Run
        ).runOptions
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

    func test_shard_reachesTheRunOptions_andTheHelp_and1Of1IsTheWholeRun() throws {
        let options = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--shard", "2/3"]) as? Run).runOptions
        XCTAssertEqual(options.shard, Shard(index: 2, count: 3))
        XCTAssertNil(try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions.shard)
        XCTAssertNil(try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--shard", "1/1"]) as? Run).runOptions.shard)
        let help = Run.helpMessage(columns: 200)
        XCTAssertTrue(help.contains("\n  --shard <k/n>"), help)
    }

    func test_sample_reachesTheRunOptions_withTheSeedGiven_orOneChosen() throws {
        let given = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--sample", "500", "--seed", "1234"]) as? Run)
        XCTAssertEqual(given.runOptions.sample, Sample(size: 500, seed: 1_234, seedIsChosen: false))

        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--sample", "40"]) as? Run)
        let chosen = try XCTUnwrap(run.runOptions.sample)
        XCTAssertEqual(chosen.size, 40)
        XCTAssertTrue(chosen.seedIsChosen)
        XCTAssertTrue((1...999_999).contains(chosen.seed), "\(chosen.seed)")

        XCTAssertNil(try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions.sample)
        XCTAssertNotEqual(Run.Options.make(sample: Sample(size: 1, seed: 1, seedIsChosen: false)), .make())
        let help = Run.helpMessage(columns: 200)
        XCTAssertTrue(help.contains("\n  --sample <N>"), help)
        XCTAssertTrue(help.contains("\n  --seed <S>"), help)
    }

    func test_aSampleOrSeedThatIsntAWholeNumber_isAUsageError() {
        for value in ["0", "+5", "1.5", "half", " 5", "99999999999999999999"] {
            assertUsageError(
                ["run", "--sample", value],
                "The value '\(value)' is invalid for '--sample <N>': give a whole number of mutants, 1 or more, "
                    + "such as 500."
            )
        }
        for value in ["+1", "1.5", "seed", "18446744073709551616"] {
            assertUsageError(
                ["run", "--sample", "5", "--seed", value],
                "The value '\(value)' is invalid for '--seed <S>': give a whole number, 0 or more, such as 1234."
            )
        }
    }

    func test_aSeedWithoutASample_isAUsageError() {
        assertUsageError(["run", "--seed", "1234"], "--seed only applies with --sample.")
    }

    // A seed SwiftMutator chose would differ from shard to shard, and from the run a resume continues.
    func test_aSampleThatMustBeTakenAgain_needsItsSeed() throws {
        assertUsageError(
            ["run", "--sample", "500", "--shard", "1/2"],
            "--sample with --shard needs --seed, so that every shard takes the same sample."
        )
        assertUsageError(
            ["run", "--sample", "500", "--resume", "logs"],
            "--sample with --resume needs the sample's --seed, which the Continue line gives, and the results file's "
                + "header records as sample.seed."
        )
        for arguments in [["--shard", "1/2", "--seed", "7"], ["--shard", "1/1"], ["--resume", "logs", "--seed", "7"]] {
            XCTAssertNoThrow(try MuterCommand.parseAsRoot(["run", "--sample", "500"] + arguments), "\(arguments)")
        }
    }

    func test_aShardThatIsntKOfN_isAUsageError() {
        for value in ["0/2", "3/2", "half", "1/2/3", "1/1001"] {
            assertUsageError(
                ["run", "--shard", value],
                "The value '\(value)' is invalid for '--shard <k/n>': give two whole numbers k/n with 1 ≤ k ≤ n ≤ "
                    + "1000, such as 1/2."
            )
        }
    }
}
