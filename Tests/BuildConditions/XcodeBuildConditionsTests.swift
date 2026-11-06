@testable import muterCore
import XCTest

final class XcodeBuildConditionsTests: MuterTestCase {
    private let xcodebuild = "/usr/bin/xcodebuild"
    private var project = ""

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

    func test_eachPlatform() async throws {
        for (name, system, environment) in [
            ("macosx", "macOS", nil),
            ("iphoneos", "iOS", nil),
            ("iphonesimulator", "iOS", "simulator"),
            ("appletvos", "tvOS", nil),
            ("appletvsimulator", "tvOS", "simulator"),
            ("watchos", "watchOS", nil),
            ("watchsimulator", "watchOS", "simulator"),
            ("xros", "visionOS", nil),
            ("xrsimulator", "visionOS", "simulator"),
            ("driverkit", "DriverKit", nil),
        ] as [(String, String, String?)] {
            settings(test: [["PLATFORM_NAME": name, "ARCHS": "arm64"]], build: [])

            let conditions = try await conditions(arguments: ["test"])

            XCTAssertEqual(conditions.platform?.system, system, name)
            XCTAssertEqual(conditions.platform?.environment, environment, name)
        }
    }

    func test_MacCatalyst_isIOSInItsEnvironment() async throws {
        settings(test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64", "IS_MACCATALYST": "YES"]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertEqual(conditions.platform?.system, "iOS")
        XCTAssertEqual(conditions.platform?.environment, "macCatalyst")
    }

    func test_aPlatformItDoesntKnow_isNoPlatform() async throws {
        settings(test: [["PLATFORM_NAME": "newos", "ARCHS": "arm64"]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNil(conditions.platform)
    }

    func test_targetsForDifferentPlatforms_areNoPlatform() async throws {
        settings(
            test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64"], ["PLATFORM_NAME": "iphoneos", "ARCHS": "arm64"]],
            build: []
        )

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNil(conditions.platform)
    }

    // The settings report one, whichever they can be.
    func test_severalDestinations_areNoPlatform() async throws {
        settings(test: [["PLATFORM_NAME": "iphonesimulator", "ARCHS": "arm64"]], build: [])

        let conditions = try await conditions(arguments: ["-destination", "a", "-destination", "b", "test"])

        XCTAssertNil(conditions.platform)
    }

    func test_noArchitectures_areNoPlatform() async throws {
        settings(test: [["PLATFORM_NAME": "macosx"]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNil(conditions.platform)
    }

    func test_aBuildForSeveralArchitectures_keepsThemAll() async throws {
        settings(test: [["PLATFORM_NAME": "iphonesimulator", "ARCHS": "arm64 x86_64"]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertEqual(conditions.platform?.architectures, ["arm64", "x86_64"])
    }

    func test_theSDKsModules() async throws {
        let platforms = project + "/Developer/Platforms"
        let macOS = try makeSDK(in: platforms, named: "MacOSX", frameworks: ["AppKit", "SwiftUI"])
        _ = try makeSDK(in: platforms, named: "iPhoneOS", frameworks: ["UIKit", "SwiftUI"])
        settings(test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64", "SDKROOT": macOS]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertEqual(conditions.platform?.modules?.present, ["AppKit", "SwiftUI", "Swift"])
        XCTAssertEqual(conditions.platform?.modules?.absent, ["UIKit"])
    }

    // A framework with no `Modules` folder can't be imported.
    func test_aFrameworkWithoutModules_isNotAModule() async throws {
        let platforms = project + "/Developer/Platforms"
        let sdk = try makeSDK(in: platforms, named: "MacOSX", frameworks: ["AppKit"])
        try FileManager.default.createDirectory(
            atPath: sdk + "/System/Library/Frameworks/HeadersOnly.framework/Headers",
            withIntermediateDirectories: true
        )

        let modules = try XCTUnwrap(BuildConditions.SDKModules(sdk: sdk, fileManager: FileManager.default))

        XCTAssertFalse(modules.present.contains("HeadersOnly"))
    }

    func test_MacCatalyst_leavesCanImportUndecided() async throws {
        let sdk = try makeSDK(in: project + "/Developer/Platforms", named: "MacOSX", frameworks: ["AppKit"])
        settings(
            test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64", "SDKROOT": sdk, "IS_MACCATALYST": "YES"]],
            build: []
        )

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNotNil(conditions.platform)
        XCTAssertNil(conditions.platform?.modules)
    }

    // So nothing reads as absent because the SDK couldn't be read.
    func test_anSDKThatListsNothing_givesNoModules() async throws {
        settings(test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64", "SDKROOT": project + "/nothing"]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNotNil(conditions.platform)
        XCTAssertNil(conditions.platform?.modules)
    }

    // A condition in a build file can be a setting of a target xcodebuild didn't report, or a local package's.
    func test_theNamesInTheProjectsBuildFiles_areUndecided() async throws {
        try write("OTHER_SWIFT_FLAGS = -DFROM_PROJECT;", to: "App.xcodeproj/project.pbxproj")
        try write("SWIFT_ACTIVE_COMPILATION_CONDITIONS = FROM_CONFIG", to: "Configs/Shared.xcconfig")
        try write(#".define("FROM_MANIFEST")"#, to: "Packages/Core/Package.swift")
        try write(#".define("FROM_VERSIONED_MANIFEST")"#, to: "Packages/Core/Package@swift-6.0.swift")
        try write("let IN_SOURCE = 1", to: "Sources/App.swift")
        settings(test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64"]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertTrue(conditions.undecidedConditions.isSuperset(of: [
            "FROM_PROJECT", "FROM_CONFIG", "FROM_MANIFEST", "FROM_VERSIONED_MANIFEST",
        ]))
        XCTAssertFalse(conditions.undecidedConditions.contains("IN_SOURCE"))
    }

    // In `-DGLUED`, the name is glued to its `D`, so as a word it reads `DGLUED`.
    func test_aDashDFlagInABuildFile_makesItsNameUndecided() async throws {
        try write("OTHER_SWIFT_FLAGS = \"-DGLUED -D SPACED\";", to: "App.xcodeproj/project.pbxproj")
        settings(test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64"]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertTrue(conditions.undecidedConditions.contains("GLUED"))
        XCTAssertTrue(conditions.undecidedConditions.contains("SPACED"))
    }

    // A Swift package's scheme has none.
    func test_noBuildSettings_isAFailure() async throws {
        process.commandResult = { [self] _ in result(of: []) }

        let result = await XcodeBuildConditions.conditions(
            inProjectAt: project,
            testedBy: MuterConfiguration(executable: xcodebuild, arguments: ["test"]),
            process: current.process,
            fileManager: FileManager.default
        )

        XCTAssertEqual(result, .failure(BuildConditionsUnavailable(reason: "xcodebuild reported no build settings")))
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

    private func settings(test: [[String: String]], build: [[String: String]]) {
        process.commandResult = { [self] command in
            result(of: command.dropFirst().contains { ["test", "build", "clean"].contains($0) } ? test : build)
        }
    }

    private func result(of targets: [[String: String]]) -> CommandResult {
        let objects = targets.map { ["action": "test", "target": "T", "buildSettings": $0] as [String: Any] }
        let json = try? JSONSerialization.data(withJSONObject: objects)
        return CommandResult(
            status: 0,
            endedBySignal: false,
            output: json.map { String(decoding: $0, as: UTF8.self) } ?? "",
            errors: ""
        )
    }

    private func conditions(arguments: [String]) async throws -> BuildConditions {
        let result = await XcodeBuildConditions.conditions(
            inProjectAt: project,
            testedBy: MuterConfiguration(executable: xcodebuild, arguments: arguments),
            process: current.process,
            fileManager: FileManager.default
        )
        return try result.get().everyTarget
    }

    private func write(_ contents: String, to path: String) throws {
        let url = URL(fileURLWithPath: project + "/" + path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// An SDK where Xcode keeps them, with `frameworks` that have modules, and the Swift module every SDK has.
    private func makeSDK(in platforms: String, named name: String, frameworks: [String]) throws -> String {
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
