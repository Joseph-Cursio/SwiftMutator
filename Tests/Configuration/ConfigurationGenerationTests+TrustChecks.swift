@testable import muterCore
import XCTest

extension ConfigurationGenerationTests {
    // `swift test` makes neither trust check, so a package's configuration has no argument to skip them.
    func test_swiftPackageManagerProjectWithAMacro_skipsNoTrustCheck() async throws {
        let directory = try makeTemporaryDirectory()
        try #".macro(name: "MacrosImpl"), .plugin(name: "Gen", capability: .buildTool())"#
            .write(toFile: "\(directory)/Package.swift", atomically: true, encoding: .utf8)

        process.stdoutToBeReturned = which("swift")

        let generated = try await MuterConfiguration.generated(from: ["Package.swift"], in: directory)

        XCTAssertEqual(generated.configuration.testCommandArguments, ["test"])
    }

    #if !os(Linux)
    // A project that uses a package plugin and a macro: the arguments skip both of Xcode's trust checks, so that a
    // run on CI, with no one to trust them, builds. They come before the destination, so that `test` still follows a
    // value: XcodeBuildConditions once read a `test` after an option as its value.
    func test_xcodeProjectUsingAPluginAndAMacro_skipsBothTrustChecks() async throws {
        let (directory, contents) = try projectUsingAPluginAndAMacro()

        process.stdoutToBeReturned = listing(schemes: ["App"])
        process.stdoutToBeReturned = simCtl()
        process.stdoutToBeReturned = which("xcodebuild")

        let generated = try await MuterConfiguration.generated(from: contents, in: directory)

        XCTAssertEqual(generated.configuration.testCommandArguments.filter { !$0.contains("platform") }, [
            "-project", "App.xcodeproj", "-scheme", "App",
            "-skipPackagePluginValidation", "-skipMacroValidation", "-destination", "test",
        ])
    }

    // The same for a workspace.
    func test_xcodeWorkspaceUsingAPluginAndAMacro_skipsBothTrustChecks() async throws {
        let (directory, contents) = try projectUsingAPluginAndAMacro()

        process.stdoutToBeReturned = listing(schemes: ["App"], kind: "workspace")
        process.stdoutToBeReturned = simCtl()
        process.stdoutToBeReturned = which("xcodebuild")

        let generated = try await MuterConfiguration.generated(from: contents + ["App.xcworkspace"], in: directory)

        let arguments = generated.configuration.testCommandArguments
        XCTAssertEqual(arguments.first, "-workspace")
        XCTAssertEqual(
            Array(arguments[4...6]),
            ["-skipPackagePluginValidation", "-skipMacroValidation", "-destination"]
        )
        XCTAssertEqual(arguments.last, "test")
    }

    /// An iOS app's project, whose target uses a package plugin, and whose resolved packages include swift-syntax: its
    /// folder, and its files, relative to it.
    func projectUsingAPluginAndAMacro() throws -> (directory: String, contents: [String]) {
        let directory = try makeTemporaryDirectory()
        let project = "App.xcodeproj"
        let swiftPM = "\(project)/project.xcworkspace/xcshareddata/swiftpm"
        try FileManager.default.createDirectory(atPath: "\(directory)/\(swiftPM)", withIntermediateDirectories: true)
        let iOSProject = try String(
            contentsOfFile: "\(fixturesDirectory)/XcodeProjectFiles/iOSApp.xcodeproj/project.pbxproj",
            encoding: .utf8
        )
        try (iOSProject + XcodebuildTrustCheckTests.projectUsingSwiftLintPlugin)
            .write(toFile: "\(directory)/\(project)/project.pbxproj", atomically: true, encoding: .utf8)
        try XcodebuildTrustCheckTests.resolvedWithSwiftSyntax
            .write(toFile: "\(directory)/\(swiftPM)/Package.resolved", atomically: true, encoding: .utf8)

        return (directory, [
            project,
            "\(project)/project.pbxproj",
            "\(project)/project.xcworkspace",
            "\(swiftPM)/Package.resolved",
        ])
    }
    #endif
}
