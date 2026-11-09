@testable import muterCore
import XCTest

final class ConfigurationGenerationTests: MuterTestCase {
    func test_swiftPackageManagerProject() async {
        let projectDirectoryContents = [
            "/some/path/Package.swift",
            "/some/path/Package@swift-5.11.swift",
            "/some/path/main.swift",
            "/some/path/PackageIgnoreMe.swift",
        ]

        process.stdoutToBeReturned = which("swift")

        let generatedConfiguration = await MuterConfiguration(from: projectDirectoryContents)

        XCTAssertEqual(
            generatedConfiguration,
            MuterConfiguration(
                executable: "/path/to/swift",
                arguments: ["test"],
                excludeList: ["Package.swift", "Package@swift-5.11.swift"]
            )
        )
    }

    #if !os(Linux)
    func test_xcodeProject() async {
        let projectDirectoryContents = [
            "/some/path/Package.swift",
            "/some/path/main.swift",
            "\(fixturesDirectory)/XcodeProjectFiles/iOSApp.xcodeproj",
        ]

        process.stdoutToBeReturned = simCtl()
        process.stdoutToBeReturned = which("xcodebuild")

        let generatedConfiguration = await MuterConfiguration(from: projectDirectoryContents)

        let expectedConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: [
                "-project",
                "iOSApp.xcodeproj",
                "-scheme",
                "iOSApp",
                "-destination",
                "platform=iOS Simulator,name=iPhone SE (3rd generation)",
                "test",
            ]
        )

