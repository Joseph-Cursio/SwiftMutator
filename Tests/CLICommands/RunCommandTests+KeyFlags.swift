import ArgumentParser
@testable import muterCore
import XCTest

/// A flag, a value for it, what the run options then hold, and the commands that take it.
private struct FlagCase {
    let arguments: [String]
    let flags: KeyFlags
    let commands: [String]

    init(_ arguments: [String], _ flags: KeyFlags, _ commands: [String]) {
        self.arguments = arguments
        self.flags = flags
        self.commands = commands
    }
}

/// #262: a flag for each configuration key but `executable` and `arguments`, on each command whose run reads the key.
extension RunCommandTests {
    private static let run = "run"
    private static let making = "mutate-without-running"
    private static let testing = "run-without-mutating"
    /// The commands that discover mutants, whose discovery reads the key: `--exclude`'s.
    private static let discovering = [run, making]
    /// The commands that test mutants: `--workers`'.
    private static let testingMutants = [run, testing]
    /// The commands that make the copy of the project, which run-without-mutating builds as a plan left it.
    private static let copying = [run, making]
    /// The commands that build: `--build-timeout`'s.
    private static let building = [run, making, testing]

    /// Each flag, a value for it, what the run options then hold, and the commands that take it.
    private static let keyFlagCases: [FlagCase] = [
        FlagCase(
            ["--exclude-calls", "log", "--exclude-calls", "trace"],
            KeyFlags(excludeCalls: ["log", "trace"]),
            discovering
        ),
        FlagCase(["--coverage-threshold", "12.5"], KeyFlags(coverageThreshold: 12.5), discovering),
        FlagCase(["--keep-swiftlint-phases"], KeyFlags(keepSwiftLintPhases: .enabled), copying),
        FlagCase(["--no-keep-swiftlint-phases"], KeyFlags(keepSwiftLintPhases: .disabled), copying),
        FlagCase(["--build-system", "xcodebuild"], KeyFlags(buildSystem: .xcodebuild), building),
        FlagCase(["--build-system", "swift"], KeyFlags(buildSystem: .swift), building),
        FlagCase(["--keep-log-folders", "2"], KeyFlags(keepLogFolders: 2), building),
        FlagCase(["--stop-at-first-failure"], KeyFlags(stopAtFirstFailure: .enabled), testingMutants),
        FlagCase(["--no-stop-at-first-failure"], KeyFlags(stopAtFirstFailure: .disabled), testingMutants),
        FlagCase(["--workers-share-build"], KeyFlags(workersShareBuild: .enabled), testingMutants),
        FlagCase(["--no-workers-share-build"], KeyFlags(workersShareBuild: .disabled), testingMutants),
        FlagCase(["--one-worker-simulator"], KeyFlags(oneWorkerSimulator: .enabled), testingMutants),
        FlagCase(["--no-one-worker-simulator"], KeyFlags(oneWorkerSimulator: .disabled), testingMutants),
        FlagCase(["--keep-all-logs"], KeyFlags(keepAllLogs: .enabled), testingMutants),
        FlagCase(["--no-keep-all-logs"], KeyFlags(keepAllLogs: .disabled), testingMutants),
        FlagCase(["--suspect-test-file-percent", "100"], KeyFlags(suspectTestFilePercent: 100), testingMutants),
        FlagCase(["--suspect-test-minimum-files", "1"], KeyFlags(suspectTestMinimumFiles: 1), testingMutants),
        FlagCase(["--control-run-every", "0"], KeyFlags(controlRunEvery: 0), testingMutants),
        FlagCase(["--suspect-kill-reruns", "7"], KeyFlags(suspectKillReruns: 7), testingMutants),
        FlagCase(
            ["--property-test-filter", "LawTests", "--property-test-filter", "Spec"],
            KeyFlags(propertyTestFilter: ["LawTests", "Spec"]),
            testingMutants
        ),
        FlagCase(["--property-survivor-reruns", "3"], KeyFlags(propertySurvivorReruns: 3), testingMutants),
        FlagCase(
            ["--property-survivor-rerun-limit", "0"], KeyFlags(propertySurvivorRerunLimit: 0), testingMutants
        ),
    ]

