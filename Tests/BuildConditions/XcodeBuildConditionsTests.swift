@testable import muterCore
import SwiftIfConfig
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

    // MARK: The compiler's version

    func test_theCompilersVersion_isWhatTheToolchainsSwiftcSays() async throws {
        let toolchain = [
            "TOOLCHAIN_DIR": "/Xcode/Default.xctoolchain", "TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault",
        ]
        settingsAndVersion(test: [macOSTarget.merging(toolchain) { first, _ in first }])

        let conditions = try await conditions(arguments: ["-scheme", "App", "test"])

        XCTAssertEqual(conditions.compiler, VersionTuple(6, 4, 2))
        XCTAssertEqual(process.commandsRun.last, ["/Xcode/Default.xctoolchain/usr/bin/swiftc", "--version"])
    }

    // `TOOLCHAIN_DIR` may not follow `-toolchain`, and `SWIFT_EXEC` or another toolchain builds with another compiler.
    func test_theCompilersVersion_isUnknown_whenAnotherCompilerMayBuild() async throws {
        let toolchain = [
            "TOOLCHAIN_DIR": "/Xcode/Default.xctoolchain", "TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault",
        ]
        let cases: [(settings: [String: String], arguments: [String])] = [
            (toolchain, ["-toolchain", "swift", "test"]),
            (toolchain.merging(["SWIFT_EXEC": "/my/swiftc"]) { _, new in new }, ["test"]),
            (toolchain.merging(["TOOLCHAINS": "org.swift.64202601"]) { _, new in new }, ["test"]),
            (toolchain.filter { $0.key != "TOOLCHAINS" }, ["test"]),
            (toolchain.filter { $0.key != "TOOLCHAIN_DIR" }, ["test"]),
        ]
        for (settings, arguments) in cases {
            settingsAndVersion(test: [macOSTarget.merging(settings) { first, _ in first }])

            let conditions = try await conditions(arguments: arguments)

            XCTAssertNil(conditions.compiler, "\(settings) \(arguments)")
            XCTAssertFalse(process.commandsRun.contains { $0.last == "--version" }, "\(settings) \(arguments)")
        }
    }

    // A target xcodebuild doesn't report, such as the framework the tests test, may set its own.
    func test_theCompilersVersion_isUnknown_whenABuildFileNamesToolchainsOrSwiftExec() async throws {
        let target = macOSTarget.merging([
            "TOOLCHAIN_DIR": "/Xcode/Default.xctoolchain", "TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault",
        ]) { first, _ in first }
        for setting in ["TOOLCHAINS = org.swift.633202606251a;", "SWIFT_EXEC = /my/swiftc;"] {
            try write(setting, to: "Framework.xcconfig")
            settingsAndVersion(test: [target])

            let conditions = try await conditions(arguments: ["test"])

            XCTAssertNil(conditions.compiler, setting)
        }
    }

    func test_theCompilersVersion_isUnknown_whenTheTargetsToolchainsDiffer() async throws {
        let shared = macOSTarget.merging(["TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault"]) { first, _ in first }
        settingsAndVersion(test: [
            shared.merging(["TOOLCHAIN_DIR": "/one"]) { first, _ in first },
            shared.merging(["TOOLCHAIN_DIR": "/two"]) { first, _ in first },
        ])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNil(conditions.compiler)
    }

    // MARK: The language mode

    func test_theLanguageVersion_isTheTargetsAndBuildFilesSharedModes() async throws {
        try write("SWIFT_VERSION = 5.0;\nEFFECTIVE_SWIFT_VERSION = 6;", to: "App.xcodeproj/project.pbxproj")
        settingsAndVersion(test: [withXcodesToolchain(["SWIFT_VERSION": "5.0"])])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertEqual(conditions.language, VersionTuple(5, 10))
    }

    func test_inSwift6Mode_theLanguageVersionIsTheCompilers() async throws {
        settingsAndVersion(test: [withXcodesToolchain(["SWIFT_VERSION": "6.0"])])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertEqual(conditions.language, VersionTuple(6, 4, 2))
    }

    // A target xcodebuild doesn't report may be the one a build file sets apart, and a package's targets have modes of
    // their own.
    func test_theLanguageVersion_isUnknown_whenAnyTargetMayHaveAnotherMode() async throws {
        let cases: [(file: String, contents: String, settings: [String: String])] = [
            ("App.xcodeproj/project.pbxproj", "SWIFT_VERSION = 5.0;", ["SWIFT_VERSION": "6.0"]),
            ("Shared.xcconfig", "SWIFT_VERSION = $(MY_MODE)", ["SWIFT_VERSION": "6.0"]),
            ("Packages/Lib/Package.swift", "// swift-tools-version:6.0", ["SWIFT_VERSION": "6.0"]),
            ("App.xcodeproj/project.pbxproj", "OTHER_SWIFT_FLAGS = -swift-version 5;", ["SWIFT_VERSION": "6.0"]),
            ("Notes.txt", "", ["SWIFT_VERSION": "6.0", "OTHER_SWIFT_FLAGS": "-language-mode 5"]),
            ("Notes.txt", "", ["SWIFT_VERSION": "6.2"]),
            ("Notes.txt", "", [:]),
        ]
        for (file, contents, settings) in cases {
            project = try makeTemporaryDirectory()
            try write(contents, to: file)
            settingsAndVersion(test: [withXcodesToolchain(settings)])

            let conditions = try await conditions(arguments: ["test"])

            XCTAssertNil(conditions.language, "\(file): \(contents) \(settings)")
        }
    }

    func test_theLanguageVersion_isUnknown_withoutTheCompilersVersion() async throws {
        settingsAndVersion(test: [macOSTarget.merging(["SWIFT_VERSION": "5.0"]) { first, _ in first }])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNil(conditions.language)
    }

    // A mention it can't read as a setting may still be one, so it reads as a mode SwiftMutator doesn't know.
    func test_theSwiftVersionsABuildFileSets() {
        XCTAssertEqual(
            XcodeBuildConditions.swiftVersions(in: """
            \t\t\t\tSWIFT_VERSION = 5.0;
            \t\t\t\tEFFECTIVE_SWIFT_VERSION = 6; MY_SWIFT_VERSION = 4; SWIFT_VERSION_X = 4;
            SWIFT_VERSION[sdk=iphoneos*] = 4.2 // for the device
            \t\t\t\t"SWIFT_VERSION[sdk=iphonesimulator*]" = "6.0";
            SWIFT_VERSION[config=Debug][sdk=*] = 4
            SWIFT_VERSION = $(inherited)
            // SWIFT_VERSION is set above
            """),
            [.swift5, .swift4dot2, .swift6, .swift4, nil, nil]
        )
    }

    func test_theLanguageVersion_followsABuildConfigurationFileTheProjectNames() async throws {
        try write(
            "baseConfigurationReference = 1A /* Base.xcconfig */; path = Config/Base.xcconfig;",
            to: "App.xcodeproj/project.pbxproj"
        )
        try write("SWIFT_VERSION = 5.0", to: "Config/Base.xcconfig")
        settingsAndVersion(test: [withXcodesToolchain(["SWIFT_VERSION": "5.0"])])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertEqual(conditions.language, VersionTuple(5, 10))
    }

    // One outside the project, or `-xcconfig`'s or `XCODE_XCCONFIG_FILE`'s, may set an unreported target's mode.
    func test_theLanguageVersion_isUnknown_whenAConfigurationFileItDidntReadMaySetIt() async throws {
        let cases: [(pbxproj: String, arguments: [String], environment: [String: String])] = [
            ("path = ../Shared/Base.xcconfig;", ["test"], [:]),
            ("path = \"$(SRCROOT)/Base.xcconfig\";", ["test"], [:]),
            ("path = Missing.xcconfig;", ["test"], [:]),
            ("", ["-xcconfig", "/ci/Overrides.xcconfig", "test"], [:]),
            ("", ["test"], ["XCODE_XCCONFIG_FILE": "/ci/Overrides.xcconfig"]),
        ]
        for (pbxproj, arguments, environment) in cases {
            project = try makeTemporaryDirectory()
            try write(pbxproj, to: "App.xcodeproj/project.pbxproj")
            settingsAndVersion(test: [withXcodesToolchain(["SWIFT_VERSION": "5.0"])])

            let conditions = try await conditions(arguments: arguments, environment: environment)

            XCTAssertNil(conditions.language, "\(pbxproj) \(arguments) \(environment)")
        }
    }

    // MARK: Helpers

    /// `settings` on a macOS target that builds with Xcode's own toolchain.
    private func withXcodesToolchain(_ settings: [String: String]) -> [String: String] {
        macOSTarget.merging([
            "TOOLCHAIN_DIR": "/Xcode/Default.xctoolchain", "TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault",
        ]) { first, _ in first }.merging(settings) { _, new in new }
    }

    private let macOSTarget = ["PLATFORM_NAME": "macosx", "ARCHS": "arm64"]

    /// `test` as the settings of the test command, and `swiftc --version` printing 6.4.2.
    private func settingsAndVersion(test: [[String: String]]) {
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

    private func conditions(
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
