import ArgumentParser
@testable import muterCore
import XCTest

extension RunCommandTests {
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
}