    // Each command that takes a flag puts it in its run options and its help; another refuses it, and its help
    // doesn't list it.
    func test_eachKeyFlag_reachesTheRunOptions_ofEachCommandThatTakesIt_andNoOther() throws {
        for flagCase in Self.keyFlagCases {
            let (arguments, flags, commands) = (flagCase.arguments, flagCase.flags, flagCase.commands)
            for command in Self.building {
                let line = [command] + arguments + (command == Self.testing ? ["plan.json"] : [])
                let help = helpMessage(of: command)
                // The help gives a pair as one, `--keep-all-logs/--no-keep-all-logs`.
                let isListed = help.contains("\n  \(arguments[0])") || help.contains("/\(arguments[0])")
                guard commands.contains(command) else {
                    XCTAssertThrowsError(try MuterCommand.parseAsRoot(line), "\(line)") { error in
                        XCTAssertEqual(MuterCommand.exitCode(for: error), .validationFailure, "\(line)")
                        XCTAssertTrue(MuterCommand.message(for: error).hasPrefix("Unknown option"), "\(line)")
                    }
                    XCTAssertFalse(isListed, "\(line)")
                    continue
                }
                XCTAssertEqual(try runOptions(of: line).keyFlags, flags, "\(line)")
                XCTAssertTrue(isListed, "\(line)")
            }
        }
    }

    // Neither of a pair given leaves the key, as does any flag left out.
    func test_withoutAKeyFlag_theRunOptionsHoldNone() throws {
        for line in [[Self.run], [Self.making], [Self.testing, "plan.json"]] {
            XCTAssertEqual(try runOptions(of: line).keyFlags, KeyFlags(), "\(line)")
        }
    }

    // Every flag at once, from each group, on run.
    func test_everyKeyFlag_reachesRunsOptions_together() throws {
        let line = [
            Self.run, "--exclude-calls", "log", "--exclude-calls", "trace", "--coverage-threshold", "12.5",
            "--keep-swiftlint-phases", "--build-system", "swift", "--keep-log-folders", "2", "--stop-at-first-failure",
            "--workers-share-build", "--one-worker-simulator", "--keep-all-logs", "--suspect-test-file-percent", "100",
            "--suspect-test-minimum-files", "1", "--control-run-every", "0", "--suspect-kill-reruns", "7",
            "--property-test-filter", "LawTests", "--property-test-filter", "Spec", "--property-survivor-reruns", "3",
            "--property-survivor-rerun-limit", "0",
        ]

        let flags = try runOptions(of: line).keyFlags

        XCTAssertEqual(flags, KeyFlags(
            excludeCalls: ["log", "trace"], coverageThreshold: 12.5, buildSystem: .swift, stopAtFirstFailure: .enabled,
            workersShareBuild: .enabled, oneWorkerSimulator: .enabled, suspectTestFilePercent: 100,
            suspectTestMinimumFiles: 1, controlRunEvery: 0, suspectKillReruns: 7, keepAllLogs: .enabled,
            keepLogFolders: 2, keepSwiftLintPhases: .enabled, propertyTestFilter: ["LawTests", "Spec"],
            propertySurvivorReruns: 3, propertySurvivorRerunLimit: 0
        ))
    }

