#if !os(Linux)
@testable import muterCore
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

        do { _ = try await sut.run(with: state) }
        catch {}

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
        process.stdoutToBeReturned = xcodebuildBuildForTestingOutput()
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
        process.stdoutToBeReturned = xcodebuildBuildForTestingOutput()
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
        process.stdoutToBeReturned = xcodebuildBuildForTestingOutput()
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
        process.stdoutToBeReturned = xcodebuildBuildForTestingFailedOutput()
        process.terminationStatus = 65

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .literal(
                reason: """
                xcodebuild build-for-testing failed with exit code 65:
                /path/to/temp/iOSProject.xcodeproj: error: The iOS Simulator deployment target 'IPHONEOS_DEPLOYMENT_TARGET' is set to 12.0, but the range of supported deployment target versions is 15.0 to 27.0.x. (in target 'iOSProjectTests' from project 'iOSProject')
                """
            )
        )
        XCTAssertFalse(fileManager.methodCalls.contains("copyItem(atPath:toPath:)"))
    }

    func test_buildForTestingFailsWithoutErrorLines_thenReportTailOfOutput() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["some", "commands", "test"]
        )

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        process.stdoutToBeReturned = "Prepare packages\n\n** TEST BUILD FAILED **\n"
        process.terminationStatus = 1

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .literal(
                reason: """
                xcodebuild build-for-testing failed with exit code 1:
                Prepare packages
                ** TEST BUILD FAILED **
                """
            )
        )
    }

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
