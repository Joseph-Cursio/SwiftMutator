#if !os(Linux)
@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

final class BuildForTestingTests: MuterTestCase {
    private let state = MutationTestState()

    var buildDescriptionPath: String {
        fixturesDirectory + "/BuildForTesting"
    }

    private let sut = BuildForTesting()

    func test_whenBuildSystemIsSwift_thenIgnoreStep() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/swift"
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [])
    }

    // MARK: xcodebuild

    func test_changeCurrentPathToTempDirectory() async throws {
        fileManager.currentDirectoryPathToReturn = "/path/to/project"

        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild"
        )

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")

        _ = try? await sut.run(with: state)

        XCTAssertTrue(fileManager.methodCalls.contains("changeCurrentDirectoryPath(_:)"))
        XCTAssertEqual(
            fileManager.changeCurrentDirectoryPath.first,
            state.mutatedProjectDirectoryURL.path
        )
    }

    func test_resetCurrentPath() {
        fileManager.currentDirectoryPathToReturn = "/path/to/project"

        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild"
        )

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")

        XCTAssertEqual(fileManager.methodCalls, [])
        XCTAssertEqual(
            fileManager.currentDirectoryPath,
            "/path/to/project"
        )
    }

    func test_copyBuildArtifactsFailed() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["some", "commands", "test"]
        )

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        scriptBuilds([built()])
        fileManager.errorToThrow = TestingError.stub

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .literal(reason: "stub")
        )
    }

    func test_findMostRecentXCTestRunFails() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["some", "commands", "test"]
        )

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        scriptBuilds([built()])
        fileManager.contentsAtPathSortedToReturn = [""]

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .literal(reason: "Could not find xctestrun file at path: /path/to/temp/TestContents")
        )
    }

    func test_parseXCTestRunFails() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["some", "commands", "test"]
        )

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        scriptBuilds([built()])
        fileManager.contentsAtPathSortedToReturn = ["some/project.xctestrun"]

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .literal(reason: "Could not parse xctestrun at path: some/project.xctestrun")
        )
    }

    func test_buildForTestingFails_thenReportXcodebuildErrors() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["some", "commands", "test"]
        )

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        scriptBuilds([built(xcodebuildBuildForTestingFailedOutput(), status: 65)])

        // A project that doesn't build for testing is a failed baseline, as a SwiftPM one is, whose baseline builds.
        try await assertThrowsMuterError(
            await sut.run(with: state),
            .mutationTestingAborted(reason: .buildForTestingFailed(
                description: """
                xcodebuild build-for-testing failed with exit code 65:
                /path/to/temp/iOSProject.xcodeproj: error: The iOS Simulator deployment target 'IPHONEOS_DEPLOYMENT_TARGET' is set to 12.0, but the range of supported deployment target versions is 15.0 to 27.0.x. (in target 'iOSProjectTests' from project 'iOSProject')
                """,
                log: nil
            ))
        )
        XCTAssertEqual(
            MutationTestingAbortReason.buildForTestingFailed(description: "", log: nil).exitStatus, .baselineFailed
        )
        XCTAssertFalse(fileManager.methodCalls.contains("copyItem(atPath:toPath:)"))
    }

    // A mutant that doesn't compile: the next build leaves it out, and takes no `clean`, so only its file builds again.
    func test_buildForTestingFailsOnAMutant_thenBuildAgainWithoutIt_andGiveItToTheRun() async throws {
        let path = "/path/to/temp/Sources/Check.swift"
        let prepared = "func check(_ value: Int) -> Bool {\n    return value > 1\n}\n"
        let source = SourceCodeInfo(path: path, code: Parser.parse(source: prepared))
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)
        let bad = try XCTUnwrap(mapping.mutationSchemata.first?.id)
        let rewritten = MuterRewriter(mapping).visit(source.code).description
        let lineWithIt = try XCTUnwrap(
            rewritten.components(separatedBy: "\n").firstIndex { $0.contains("\"\(bad)\"") }
        )
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["-scheme", "S", "test"]
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        state.mutationMapping = [mapping]
        state.preparedSources = [path: prepared]
        state.loggingDirectory = "/logs"
        let failed = "\(path):\(lineWithIt + 2):9: error: no such operator\n"
        scriptBuilds([built(failed, status: 65), built()])
        fileManager.contentsAtPathSortedToReturn = ["some/project.xctestrun"]
        fileManager.fileContentsToReturn = loadXCTestRun()

        let result = try await sut.run(with: state)

        let builds = buildsRun
        XCTAssertEqual(builds.count, 2, "\(builds)")
        XCTAssertTrue(builds[0].contains("clean"))
        XCTAssertFalse(builds[1].contains("clean"))
        XCTAssertTrue(builds[1].contains("build-for-testing"))
        XCTAssertFalse(writeFile.contentPassed?.contains("\"\(bad)\"") ?? true)
        XCTAssertEqual(fileManager.createdFiles["/logs/failed build 1.log"], Data(failed.utf8))
        XCTAssertTrue(
            result.contains { change in
                if case let .mutantsLeftOutOfTheBuild(mutants) = change { return Array(mutants.keys) == [bad] }
                return false
            },
            "\(result)"
        )
    }

    // The value of `-scheme` isn't the `clean` the first build adds.
    func test_rebuildArguments_takeOutOnlyTheCleanTheBuildAdds() {
        let configuration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["-scheme", "clean", "test"]
        )

        XCTAssertEqual(configuration.buildForTestingArguments.suffix(2), ["clean", "build-for-testing"])
        XCTAssertEqual(configuration.rebuildForTestingArguments.last, "build-for-testing")
        XCTAssertEqual(configuration.rebuildForTestingArguments.filter { $0 == "clean" }.count, 1)
        XCTAssertTrue(configuration.rebuildForTestingArguments.contains("-scheme"))
    }

    // The log of the build that stops the run holds what its error lines leave out.
    func test_aBuildWithNoMutantToBlame_stillKeepsItsLog() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["some", "commands", "test"]
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        state.loggingDirectory = "/logs"
        scriptBuilds([
            CommandResult(
                status: 65,
                endedBySignal: false,
                output: "ld: symbol(s) not found\n",
                errors: "note: from standard error\n"
            ),
        ])

        await assertThrowsMuterError(try await sut.run(with: state)) { error in
            guard case let .mutationTestingAborted(.buildForTestingFailed(_, log)) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(log, "/logs/failed build 1.log")
            XCTAssertTrue(error.description.contains("The build's log is in /logs/failed build 1.log"), "\(error)")
        }

        // What the build wrote to standard error too, which only the kept log has.
        XCTAssertEqual(
            fileManager.createdFiles["/logs/failed build 1.log"],
            Data("ld: symbol(s) not found\nnote: from standard error\n".utf8)
        )
    }

    func test_buildForTestingFailsWithoutErrorLines_thenReportTailOfOutput() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["some", "commands", "test"]
        )

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        scriptBuilds([built("Prepare packages\n\n** TEST BUILD FAILED **\n", status: 1)])

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .mutationTestingAborted(reason: .buildForTestingFailed(
                description: """
                xcodebuild build-for-testing failed with exit code 1:
                Prepare packages
                ** TEST BUILD FAILED **
                """,
                log: nil
            ))
        )
    }

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

    // Each build runs under buildTimeout. One stopped there stops the run, as a failed baseline does, naming the
    // step, the limit and the log, and its compile errors, cut short, take no mutant out to build again.
    func test_aBuildPastTheBuildTimeout_stopsTheRun_withoutBuildingAgain() async throws {
        let path = "/path/to/temp/Sources/Check.swift"
        let prepared = "func check(_ value: Int) -> Bool {\n    return value > 1\n}\n"
        let source = SourceCodeInfo(path: path, code: Parser.parse(source: prepared))
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild", arguments: ["-scheme", "S", "test"], buildTimeout: 900
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        state.mutationMapping = [mapping]
        state.preparedSources = [path: prepared]
        state.loggingDirectory = "/logs"
        let cutShort = "Compiling Check.swift\n\(path):3:9: error: no such operator\n"
        scriptBuilds([
            CommandResult(status: 9, endedBySignal: true, output: cutShort, errors: "", timedOut: true),
            built(),
        ])

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .mutationTestingAborted(reason: .buildTimeoutReached(
                step: .buildForTesting, seconds: 900, output: cutShort, log: "/logs/failed build 1.log"
            ))
        )
        XCTAssertEqual(buildsRun.count, 1)
        XCTAssertEqual(process.timeLimits, [900])
        XCTAssertEqual(fileManager.createdFiles["/logs/failed build 1.log"], Data(cutShort.utf8))
        XCTAssertNil(writeFile.contentPassed)
    }

    // Each build has the whole limit: the one after taking out a mutant that doesn't compile too.
    func test_aBuildAgainPastTheBuildTimeout_stopsTheRun_withItsOwnLog() async throws {
        let path = "/path/to/temp/Sources/Check.swift"
        let prepared = "func check(_ value: Int) -> Bool {\n    return value > 1\n}\n"
        let source = SourceCodeInfo(path: path, code: Parser.parse(source: prepared))
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)
        let bad = try XCTUnwrap(mapping.mutationSchemata.first?.id)
        let rewritten = MuterRewriter(mapping).visit(source.code).description
        let lineWithIt = try XCTUnwrap(
            rewritten.components(separatedBy: "\n").firstIndex { $0.contains("\"\(bad)\"") }
        )
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild", arguments: ["-scheme", "S", "test"], buildTimeout: 900
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        state.mutationMapping = [mapping]
        state.preparedSources = [path: prepared]
        state.loggingDirectory = "/logs"
        scriptBuilds([
            built("\(path):\(lineWithIt + 2):9: error: no such operator\n", status: 65),
            CommandResult(status: 9, endedBySignal: true, output: "Compiling\n", errors: "", timedOut: true),
        ])

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .mutationTestingAborted(reason: .buildTimeoutReached(
                step: .buildForTesting, seconds: 900, output: "Compiling\n", log: "/logs/failed build 2.log"
            ))
        )
        XCTAssertEqual(process.timeLimits, [900, 900])
    }

    // A build stopped before it printed anything is stopped at its limit, not a command that couldn't run.
    func test_aBuildPastTheBuildTimeout_thatPrintedNothing_isStillReportedAsStopped() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild", arguments: ["test"], buildTimeout: 30
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        scriptBuilds([CommandResult(status: 9, endedBySignal: true, output: "", errors: "", timedOut: true)])

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .mutationTestingAborted(reason: .buildTimeoutReached(
                step: .buildForTesting, seconds: 30, output: "", log: nil
            ))
        )
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

    /// Makes `builds`, in order, what each build for testing ends as, and `help` what the test command's `-help` gives,
    /// nil as for one that can't be started.
    private func scriptBuilds(_ builds: [CommandResult], help: CommandResult? = nil) {
        let queue = Queue<CommandResult>()
        builds.forEach(queue.enqueue)
        process.commandResult = { command in
            command.contains("-help") ? help : queue.dequeue()
        }
    }

    /// A build that printed `output` and exited with `status`.
    private func built(_ output: String? = nil, status: Int32 = 0) -> CommandResult {
        CommandResult(
            status: status, endedBySignal: false, output: output ?? xcodebuildBuildForTestingOutput(), errors: ""
        )
    }

    /// Each build for testing run, its executable first, in order.
    private var buildsRun: [[String]] {
        process.commandsRun.filter { !$0.contains("-help") }
    }

    private var helpOutput: String {
        xcodebuildHelpOutput
    }

    /// Lines of Xcode 27.2's `xcodebuild -help`, which it writes to standard error.
    private let xcodebuildHelpOutput = """
    Usage: xcodebuild [-project <projectname>] [[-target <targetname>]...|-alltargets] [<buildaction>]...

    Options:
        -test-iterations <number>                                If specified, tests will run <number> times
        -collect-test-diagnostics on-failure|never               Whether or not testing collects verbose diagnostics (like a sysdiagnose) when encountering a failure
        -testLanguage                                            constrains testing by specifying ISO 639-1 language in which to run the tests
    """

    private func xcodebuildBuildForTestingFailedOutput() -> String {
        """
        Command line invocation:
            /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project iOSProject.xcodeproj -scheme iOSProject build-for-testing

        /path/to/temp/iOSProject.xcodeproj: error: The iOS Simulator deployment target 'IPHONEOS_DEPLOYMENT_TARGET' is set to 12.0, but the range of supported deployment target versions is 15.0 to 27.0.x. (in target 'iOSProjectTests' from project 'iOSProject')

        ** TEST BUILD FAILED **
        """
    }

    private func xcodebuildBuildForTestingOutput() -> String {
        """
        Command line invocation:
            /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project iOSProject.xcodeproj -scheme iOSProject -destination "platform=iOS Simulator,name=iPhone SE (3rd generation)" build-for-testing

        User defaults from command line:
            IDEPackageSupportUseBuiltinSCM = YES

        Prepare packages

        Computing target dependency graph and provisioning inputs

        Create build description
        Build description signature: a57afb1c7ff29046be11d242c417308a
        Build description path: \(buildDescriptionPath)/desc.xcbuild


        ** TEST BUILD SUCCEEDED **
        """
    }

    private func loadXCTestRun() -> Data {
        FileManager.default.contents(atPath: buildDescriptionPath + "/project.xctestrun") ?? .init()
    }

    private func loadXCTestRunWithDebugFolder() -> Data {
        FileManager.default.contents(atPath: buildDescriptionPath + "/projectWithDebugPath.xctestrun") ?? .init()
    }
}

extension muterCore.XCTestRun {
    static func from(_ data: Data) -> Self {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: AnyHashable]

        return .init(plist ?? [:])
    }
}
#endif