    // As their keys are refused, with the key's range, as the run is about to start.
    func test_aKeyFlagOutOfItsKeysRange_isAUsageError() {
        let refused: [(arguments: [String], message: String)] = [
            (["--coverage-threshold", "100.5"], "--coverage-threshold must be a percentage from 0 to 100, not 100.5."),
            (["--coverage-threshold=-1"], "--coverage-threshold must be a percentage from 0 to 100, not -1."),
            (["--coverage-threshold", "nan"], "--coverage-threshold must be a percentage from 0 to 100, not nan."),
            (["--keep-log-folders", "1"], "--keep-log-folders must be a whole number at least 2, not 1."),
            (
                ["--suspect-test-file-percent", "0"],
                "--suspect-test-file-percent must be a whole number from 1 to 100, not 0."
            ),
            (
                ["--suspect-test-file-percent", "101"],
                "--suspect-test-file-percent must be a whole number from 1 to 100, not 101."
            ),
            (
                ["--suspect-test-minimum-files", "0"],
                "--suspect-test-minimum-files must be a whole number at least 1, not 0."
            ),
            (["--control-run-every=-1"], "--control-run-every must be a whole number at least 0, not -1."),
            (["--suspect-kill-reruns=-1"], "--suspect-kill-reruns must be a whole number at least 0, not -1."),
            (
                ["--property-survivor-reruns=-2"],
                "--property-survivor-reruns must be a whole number at least 0, not -2."
            ),
            (
                ["--property-survivor-rerun-limit=-3"],
                "--property-survivor-rerun-limit must be a whole number at least 0, not -3."
            ),
            (
                ["--property-test-filter", ""],
                "--property-test-filter: a glob can't be empty, as it would match no test."
            ),
        ]
        for (arguments, message) in refused {
            assertUsageError([Self.run] + arguments, message)
        }
        assertUsageError(
            [Self.making, "--keep-log-folders", "0"], "--keep-log-folders must be a whole number at least 2, not 0."
        )
        assertUsageError(
            [Self.testing, "--control-run-every=-1", "plan.json"],
            "--control-run-every must be a whole number at least 0, not -1."
        )
    }

    // A value its key can't hold either: ArgumentParser's own refusal, or the build system's.
    func test_aMalformedKeyFlag_isAUsageError() {
        let malformed: [(arguments: [String], message: String)] = [
            (
                ["--build-system", "make"],
                "The value 'make' is invalid for '--build-system <swift|xcodebuild>': give swift or xcodebuild."
            ),
            (
                ["--build-system", "unknown"],
                "The value 'unknown' is invalid for '--build-system <swift|xcodebuild>': give swift or xcodebuild."
            ),
            (["--control-run-every", "1.5"], "The value '1.5' is invalid for '--control-run-every <count>'"),
            (["--coverage-threshold", "half"], "The value 'half' is invalid for '--coverage-threshold <percent>'"),
        ]
        for (arguments, message) in malformed {
            assertUsageError([Self.run] + arguments, message)
        }
    }

    // Both of a pair: the last one given wins, as ArgumentParser has it, so a script's flags can be overridden by
    // one added after them.
    func test_bothFlagsOfAPair_theLastWins() throws {
        let turnedOff = try runOptions(of: [Self.run, "--keep-all-logs", "--no-keep-all-logs"]).keyFlags
        XCTAssertEqual(turnedOff, KeyFlags(keepAllLogs: .disabled))
        let turnedOn = try runOptions(of: [Self.run, "--no-keep-all-logs", "--keep-all-logs"]).keyFlags
        XCTAssertEqual(turnedOn, KeyFlags(keepAllLogs: .enabled))
    }

    func test_runOptionsEquality_coversEveryKeyFlag() {
        for flags in Self.keyFlagCases.map(\.flags) {
            XCTAssertNotEqual(Run.Options.make(keyFlags: flags), .make(), "\(flags)")
            XCTAssertEqual(Run.Options.make(keyFlags: flags), .make(keyFlags: flags), "\(flags)")
        }
        XCTAssertEqual(Run.Options.null.keyFlags, KeyFlags())
    }

    private func runOptions(of line: [String]) throws -> Run.Options {
        let command = try MuterCommand.parseAsRoot(line)
        switch command {
        case let run as Run:
            return run.runOptions

        case let making as MutateWithoutRunning:
            return making.runOptions

        case let testing as RunWithoutMutating:
            return testing.runOptions

        default:
            throw MuterError.literal(reason: "\(line) isn't a run command")
        }
    }

    private func helpMessage(of command: String) -> String {
        switch command {
        case Self.run:
            Run.helpMessage(columns: 200)

        case Self.making:
            MutateWithoutRunning.helpMessage(columns: 200)

        default:
            RunWithoutMutating.helpMessage(columns: 200)
        }
    }
}