        XCTAssertEqual(generatedConfiguration.testCommandExecutable, expectedConfiguration.testCommandExecutable)
        XCTAssertEqual(
            generatedConfiguration.testCommandArguments.filter { !$0.contains("platform") },
            expectedConfiguration.testCommandArguments.filter { !$0.contains("platform") }
        )
        XCTAssertNotNil(
            generatedConfiguration.testCommandArguments
                .first { $0.contains("platform=iOS Simulator,name=iPhone") }
        )
        // The first generator that knows the project makes its configuration, so the package's, after it, doesn't
        // run its `which swift`.
        XCTAssertFalse(process.processesRun.contains(["/usr/bin/which", "swift"]), "\(process.processesRun)")
    }

    func test_iosProject() async {
        let projectDirectoryContents = [
            "\(fixturesDirectory)/XcodeProjectFiles/iOSApp.xcodeproj",
            "/some/path/AppDelegate.swift",
        ]

        process.stdoutToBeReturned = simCtl()
        process.stdoutToBeReturned = which("xcodebuild")

        let generatedConfiguration = await MuterConfiguration(from: projectDirectoryContents)

        let expectedConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: [
                "-project",
                "iOSApp.xcodeproj",
                "-scheme",
                "iOSApp",
                "-destination",
                "platform=iOS Simulator,name=iPhone SE (3rd generation)",
                "test",
            ]
        )

        XCTAssertEqual(generatedConfiguration.testCommandExecutable, expectedConfiguration.testCommandExecutable)
        XCTAssertEqual(
            generatedConfiguration.testCommandArguments.filter { !$0.contains("platform") },
            expectedConfiguration.testCommandArguments.filter { !$0.contains("platform") }
        )
        XCTAssertNotNil(
            generatedConfiguration.testCommandArguments
                .first { $0.contains("platform=iOS Simulator,name=iPhone") }
        )
    }

    func test_xcodeWorkspace() async {
        let projectDirectoryContents = [
            "\(fixturesDirectory)/XcodeProjectFiles/iOSApp.xcodeproj",
            "\(fixturesDirectory)/XcodeProjectFiles/iOSApp.xcodeproj/project.xcworkspace",
            "\(fixturesDirectory)/XcodeProjectFiles/iOSApp.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
            "/some/path/AppDelegate.swift",
        ]

        process.stdoutToBeReturned = simCtl()
        process.stdoutToBeReturned = which("xcodebuild")

        let generatedConfiguration = await MuterConfiguration(from: projectDirectoryContents)

        let expectedConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: [
                "-project",
                "iOSApp.xcodeproj",
                "-scheme",
                "iOSApp",
                "-destination",
                "platform=iOS Simulator,name=iPhone SE (3rd generation)",
                "test",
            ]
        )

        XCTAssertEqual(generatedConfiguration.testCommandExecutable, expectedConfiguration.testCommandExecutable)
        XCTAssertEqual(
            generatedConfiguration.testCommandArguments.filter { !$0.contains("platform") },
            expectedConfiguration.testCommandArguments.filter { !$0.contains("platform") }
        )
        XCTAssertNotNil(
            generatedConfiguration.testCommandArguments
                .first { $0.contains("platform=iOS Simulator,name=iPhone") }
        )
    }

    func test_macOSProject() async {
        let projectDirectoryContents = [
            "\(fixturesDirectory)/XcodeProjectFiles/CocoaApp.xcodeproj",
            "/some/path/AppDelegate.swift",
        ]

        process.stdoutToBeReturned = macOSDescitionation()
        process.stdoutToBeReturned = which("xcodebuild")

        let generatedConfiguration = await MuterConfiguration(from: projectDirectoryContents)

        XCTAssertEqual(
            generatedConfiguration,
            MuterConfiguration(
                executable: "/path/to/xcodebuild",
                arguments: [
                    "-project",
                    "CocoaApp.xcodeproj",
                    "-scheme",
                    "CocoaApp",
                    "-destination",
                    "platform=macOS,arch=arm64,id=00006000-000A38D61E02401E,name=My Mac",
                    "test",
                ]
            )
        )
    }

    func test_iosWorkspace() async {
        let projectDirectoryContents = [
            "\(fixturesDirectory)/XcodeProjectFiles/iOSApp.xcodeproj",
            "/some/path/iOSApp.xcworkspace", // does not need to be a real file - just needs to share a name
            "/some/path/AppDelegate.swift",
        ]

        process.stdoutToBeReturned = simCtl()
        process.stdoutToBeReturned = which("xcodebuild")

        let generatedConfiguration = await MuterConfiguration(from: projectDirectoryContents)

        let expectedConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: [
                "-workspace",
                "iOSApp.xcworkspace",
                "-scheme",
                "iOSApp",
                "-destination",
                "platform=iOS Simulator,name=iPhone SE (3rd generation)",
                "test",
            ]
        )

        XCTAssertEqual(generatedConfiguration.testCommandExecutable, expectedConfiguration.testCommandExecutable)
        XCTAssertEqual(
            generatedConfiguration.testCommandArguments.filter { !$0.contains("platform") },
            expectedConfiguration.testCommandArguments.filter { !$0.contains("platform") }
        )
        XCTAssertNotNil(
            generatedConfiguration.testCommandArguments
                .first { $0.contains("platform=iOS Simulator,name=iPhone") }
        )
    }

    func test_macOSWorkspace() async {
        let projectDirectoryContents = [
            "\(fixturesDirectory)/XcodeProjectFiles/CocoaApp.xcodeproj",
            "/some/path/CocoaApp.xcworkspace", // does not need to be a real file - just needs to share a name
            "/some/path/AppDelegate.swift",
        ]

        process.stdoutToBeReturned = macOSDescitionation()
        process.stdoutToBeReturned = which("xcodebuild")

        let generatedConfiguration = await MuterConfiguration(from: projectDirectoryContents)

        XCTAssertEqual(
            generatedConfiguration,
            MuterConfiguration(
                executable: "/path/to/xcodebuild",
                arguments: [
                    "-workspace",
                    "CocoaApp.xcworkspace",
                    "-scheme",
                    "CocoaApp",
                    "-destination",
                    "platform=macOS,arch=arm64,id=00006000-000A38D61E02401E,name=My Mac",
                    "test",
                ]
            )
        )
    }

    // A project that uses a package plugin and a macro: the arguments skip both of Xcode's trust checks, so that a
    // run on CI, with no one to trust them, builds. They come before the destination, so that `test` still follows a
    // value: XcodeBuildConditions once read a `test` after an option as its value.
    func test_xcodeProjectUsingAPluginAndAMacro_skipsBothTrustChecks() async throws {
        let projectDirectoryContents = try projectUsingAPluginAndAMacro()

        process.stdoutToBeReturned = simCtl()
        process.stdoutToBeReturned = which("xcodebuild")

        let generatedConfiguration = await MuterConfiguration(from: projectDirectoryContents)

        XCTAssertEqual(generatedConfiguration.testCommandArguments.filter { !$0.contains("platform") }, [
            "-project", "App.xcodeproj", "-scheme", "App",
            "-skipPackagePluginValidation", "-skipMacroValidation", "-destination", "test",
        ])
    }

    // The same for a workspace.
    func test_xcodeWorkspaceUsingAPluginAndAMacro_skipsBothTrustChecks() async throws {
        let projectDirectoryContents = try projectUsingAPluginAndAMacro() + ["/some/path/App.xcworkspace"]

        process.stdoutToBeReturned = simCtl()
        process.stdoutToBeReturned = which("xcodebuild")

        let generatedConfiguration = await MuterConfiguration(from: projectDirectoryContents)

        XCTAssertEqual(generatedConfiguration.testCommandArguments.first, "-workspace")
        XCTAssertEqual(
            Array(generatedConfiguration.testCommandArguments[4...6]),
            ["-skipPackagePluginValidation", "-skipMacroValidation", "-destination"]
        )
        XCTAssertEqual(generatedConfiguration.testCommandArguments.last, "test")
    }

    /// An iOS app's project, whose target uses a package plugin, and whose resolved packages include swift-syntax.
    private func projectUsingAPluginAndAMacro() throws -> [String] {
        let project = try makeTemporaryDirectory() + "/App.xcodeproj"
        let swiftPM = "\(project)/project.xcworkspace/xcshareddata/swiftpm"
        try FileManager.default.createDirectory(atPath: swiftPM, withIntermediateDirectories: true)
        let iOSProject = try String(
            contentsOfFile: "\(fixturesDirectory)/XcodeProjectFiles/iOSApp.xcodeproj/project.pbxproj",
            encoding: .utf8
        )
        try (iOSProject + XcodebuildTrustCheckTests.projectUsingSwiftLintPlugin)
            .write(toFile: "\(project)/project.pbxproj", atomically: true, encoding: .utf8)
        try XcodebuildTrustCheckTests.resolvedWithSwiftSyntax
            .write(toFile: "\(swiftPM)/Package.resolved", atomically: true, encoding: .utf8)

        return [
            project,
            "\(project)/project.pbxproj",
            "\(project)/project.xcworkspace",
            "\(swiftPM)/Package.resolved",
        ]
    }
    #endif

    // `swift test` makes neither trust check, so a package's configuration has no argument to skip them.
    func test_swiftPackageManagerProjectWithAMacro_skipsNoTrustCheck() async throws {
        let manifest = try makeTemporaryDirectory() + "/Package.swift"
        try #".macro(name: "MacrosImpl"), .plugin(name: "Gen", capability: .buildTool())"#
            .write(toFile: manifest, atomically: true, encoding: .utf8)

        process.stdoutToBeReturned = which("swift")

        let generatedConfiguration = await MuterConfiguration(from: [manifest])

        XCTAssertEqual(generatedConfiguration.testCommandArguments, ["test"])
    }

    func test_unsupportedProject() async {
        let generatedConfiguration = await MuterConfiguration(from: ["/some/path/main.swift"])
        XCTAssertEqual(
            generatedConfiguration,
            MuterConfiguration(executable: "", arguments: [])
        )
    }

    private func simCtl() -> String {
        """
        {
            "devicetypes":
            [
                {
                    "productFamily": "iPhone",
                    "bundlePath": "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 14 Plus.simdevicetype",
                    "maxRuntimeVersion": 4294967295,
                    "maxRuntimeVersionString": "65535.255.255",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-14-Plus",
                    "modelIdentifier": "iPhone14,8",
                    "minRuntimeVersionString": "16.0.0",
                    "minRuntimeVersion": 1048576,
                    "name": "iPhone 14 Plus"
                },
                {
                    "productFamily": "iPhone",
                    "bundlePath": "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone SE (3rd generation).simdevicetype",
                    "maxRuntimeVersion": 4294967295,
                    "maxRuntimeVersionString": "65535.255.255",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation",
                    "modelIdentifier": "iPhone14,6",
                    "minRuntimeVersionString": "15.4.0",
                    "minRuntimeVersion": 984064,
                    "name": "iPhone SE (3rd generation)"
                }
            ]
        }
        """
    }

    private func macOSDescitionation() -> String {
        """
            [MT] IDERunDestination: Supported platforms for the buildables in the current scheme is empty.


                Available destinations for the "ExampleMacOSApp" scheme:
                    { platform:macOS, arch:arm64, id:00006000-000A38D61E02401E, name:My Mac }
                    { platform:macOS, name:Any Mac }
        """
    }

    func which(_ program: String) -> String {
        "/path/to/\(program)"
    }
}
