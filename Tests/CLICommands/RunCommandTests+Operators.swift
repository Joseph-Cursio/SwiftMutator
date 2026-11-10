import ArgumentParser
@testable import muterCore
import XCTest

extension RunCommandTests {
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
}
