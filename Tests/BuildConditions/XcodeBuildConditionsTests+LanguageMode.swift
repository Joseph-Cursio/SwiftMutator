@testable import muterCore
import SwiftIfConfig
import XCTest

extension XcodeBuildConditionsTests {
    /// A file that may set a target's language mode, what it holds, and the target's settings.
    private struct ModeSetting {
        let file: String
        let contents: String
        let settings: [String: String]

        init(_ file: String, _ contents: String, _ settings: [String: String]) {
            self.file = file
            self.contents = contents
            self.settings = settings
        }
    }

    /// A project file, the test command's arguments, and the environment it runs in.
    private struct ConfigurationFileCase {
        let pbxproj: String
        let arguments: [String]
        let environment: [String: String]

        init(_ pbxproj: String, _ arguments: [String], _ environment: [String: String]) {
            self.pbxproj = pbxproj
            self.arguments = arguments
            self.environment = environment
        }
    }

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
        let cases = [
            ModeSetting("App.xcodeproj/project.pbxproj", "SWIFT_VERSION = 5.0;", ["SWIFT_VERSION": "6.0"]),
            ModeSetting("Shared.xcconfig", "SWIFT_VERSION = $(MY_MODE)", ["SWIFT_VERSION": "6.0"]),
            ModeSetting("Packages/Lib/Package.swift", "// swift-tools-version:6.0", ["SWIFT_VERSION": "6.0"]),
            ModeSetting(
                "App.xcodeproj/project.pbxproj",
                "OTHER_SWIFT_FLAGS = -swift-version 5;",
                ["SWIFT_VERSION": "6.0"]
            ),
            ModeSetting("Notes.txt", "", ["SWIFT_VERSION": "6.0", "OTHER_SWIFT_FLAGS": "-language-mode 5"]),
            ModeSetting("Notes.txt", "", ["SWIFT_VERSION": "6.2"]),
            ModeSetting("Notes.txt", "", [:]),
        ]
        for setting in cases {
            project = try makeTemporaryDirectory()
            try write(setting.contents, to: setting.file)
            settingsAndVersion(test: [withXcodesToolchain(setting.settings)])

            let conditions = try await conditions(arguments: ["test"])

            XCTAssertNil(conditions.language, "\(setting.file): \(setting.contents) \(setting.settings)")
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
        try write(projectFile(basedOn: "Base.xcconfig", inGroupAt: "Config"), to: "App.xcodeproj/project.pbxproj")
        try write("SWIFT_VERSION = 5.0", to: "Config/Base.xcconfig")
        settingsAndVersion(test: [withXcodesToolchain(["SWIFT_VERSION": "5.0"])])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertEqual(conditions.language, VersionTuple(5, 10))
    }

    // One outside the project, or `-xcconfig`'s or `XCODE_XCCONFIG_FILE`'s, may set an unreported target's mode.
    func test_theLanguageVersion_isUnknown_whenAConfigurationFileItDidntReadMaySetIt() async throws {
        let cases = [
            ConfigurationFileCase(projectFile(basedOn: "Base.xcconfig", inGroupAt: "../Shared"), ["test"], [:]),
            ConfigurationFileCase(projectFile(basedOn: "$(SRCROOT)/Base.xcconfig"), ["test"], [:]),
            ConfigurationFileCase(projectFile(basedOn: "Missing.xcconfig"), ["test"], [:]),
            ConfigurationFileCase("", ["-xcconfig", "/ci/Overrides.xcconfig", "test"], [:]),
            ConfigurationFileCase("", ["test"], ["XCODE_XCCONFIG_FILE": "/ci/Overrides.xcconfig"]),
        ]
        for configuration in cases {
            project = try makeTemporaryDirectory()
            try write(configuration.pbxproj, to: "App.xcodeproj/project.pbxproj")
            settingsAndVersion(test: [withXcodesToolchain(["SWIFT_VERSION": "5.0"])])

            let conditions = try await conditions(
                arguments: configuration.arguments,
                environment: configuration.environment
            )

            XCTAssertNil(
                conditions.language,
                "\(configuration.pbxproj) \(configuration.arguments) \(configuration.environment)"
            )
        }
    }
}
