@testable import muterCore
import XCTest

extension ConfigurationGenerationTests {
    // `swift test` makes neither trust check, so a package's configuration has no argument to skip them.
    func test_swiftPackageManagerProjectWithAMacro_skipsNoTrustCheck() async throws {
        let manifest = try makeTemporaryDirectory() + "/Package.swift"
        try #".macro(name: "MacrosImpl"), .plugin(name: "Gen", capability: .buildTool())"#
            .write(toFile: manifest, atomically: true, encoding: .utf8)

        process.stdoutToBeReturned = which("swift")

        let generatedConfiguration = await MuterConfiguration(from: [manifest])

        XCTAssertEqual(generatedConfiguration.testCommandArguments, ["test"])
    }

    #if !os(Linux)
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
    func projectUsingAPluginAndAMacro() throws -> [String] {
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
}
