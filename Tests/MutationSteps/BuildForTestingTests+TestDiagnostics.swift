#if !os(Linux)
@testable import muterCore
import TestingExtensions
import XCTest

extension BuildForTestingTests {
    // Asked once, after the build, of the test command itself: a wrapper `executable` may not pass the option on.
    func test_whenTheBuildSucceeds_thenAsksTheTestCommandWhetherItTakesNoTestDiagnostics() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["some", "commands", "test"]
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        scriptBuilds([built()], help: CommandResult(status: 0, endedBySignal: false, output: "", errors: helpOutput))
        fileManager.contentsAtPathSortedToReturn = ["some/project.xctestrun"]
        fileManager.fileContentsToReturn = loadXCTestRun()

        let result = try await sut.run(with: state)

        XCTAssertEqual(result.last, .testDiagnosticsOptionChecked(canBeTurnedOff: true))
        XCTAssertEqual(process.commandsRun.last, ["/path/to/xcodebuild", "-help"])
        XCTAssertEqual(process.commandsRun.count, 2, "\(process.commandsRun)")
        // The build has no limit without a buildTimeout.
        XCTAssertEqual(process.timeLimits, [nil, BuildForTesting.helpTimeLimit])
    }

    // Without an answer, the option is left out: one the test command didn't know would fail every mutant's run.
    func test_whenTheTestCommandsHelpCannotBeRead_thenTestDiagnosticsAreLeftOn() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["some", "commands", "test"]
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        scriptBuilds([built()])
        fileManager.contentsAtPathSortedToReturn = ["some/project.xctestrun"]
        fileManager.fileContentsToReturn = loadXCTestRun()

        let couldNotStart = try await sut.run(with: state)
        fileManager.fileContentsToReturn = loadXCTestRun()
        scriptBuilds(
            [built()],
            help: CommandResult(status: 0, endedBySignal: false, output: "", errors: helpOutput, timedOut: true)
        )
        let timedOut = try await sut.run(with: state)

        XCTAssertEqual(couldNotStart.last, .testDiagnosticsOptionChecked(canBeTurnedOff: false))
        XCTAssertEqual(timedOut.last, .testDiagnosticsOptionChecked(canBeTurnedOff: false))
    }

    func test_whenTheBuildFails_thenTheTestCommandsHelpIsNotAsked() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["some", "commands", "test"]
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        scriptBuilds([built(xcodebuildBuildForTestingFailedOutput(), status: 65)])

        _ = try? await sut.run(with: state)

        XCTAssertEqual(process.commandsRun.count, 1, "\(process.commandsRun)")
        XCTAssertFalse(process.commandsRun.contains(["/path/to/xcodebuild", "-help"]))
    }

    func test_listsNoTestDiagnostics_onlyForXcodebuildsLineWithNever() {
        XCTAssertTrue(BuildForTesting.listsNoTestDiagnostics(xcodebuildHelpOutput))
        XCTAssertTrue(BuildForTesting.listsNoTestDiagnostics("-collect-test-diagnostics never|on-failure"))

        // An Xcode before the option, a wrapper's own usage, and lines that merely mention it.
        XCTAssertFalse(BuildForTesting.listsNoTestDiagnostics(""))
        let olderHelp = xcodebuildHelpOutput.replacingOccurrences(
            of: "-collect-test-diagnostics",
            with: "-test-repetition-relaunch"
        )
        XCTAssertFalse(BuildForTesting.listsNoTestDiagnostics(olderHelp))
        XCTAssertFalse(BuildForTesting.listsNoTestDiagnostics("usage: run-tests.sh [scheme]"))
        XCTAssertFalse(BuildForTesting.listsNoTestDiagnostics("-collect-test-diagnostics on-failure"))
        XCTAssertFalse(BuildForTesting.listsNoTestDiagnostics("-collect-test-diagnostics"))
        XCTAssertFalse(BuildForTesting.listsNoTestDiagnostics("unknown option -collect-test-diagnostics never"))
    }

    var helpOutput: String {
        xcodebuildHelpOutput
    }
}
#endif
