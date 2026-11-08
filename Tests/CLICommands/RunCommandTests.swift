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
    }

    // Both commands that test mutants take it, and `run` skips coverage for it, which only leaves files and code out of
    // discovery. Every file is still discovered with every operator: its path may be only the end of one, and a wrong
    // operator is refused with the mutants near its place, whatever their operators.
    func test_mutant_reachesTheRunOptions_ofRunAndRunWithoutMutating() throws {
        let named = MutantReference(
            path: "Sources/Foo/Bar.swift", line: 12, column: 9, mutationOperatorId: .swapTernary
        )
        let run = try XCTUnwrap(
            MuterCommand.parseAsRoot(["run", "--mutant", "Sources/Foo/Bar.swift:12:9 SwapTernary"]) as? Run
        ).runOptions
        XCTAssertEqual(run.mutant, named)
        XCTAssertTrue(run.skipCoverage)
        XCTAssertEqual(run.mutationOperatorsList, .allOperators)
        XCTAssertEqual(run.filesToMutate, [])

        let anyOperator = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--mutant", "Bar.swift:12"]) as? Run)
        XCTAssertEqual(anyOperator.runOptions.mutant, MutantReference(path: "Bar.swift", line: 12))
        XCTAssertEqual(anyOperator.runOptions.mutationOperatorsList, .allOperators)

        let plain = try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions
        XCTAssertNil(plain.mutant)
        XCTAssertFalse(plain.skipCoverage)

        let plan = try XCTUnwrap(
            MuterCommand.parseAsRoot(["run-without-mutating", "plan.json", "--mutant", "Bar.swift:12:9"])
                as? RunWithoutMutating
        ).runOptions
        XCTAssertEqual(plan.mutant, MutantReference(path: "Bar.swift", line: 12, column: 9))
        XCTAssertEqual(plan.testPlanURL?.lastPathComponent, "plan.json")
    }

    func test_aMutantThatDoesntRead_isAUsageError() {
        assertUsageError(
            ["run", "--mutant", "Bar.swift"],
            "The value 'Bar.swift' is invalid for '--mutant <mutant>': give the mutant as path:line[:column] "
                + "[Operator], such as 'Sources/Foo/Bar.swift:12:9 SwapTernary'."
        )
    }

    // It names the one mutant to test, so nothing else that chooses mutants, or continues a run, goes with it.
    func test_mutant_withAnotherOptionThatChoosesMutants_isAUsageError() {
        let others: [(option: String, arguments: [String])] = [
            ("--operators", ["--operators", "SwapTernary"]),
            ("--files-to-mutate", ["--files-to-mutate", "Sources/Foo/Bar.swift"]),
            ("--since", ["--since", "main"]),
            ("--shard", ["--shard", "1/2"]),
            ("--sample", ["--sample", "5", "--seed", "1"]),
            ("--resume", ["--resume", "/logs/results.jsonl"]),
            ("--reuse", ["--reuse", "/logs/results.jsonl"]),
        ]
        for (option, arguments) in others {
            assertUsageError(
                ["run", "--mutant", "Bar.swift:12:9"] + arguments,
                "--mutant can't be given with \(option)."
            )
        }
        assertUsageError(
            ["run-without-mutating", "plan.json", "--mutant", "Bar.swift:12:9", "--resume", "/logs/results.jsonl"],
            "--mutant can't be given with --resume."
        )
        XCTAssertNoThrow(try MuterCommand.parseAsRoot(["run", "--mutant", "Bar.swift:12:9", "--shard", "1/1"]))
    }

    // `run`'s help gains only --mutant, after the other options that choose mutants.
    func test_mutant_isInTheHelp_ofRunAndRunWithoutMutating() {
        let help = Run.helpMessage(columns: 200)
        let seed = help.range(of: "\n  --seed <S>")
        let mutant = help.range(of: "\n  --mutant <mutant>")
        let configuration = help.range(of: "\n  -c, --configuration")
        XCTAssertNotNil(mutant, help)
        if let seed, let mutant, let configuration {
            XCTAssertLessThan(seed.lowerBound, mutant.lowerBound, help)
            XCTAssertLessThan(mutant.lowerBound, configuration.lowerBound, help)
        }
        XCTAssertTrue(
            help.contains("Test only this mutant, and print its change, its tests' log and its verdict:"),
            help
        )
        let options = RunWithoutMutating.helpMessage(columns: 200).components(separatedBy: "OPTIONS:\n").last ?? ""
        XCTAssertTrue(options.hasPrefix("  --mutant <mutant>"), options)
    }

    // Repeatable, and only on the command that tests a plan.
    func test_planIgnoring_reachesTheRunOptions_ofRunWithoutMutating() throws {
        let plan = try XCTUnwrap(
            MuterCommand.parseAsRoot(
                ["run-without-mutating", "--plan-ignoring", "Sources/A.swift", "--plan-ignoring", "*.md", "plan.json"]
            ) as? RunWithoutMutating
        )
        XCTAssertEqual(plan.runOptions.planIgnoring, ["Sources/A.swift", "*.md"])
        XCTAssertEqual(
            try XCTUnwrap(MuterCommand.parseAsRoot(["run-without-mutating", "plan.json"]) as? RunWithoutMutating)
                .runOptions.planIgnoring,
            []
        )
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["run", "--plan-ignoring", "*.md"]))
        let help = RunWithoutMutating.helpMessage(columns: 200)
        XCTAssertTrue(help.contains("\n  --plan-ignoring <glob>"), help)
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
        XCTAssertEqual(given.runOptions.sample, Sample(size: 500, seed: 1234, seedIsChosen: false))

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

    // The plan records what they chose, so mutate-without-running takes them as run does.
    func test_operatorsAndFilesToMutate_reachTheRunOptions_ofRunAndMutateWithoutRunning() throws {
        let chosen = ["--files-to-mutate", "Sources/A.swift,B.swift", "--operators", "SwapTernary", "RemoveSideEffects"]
        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run"] + chosen) as? Run).runOptions
        let mutate = try XCTUnwrap(
            MuterCommand.parseAsRoot(["mutate-without-running"] + chosen) as? MutateWithoutRunning
        ).runOptions

        for options in [run, mutate] {
            XCTAssertEqual(options.filesToMutate, ["Sources/A.swift", "B.swift"])
            XCTAssertEqual(options.mutationOperatorsList, [.swapTernary, .removeSideEffects])
        }
        XCTAssertTrue(mutate.createTestPlan)
        let plain = try XCTUnwrap(MuterCommand.parseAsRoot(["mutate-without-running"]) as? MutateWithoutRunning)
        XCTAssertEqual(plain.runOptions.filesToMutate, [])
        XCTAssertEqual(plain.runOptions.mutationOperatorsList, .allOperators)
    }

    // Both commands list the two options first, as `run` always has.
    func test_skipOperators_reachesTheRunOptions_ofRunAndMutateWithoutRunning() throws {
        let chosen = ["--skip-operators", "SwapTernary", "RemoveSideEffects"]
        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run"] + chosen) as? Run).runOptions
        let mutate = try XCTUnwrap(
            MuterCommand.parseAsRoot(["mutate-without-running"] + chosen) as? MutateWithoutRunning
        ).runOptions

        for options in [run, mutate] {
            XCTAssertEqual(options.skipOperators, [.swapTernary, .removeSideEffects])
            XCTAssertFalse(options.operatorsAreNamed)
        }
        let plain = try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions
        XCTAssertNil(plain.skipOperators)
        XCTAssertFalse(plain.operatorsAreNamed)
        let namedArguments = ["--operators", "SwapTernary", "SwapTernary"]
        let namedRun = try XCTUnwrap(MuterCommand.parseAsRoot(["run"] + namedArguments) as? Run).runOptions
        let namedMutate = try XCTUnwrap(
            MuterCommand.parseAsRoot(["mutate-without-running"] + namedArguments) as? MutateWithoutRunning
        ).runOptions
        for options in [namedRun, namedMutate] {
            XCTAssertTrue(options.operatorsAreNamed)
            XCTAssertEqual(options.mutationOperatorsList, [.swapTernary], "named twice, used once")
        }
    }

    func test_anUnknownOperator_isRefused_byBothOptions_ofBothCommands() {
        for command in ["run", "mutate-without-running"] {
            for (option, value) in [("--operators", "operators"), ("--skip-operators", "skip-operators")] {
                assertUsageError(
                    [command, option, "SwapTernery"],
                    "The value 'SwapTernery' is invalid for '\(option) <\(value)>': \(MutationOperator.Id.description)"
                )
            }
        }
    }

    func test_mutant_refusesSkipOperators() {
        assertUsageError(
            ["run", "--mutant", "Bar.swift:12:9", "--skip-operators", "SwapTernary"],
            "--mutant can't be given with --skip-operators."
        )
    }

    func test_operatorsAndFilesToMutate_comeFirstInTheHelp_ofRunAndMutateWithoutRunning() {
        for help in [Run.helpMessage(columns: 400), MutateWithoutRunning.helpMessage(columns: 400)] {
            let options = help.components(separatedBy: "OPTIONS:\n").last ?? ""
            XCTAssertTrue(options.hasPrefix("  --files-to-mutate <path>"), help)
            XCTAssertTrue(options.contains("\n  --operators <operators> "), help)
            XCTAssertTrue(help.contains(MutationOperator.Id.description), help)
        }
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
            reasons: [.inUse(holder: nil, lastProcess: 81234, lastHost: "studio.local")],
            beforeTheCopy: true
        )

        XCTAssertEqual(Run.message(showing: refused), "\(refused)")
        let inUse = MutatedProjectLockError.inUse(mutatedProject: "/code/x_mutated", process: 81234)
        XCTAssertEqual(Run.message(showing: inUse), "\(inUse)")
        let plan = TestPlanRefused(path: "/code/x/muter-mappings.json", reason: .copyMissing(path: "/code/x_mutated"))
        XCTAssertEqual(Run.message(showing: plan), "\(plan)")
        let mutant = MutantRefused(
            reference: MutantReference(path: "Bar.swift", line: 12),
            reason: .notFound(nearby: [], files: 0)
        )
        XCTAssertEqual(Run.message(showing: mutant), "\(mutant)")
        let cannotLock = Run.message(showing: MutatedProjectLockError.cannotLock(path: "/x.lock", errno: EACCES))
        XCTAssertTrue(cannotLock.contains("SwiftMutator has encountered an error"), cannotLock)
        let other = Run.message(showing: MuterError.noSourceFilesDiscovered)
        XCTAssertTrue(other.contains("SwiftMutator has encountered an error"), other)
        XCTAssertTrue(other.contains("\(MuterError.noSourceFilesDiscovered)"), other)
        XCTAssertTrue(other.contains("please open an issue"), other)
        XCTAssertTrue(other.contains("open an issue at\nhttps://github.com/Joseph-Cursio/SwiftMutator/issues"), other)
        XCTAssertFalse(other.contains("muter-mutation-testing"), other)
    }

    // A script can tell a refused resume or reuse, and a run another holds a lock against, from an error, and from
    // each other: after the first, a new run starts, and after the second, waiting for the other run lets it through.
    // A low score, a failed baseline and an abort each have one too.
    func test_eachOutcome_exitsWithItsOwnStatus() {
        XCTAssertEqual(ExitCode.scoreBelowThreshold.rawValue, 2)
        XCTAssertEqual(ExitCode.baselineFailed.rawValue, 3)
        XCTAssertEqual(ExitCode.abortedMidRun.rawValue, 4)
        XCTAssertEqual(ExitCode.resumeRefused.rawValue, 5)
        XCTAssertEqual(ExitCode.anotherRunHoldsTheLock.rawValue, 6)
        XCTAssertEqual(ExitCode.testPlanRefused.rawValue, 7)
        XCTAssertEqual(ExitCode.stoppedOnAnError.rawValue, -1)
        let difference = ResumeCheck.Difference(name: "mutationTestTimeout", was: "120", isNow: "60")
        let changes = [ProjectTree.FileChange(path: "notes.txt", kind: .added)]
        let refusals = [
            ResumeRefused(
                path: "/logs/results.jsonl",
                reasons: [.configurationChanged(difference), .filesChanged(changes)],
                beforeTheCopy: true
            ),
            ResumeRefused(
                path: "/logs/results.jsonl",
                reasons: [.configurationChanged(difference)],
                beforeTheCopy: true,
                isReuse: true
            ),
            ResumeRefused(path: "/logs/results.jsonl", reasons: [.filesChanged(changes)], beforeTheCopy: false),
            ResumeRefused(
                path: "/logs/results.jsonl",
                reasons: [.reportWouldReplaceTheResultsFile("/logs/results.jsonl")],
                beforeTheCopy: true
            ),
            // Held, but refused for another reason too: it won't resume once the lock is free either.
            ResumeRefused(
                path: "/logs/results.jsonl",
                reasons: [.inUse(holder: nil, lastProcess: 81234, lastHost: "studio.local"), .filesChanged(changes)],
                beforeTheCopy: true
            ),
        ]
        for refused in refusals {
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: refused), .resumeRefused, "\(refused)")
        }
        let lockedFile = ResumeRefused(
            path: "/logs/results.jsonl",
            reasons: [.inUse(holder: nil, lastProcess: 81234, lastHost: "studio.local")],
            beforeTheCopy: true
        )
        XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: lockedFile), .anotherRunHoldsTheLock)
        let lockedCopy = MutatedProjectLockError.inUse(mutatedProject: "/code/x_mutated", process: 81234)
        XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: lockedCopy), .anotherRunHoldsTheLock)
        let plans = [
            TestPlanRefused(path: "/code/x/muter-mappings.json", reason: .newerFormat(found: 3)),
            TestPlanRefused(path: "/code/x/muter-mappings.json", reason: .copyMissing(path: "/code/x_mutated")),
        ]
        for refused in plans {
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: refused), .testPlanRefused, "\(refused)")
        }
        let errors: [Error] = [
            MutatedProjectLockError.cannotLock(path: "/x.lock", errno: EACCES),
            ResultsFileError.newerFormat(path: "/logs/results.jsonl", version: 3),
            ChangeSelectionError.unknownRef("origin/main"),
            MuterError.noSourceFilesDiscovered,
            MuterError.configurationParsingError(reason: "failUnder must be a number from 0 to 100, not 101"),
        ]
        for error in errors {
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: error), .stoppedOnAnError, "\(error)")
        }
        let nothing = NothingToMutate(reason: .noSwiftFileChanged, selection: .make())
        XCTAssertNil(ExitCode.exitStatus(afterRunFailedWith: nothing))
        let empty = EmptyShard(shard: Shard(index: 3, count: 4), mutantsInAllShards: 2)
        XCTAssertNil(ExitCode.exitStatus(afterRunFailedWith: empty))
        for (reason, status) in Self.everyAbortReason {
            XCTAssertEqual(
                ExitCode.exitStatus(afterRunFailedWith: MuterError.mutationTestingAborted(reason: reason)),
                status,
                "\(reason)"
            )
        }
    }

    /// One of each abort reason, with the status a run it stopped exits with: 3 when no mutant was tested because a
    /// baseline failed, 4 for the rest. Built from every kind of reason, so a new kind is in it or the tests don't
    /// compile.
    static var everyAbortReason: [(MutationTestingAbortReason, ExitCode)] {
        MutationTestingAbortReason.Kind.allCases.map { kind in
            let reason = sampleAbortReason(of: kind)
            let status: ExitCode = switch kind {
            case .baselineTestFailed, .workerBaselineTestFailed: .baselineFailed
            case .tooManyBuildErrors, .mutantNotSwitchedOn, .controlRunNotSwitchedOff, .simulatorUnavailable,
                 .noMutantCodeShownRunning, .unknownError: .abortedMidRun
            }
            return (reason, status)
        }
    }

    /// An abort reason of `kind`. No `default`, so a new kind needs one.
    static func sampleAbortReason(of kind: MutationTestingAbortReason.Kind) -> MutationTestingAbortReason {
        switch kind {
        case .baselineTestFailed: .baselineTestFailed(log: "", mutatedFilePaths: [])
        case .workerBaselineTestFailed: .workerBaselineTestFailed(worker: 2, directory: "/x_worker2", log: "")
        case .tooManyBuildErrors: .tooManyBuildErrors
        case .noMutantCodeShownRunning: .noMutantCodeShownRunning(runs: 5)
        case .mutantNotSwitchedOn: .mutantNotSwitchedOn(id: "Foo_1", description: "no space left")
        case .controlRunNotSwitchedOff: .controlRunNotSwitchedOff(number: 1, description: "no space left")
        case .simulatorUnavailable: .simulatorUnavailable(worker: 1, line: "device not found", log: nil)
        case .unknownError: .unknownError(description: "?")
        }
    }

    // Each sample abort reason is of the kind it stands for, so every kind, and so every case, has a sample.
    func test_everyAbortReason_hasOneOfEachKind() {
        let kinds = Self.everyAbortReason.map(\.0.kind)
        XCTAssertEqual(kinds, MutationTestingAbortReason.Kind.allCases)
    }

    // The verdict decides the status of a run that ended without failing or a signal; a failure's status wins.
    func test_aRunsVerdictOnItsScore_decidesItsStatus() {
        let below = ScoreGate(failUnder: 80, judging: .make([.failed, .passed]))
        let meets = ScoreGate(failUnder: 50, judging: .make([.failed, .passed]))
        let oneMutant = ScoreGate(failUnder: 80, judging: .make([.passed], mutant: "Foo.swift:3:9"))
        let ended = { (gate: ScoreGate?) in Interruptions.Ended<ScoreGate?>(result: .success(gate), signal: nil) }

        XCTAssertEqual(ended(below).exitStatus, .scoreBelowThreshold)
        XCTAssertNil(ended(meets).exitStatus)
        XCTAssertNil(ended(oneMutant).exitStatus)
        XCTAssertNil(ended(nil).exitStatus)
        let aborted = Interruptions.Ended<ScoreGate?>(
            result: .failure(MuterError.mutationTestingAborted(reason: .tooManyBuildErrors)),
            signal: nil
        )
        XCTAssertEqual(aborted.exitStatus, .abortedMidRun)
        let nothing = Interruptions.Ended<ScoreGate?>(
            result: .failure(NothingToMutate(reason: .noSwiftFileChanged, selection: .make())),
            signal: nil
        )
        XCTAssertNil(nothing.exitStatus)
    }

    // On each command that tests mutants, in place of failUnder, and on `report`; never `mutate-without-running`,
    // which tests nothing.
    func test_failUnder_reachesTheRunOptions_ofEachCommandThatTests_andTheHelp() throws {
        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--fail-under", "80"]) as? Run)
        XCTAssertEqual(run.runOptions.failUnder, 80)
        let plan = try MuterCommand.parseAsRoot(["run-without-mutating", "--fail-under", "72.5", "plan.json"])
        XCTAssertEqual(try XCTUnwrap(plan as? RunWithoutMutating).runOptions.failUnder, 72.5)
        XCTAssertNil(try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions.failUnder)
        let report = try XCTUnwrap(MuterCommand.parseAsRoot(["report", "r.jsonl", "--fail-under", "0"]) as? Report)
        XCTAssertEqual(report.reportOptions.failUnder, 0)
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["mutate-without-running", "--fail-under", "80"]))
        for help in [Run.helpMessage(columns: 200), RunWithoutMutating.helpMessage(columns: 200)]
            + [Report.helpMessage(columns: 200)] {
            XCTAssertTrue(help.contains("\n  --fail-under <percent>"), help)
        }
        XCTAssertFalse(MutateWithoutRunning.helpMessage(columns: 200).contains("--fail-under"))
    }

    func test_aFailUnderThatIsntAPercent_isAUsageError() {
        let refused = ["-1", "100.1", "101", "nan", "inf", "eighty", "1e2", "0x50", "+80", "80.", ".5", "8 0"]
            + ["8_0", "1:20", "0.0000001", "33.3333333"]
        for value in refused {
            for command in [["run"], ["report", "r.jsonl"]] {
                assertUsageError(
                    command + ["--fail-under=\(value)"],
                    "The value '\(value)' is invalid for '--fail-under <percent>': give a percent from 0 to 100, with "
                        + "at most 6 decimals, such as 80 or 72.5."
                )
            }
        }
        for value in ["0", "100", "72.5", "0.05", "080", "0.000001", "33.333333"] {
            XCTAssertNoThrow(try MuterCommand.parseAsRoot(["run", "--fail-under", value]), value)
        }
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
