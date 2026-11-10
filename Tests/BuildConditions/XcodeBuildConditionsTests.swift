@testable import muterCore
import SwiftIfConfig
import XCTest

final class XcodeBuildConditionsTests: MuterTestCase {
    let xcodebuild = "/usr/bin/xcodebuild"
    var project = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        current.fileManager = FileManager.default
        project = try makeTemporaryDirectory()
    }

    func test_readsThePlatformAndConditionsOfTheTestBundle_andOfTheScheme() async throws {
        let shared = ["PLATFORM_NAME": "iphonesimulator", "ARCHS": "arm64", "CONFIGURATION": "Testing"]
        let testBundle = ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG TESTS"]
        let scheme = [
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "OTHER_SWIFT_FLAGS": "-plugin-path /x -DFROM_FLAG -D 'SPLIT'",
        ]
        settings(
            test: [shared.merging(testBundle) { first, _ in first }],
            build: [shared.merging(scheme) { first, _ in first }]
        )

        let conditions = try await conditions(arguments: ["-scheme", "App", "-destination", "d", "test"])

        XCTAssertEqual(conditions.platform?.system, "iOS")
        XCTAssertEqual(conditions.platform?.environment, "simulator")
        XCTAssertEqual(conditions.platform?.architectures, ["arm64"])
        XCTAssertEqual(conditions.customConditions, [["DEBUG", "TESTS"], ["DEBUG", "FROM_FLAG", "SPLIT"]])
        // The test action's configuration, for the scheme's own targets too.
        XCTAssertEqual(process.commandsRun, [
            [xcodebuild, "-scheme", "App", "-destination", "d", "test", "-showBuildSettings", "-json"],
            [
                xcodebuild, "-scheme", "App", "-destination", "d", "-configuration", "Testing",
                "-showBuildSettings", "-json",
            ],
        ])
    }

    func test_aConfigurationGiven_isLeftAlone() async throws {
        settings(test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64", "CONFIGURATION": "Debug"]], build: [])

        _ = try await conditions(arguments: ["-configuration", "Beta", "test"])

        XCTAssertEqual(process.commandsRun.last, [
            xcodebuild, "-configuration", "Beta", "-showBuildSettings", "-json",
        ])
    }

    // A value that reads like an action isn't one.
    func test_onlyActionsAreTakenOut() async throws {
        settings(test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64"]], build: [])

        _ = try await conditions(arguments: ["clean", "-scheme", "test", "build", "test"])

        XCTAssertEqual(process.commandsRun.last, [xcodebuild, "-scheme", "test", "-showBuildSettings", "-json"])
    }

    // An option that takes no value, as the trust check ones init writes, leaves the action after it an action.
    func test_anActionAfterAnOptionWithNoValue_isTakenOut() async throws {
        settings(test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64"]], build: [])

        _ = try await conditions(arguments: ["-scheme", "App", "-quiet", "-skipMacroValidation", "test"])

        XCTAssertEqual(process.commandsRun.last, [
            xcodebuild, "-scheme", "App", "-quiet", "-skipMacroValidation", "-showBuildSettings", "-json",
        ])
    }

    func test_withNoActionToTakeOut_itIsAskedOnce() async throws {
        settings(test: [], build: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64"]])

        _ = try await conditions(arguments: ["-scheme", "App"])

        XCTAssertEqual(process.commandsRun.count, 1)
    }

    func test_theSecondAskFailing_keepsTheFirstsTargets() async throws {
        process.commandResult = { [self] command in
            command.contains("test") ? result(of: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64"]]) : nil
        }

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertEqual(conditions.platform?.system, "macOS")
        XCTAssertEqual(conditions.customConditions, [[]])
    }

    // A Swift package's scheme has none.
    func test_noBuildSettings_isAFailure() async throws {
        process.commandResult = { [self] _ in result(of: []) }

        let conditions = await XcodeBuildConditions.conditions(
            inProjectAt: project,
            testedBy: MuterConfiguration(executable: xcodebuild, arguments: ["test"]),
            process: current.process,
            fileManager: FileManager.default
        )

        XCTAssertEqual(
            conditions,
            .failure(BuildConditionsUnavailable(reason: "xcodebuild reported no build settings"))
        )
    }

    func test_xcodebuildFailing_isAFailure() async throws {
        process.commandResult = { _ in CommandResult(status: 65, endedBySignal: false, output: "", errors: "no") }

        let result = await XcodeBuildConditions.conditions(
            inProjectAt: project,
            testedBy: MuterConfiguration(executable: xcodebuild, arguments: ["test"]),
            process: current.process,
            fileManager: FileManager.default
        )

        XCTAssertEqual(result, .failure(BuildConditionsUnavailable(reason: "xcodebuild reported no build settings")))
    }

    // MARK: Helpers

    /// A project file, as Xcode writes one, whose main group holds `children`, with `objects`.
    func projectFile(mainGroup children: String, _ objects: String) -> String {
        """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            objects = {
                P = {isa = PBXProject; mainGroup = M; projectDirPath = ""; };
                M = {isa = PBXGroup; children = (\(children)); sourceTree = "<group>"; };
                \(objects)
            };
            rootObject = P;
        }
        """
    }

    /// One whose build configuration is based on the build configuration file at `path`, by `sourceTree`, in the
    /// main group or a group in it at `group`.
    func projectFile(
        basedOn path: String,
        sourceTree: String = #""<group>""#,
        inGroupAt group: String? = nil
    ) -> String {
        let file = """
        F = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = "\(path)"; sourceTree = \(sourceTree); };
        C = {isa = XCBuildConfiguration; baseConfigurationReference = F; buildSettings = {}; name = Debug; };
        """
        guard let group else { return projectFile(mainGroup: "F", file) }
        return projectFile(
            mainGroup: "G",
            #"G = {isa = PBXGroup; children = (F); path = "\#(group)"; sourceTree = "<group>"; };"# + "\n" + file
        )
    }

    /// A workspace's contents, as Xcode writes them, with `references`.
    func workspaceFile(_ references: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace
           version = "1.0">
        \(references)
        </Workspace>
        """
    }

    /// One that references the project at `path`, as a project it builds a target of.
    func projectFile(referencingProject path: String) -> String {
        projectFile(mainGroup: "R", """
        R = {isa = PBXFileReference; lastKnownFileType = "wrapper.pb-project";
            path = "\(path)"; sourceTree = "<group>"; };
        """)
    }

    /// `settings` on a macOS target that builds with Xcode's own toolchain.
    func withXcodesToolchain(_ settings: [String: String]) -> [String: String] {
        let onXcodesToolchain = macOSTarget.merging([
            "TOOLCHAIN_DIR": "/Xcode/Default.xctoolchain", "TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault",
        ]) { first, _ in first }
        return onXcodesToolchain.merging(settings) { _, new in new }
    }

    let macOSTarget = ["PLATFORM_NAME": "macosx", "ARCHS": "arm64"]

    /// `test` as the settings of the test command, and `swiftc --version` printing 6.4.2.
    func settingsAndVersion(test: [[String: String]]) {
        process.commandResult = { [self] command in
            guard command.last != "--version" else {
                return CommandResult(
                    status: 0,
                    endedBySignal: false,
                    output: "Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)\n",
                    errors: ""
                )
            }
            return result(of: command.dropFirst().contains("test") ? test : [])
        }
    }

    func settings(test: [[String: String]], build: [[String: String]]) {
        process.commandResult = { [self] command in
            result(of: command.dropFirst().contains { ["test", "build", "clean"].contains($0) } ? test : build)
        }
    }

    func result(of targets: [[String: String]]) -> CommandResult {
        let objects = targets.map { ["action": "test", "target": "T", "buildSettings": $0] as [String: Any] }
        let json = try? JSONSerialization.data(withJSONObject: objects)
        return CommandResult(
            status: 0,
            endedBySignal: false,
            output: json.map { String(lossyUTF8: $0) } ?? "",
            errors: ""
        )
    }

    func conditions(
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> BuildConditions {
        let result = await XcodeBuildConditions.conditions(
            inProjectAt: project,
            testedBy: MuterConfiguration(executable: xcodebuild, arguments: arguments),
            process: current.process,
            fileManager: FileManager.default,
            environment: environment
        )
        return try result.get().everyTarget
    }

    func write(_ contents: String, to path: String) throws {
        let url = URL(fileURLWithPath: project + "/" + path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// An SDK where Xcode keeps them, with `frameworks` that have modules, and the Swift module every SDK has.
    func makeSDK(in platforms: String, named name: String, frameworks: [String]) throws -> String {
        let sdk = "\(platforms)/\(name).platform/Developer/SDKs/\(name).sdk"
        for framework in frameworks {
            try FileManager.default.createDirectory(
                atPath: "\(sdk)/System/Library/Frameworks/\(framework).framework/Modules",
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            atPath: "\(sdk)/usr/lib/swift/Swift.swiftmodule",
            withIntermediateDirectories: true
        )
        return sdk
    }
}
