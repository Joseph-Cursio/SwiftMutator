@testable import muterCore
import SwiftIfConfig
import XCTest

extension SwiftPackageBuildConditionsTests {
    /// A manifest's tools version and `swiftLanguageModes`, and the language version they give.
    private struct ToolsVersionCase {
        let toolsVersion: String
        let modes: String
        let expected: VersionTuple

        init(_ toolsVersion: String, _ modes: String, _ expected: VersionTuple) {
            self.toolsVersion = toolsVersion
            self.modes = modes
            self.expected = expected
        }
    }

    /// A manifest's `swiftLanguageModes`, its library's settings, and the test command's arguments, which together
    /// leave the mode a target builds in untold.
    private struct UntellableMode {
        let modes: String
        let lib: String
        let arguments: [String]

        init(_ modes: String, _ lib: String, _ arguments: [String]) {
            self.modes = modes
            self.lib = lib
            self.arguments = arguments
        }
    }

    func test_theLanguageVersion_followsTheToolsVersion_orTheLatestLanguageMode() async throws {
        let cases = [
            ToolsVersionCase("6.0.0", "null", VersionTuple(6, 2, 1)),
            ToolsVersionCase("5.9.0", "null", VersionTuple(5, 10)),
            ToolsVersionCase("6.0.0", #"["5", "6", "4.2"]"#, VersionTuple(6, 2, 1)),
            ToolsVersionCase("6.0.0", #"["4.2", "5"]"#, VersionTuple(5, 10)),
        ]
        for manifest in cases {
            describingModes(toolsVersion: manifest.toolsVersion, modes: manifest.modes)

            let conditions = try await conditions()

            XCTAssertEqual(
                conditions.everyTarget.language,
                manifest.expected,
                "\(manifest.toolsVersion) \(manifest.modes)"
            )
        }
    }

    func test_aTargetsOwnMode_counts_andTargetsInDifferentModes_leaveItUnknown() async throws {
        let five = #"[{"tool": "swift", "kind": {"swiftLanguageMode": {"_0": "5"}}}]"#
        describingModes(toolsVersion: "6.0.0", lib: five, tests: five)
        let bothInFive = try await conditions()
        describingModes(toolsVersion: "6.0.0", lib: five)
        let oneInFive = try await conditions()

        XCTAssertEqual(bothInFive.everyTarget.language, VersionTuple(5, 10))
        XCTAssertNil(oneInFive.everyTarget.language)
    }

    func test_aModeSettingForAnotherConfiguration_isLeftOut() async throws {
        describingModes(
            toolsVersion: "6.0.0",
            lib: #"[{"tool": "swift", "kind": {"swiftLanguageMode": {"_0": "5"}}, "condition": {"config": "release"}}]"#
        )

        let conditions = try await conditions()

        XCTAssertEqual(conditions.everyTarget.language, VersionTuple(6, 2, 1))
    }

    func test_theLanguageVersion_isUnknown_whenAModeCantBeTold() async throws {
        let cases = [
            // One a trait sets, one that is flags, and one SwiftMutator can't read.
            UntellableMode(
                "null",
                #"[{"tool": "swift", "kind": {"swiftLanguageMode": {"_0": "5"}}, "condition": {"traits": ["T"]}}]"#,
                ["test"]
            ),
            UntellableMode(
                "null",
                #"[{"tool": "swift", "kind": {"unsafeFlags": {"_0": ["-swift-version", "5"]}}}]"#,
                ["test"]
            ),
            UntellableMode("null", #"[{"tool": "swift", "kind": {"swiftLanguageMode": {"_0": {"v": 5}}}}]"#, ["test"]),
            UntellableMode(
                "null",
                #"[{"tool": "swift", "kind": {"futureLanguageModeSetting": {"_0": "5"}}}]"#,
                ["test"]
            ),
            UntellableMode("null", "[]", ["test", "-Xswiftc", "-swift-version", "-Xswiftc", "5"]),
            UntellableMode(#"["5", "7"]"#, "[]", ["test"]),
        ]
        for mode in cases {
            describingModes(toolsVersion: "6.0.0", modes: mode.modes, lib: mode.lib)

            let conditions = try await conditions(arguments: mode.arguments)

            XCTAssertNil(conditions.everyTarget.language, "\(mode.modes) \(mode.lib) \(mode.arguments)")
        }
    }

    // SwiftPM builds a plugin in its tools version's mode, whatever `swiftLanguageModes` says.
    func test_aPlugin_buildsInItsToolsVersionsMode() async throws {
        describingModes(toolsVersion: "5.10.0", modes: #"["5"]"#, plugin: true)
        let allInFive = try await conditions()
        describingModes(toolsVersion: "6.0.0", modes: #"["5"]"#, plugin: true)
        let pluginInSix = try await conditions()
        describingModes(toolsVersion: "5.10.0", modes: #"["5"]"#, plugin: true)
        let withToolFlags = try await conditions(arguments: ["test", "-Xbuild-tools-swiftc", "-DTOOL"])

        XCTAssertEqual(allInFive.everyTarget.language, VersionTuple(5, 10))
        XCTAssertNil(pluginInSix.everyTarget.language)
        XCTAssertNil(withToolFlags.everyTarget.language)
    }

    // SwiftPM takes `-Xswiftc=FLAG` as `-Xswiftc FLAG`.
    func test_joinedXswiftcFlags_count() async throws {
        describingModes(toolsVersion: "6.0.0")

        let conditions = try await conditions(arguments: [
            "test", "-Xswiftc=-DJOINED", "-Xswiftc=-swift-version", "-Xswiftc=5",
        ])

        XCTAssertTrue(conditions.everyTarget.customConditions.allSatisfy { $0.contains("JOINED") })
        XCTAssertNil(conditions.everyTarget.language)
    }

    func test_theLanguageVersion_isUnknown_withoutTheCompilersVersion() async throws {
        describingModes(toolsVersion: "6.0.0", printsAVersion: false)

        let conditions = try await conditions()

        XCTAssertNil(conditions.everyTarget.language)
    }
}
