#if !os(Linux)
@testable import muterCore
import TestingExtensions
import XCTest

final class BuildForTestingTests: MuterTestCase {
    let state = MutationTestState()

    var buildDescriptionPath: String {
        fixturesDirectory + "/BuildForTesting"
    }

    let sut = BuildForTesting()

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
                /path/to/temp/iOSProject.xcodeproj: error: The iOS Simulator deployment target \
                'IPHONEOS_DEPLOYMENT_TARGET' is set to 12.0, but the range of supported deployment target versions \
                is 15.0 to 27.0.x. (in target 'iOSProjectTests' from project 'iOSProject')
                """,
                log: nil
            ))
        )
        XCTAssertEqual(
            MutationTestingAbortReason.buildForTestingFailed(description: "", log: nil).exitStatus, .baselineFailed
        )
        XCTAssertFalse(fileManager.methodCalls.contains("copyItem(atPath:toPath:)"))
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

    /// Makes `builds`, in order, what each build for testing ends as, and `help` what the test command's `-help` gives,
    /// nil as for one that can't be started.
    func scriptBuilds(_ builds: [CommandResult], help: CommandResult? = nil) {
        let queue = Queue<CommandResult>()
        builds.forEach(queue.enqueue)
        process.commandResult = { command in
            command.contains("-help") ? help : queue.dequeue()
        }
    }

    /// A build that printed `output` and exited with `status`.
    func built(_ output: String? = nil, status: Int32 = 0) -> CommandResult {
        CommandResult(
            status: status, endedBySignal: false, output: output ?? xcodebuildBuildForTestingOutput(), errors: ""
        )
    }

    /// Each build for testing run, its executable first, in order.
    var buildsRun: [[String]] {
        process.commandsRun.filter { !$0.contains("-help") }
    }

    /// Lines of Xcode 27.2's `xcodebuild -help`, which it writes to standard error.
    let xcodebuildHelpOutput = """
    Usage: xcodebuild [-project <projectname>] [[-target <targetname>]...|-alltargets] [<buildaction>]...

    Options:
        -test-iterations <number>                                If specified, tests will run <number> times
        -collect-test-diagnostics on-failure|never               Whether or not testing collects verbose diagnostics \
    (like a sysdiagnose) when encountering a failure
        -testLanguage                                            constrains testing by specifying ISO 639-1 language \
    in which to run the tests
    """

    func xcodebuildBuildForTestingFailedOutput() -> String {
        """
        Command line invocation:
            /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project iOSProject.xcodeproj -scheme \
        iOSProject build-for-testing

        /path/to/temp/iOSProject.xcodeproj: error: The iOS Simulator deployment target 'IPHONEOS_DEPLOYMENT_TARGET' \
        is set to 12.0, but the range of supported deployment target versions is 15.0 to 27.0.x. (in target \
        'iOSProjectTests' from project 'iOSProject')

        ** TEST BUILD FAILED **
        """
    }

    func xcodebuildBuildForTestingOutput() -> String {
        """
        Command line invocation:
            /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project iOSProject.xcodeproj -scheme \
        iOSProject -destination "platform=iOS Simulator,name=iPhone SE (3rd generation)" build-for-testing

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

    func loadXCTestRun() -> Data {
        FileManager.default.contents(atPath: buildDescriptionPath + "/project.xctestrun") ?? .init()
    }
}
#endif
