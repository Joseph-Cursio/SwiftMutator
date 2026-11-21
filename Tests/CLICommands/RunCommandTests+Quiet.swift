@testable import muterCore
import XCTest

extension RunCommandTests {
    // Each command that runs mutation testing takes it, as it takes --verbose.
    func test_quiet_reachesTheRunOptions_ofEachRunCommand_andTheHelp() throws {
        XCTAssertTrue(try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--quiet"]) as? Run).runOptions.quiet)
        XCTAssertFalse(try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions.quiet)
        let mutate = try MuterCommand.parseAsRoot(["mutate-without-running", "--quiet"])
        XCTAssertTrue(try XCTUnwrap(mutate as? MutateWithoutRunning).runOptions.quiet)
        let runPlan = try MuterCommand.parseAsRoot(["run-without-mutating", "--quiet", "plan.json"])
        XCTAssertTrue(try XCTUnwrap(runPlan as? RunWithoutMutating).runOptions.quiet)
        let help = Run.helpMessage(columns: 200)
        XCTAssertTrue(help.contains("\n  --quiet "), help)
        XCTAssertTrue(
            help.contains("Prints only warnings, errors and the run's summary: no banner, progress or notices."),
            help
        )
    }

    func test_quietWithVerbose_isAUsageError() {
        let message = "--quiet and --verbose can't be given together."
        assertUsageError(["run", "--quiet", "--verbose"], message)
        assertUsageError(["mutate-without-running", "--verbose", "--quiet"], message)
        assertUsageError(["run-without-mutating", "--quiet", "--verbose", "plan.json"], message)
    }

    func test_runOptionsEquality_coversQuiet() {
        XCTAssertNotEqual(Run.Options.make(quiet: true), .make())
        XCTAssertEqual(Run.Options.make(quiet: true), .make(quiet: true))
        XCTAssertFalse(Run.Options.null.quiet)
    }
}
