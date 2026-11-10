@testable import muterCore
import SwiftIfConfig
import XCTest

final class SwiftPackageBuildConditionsTests: MuterTestCase {
    let swift = "/path/to/swift"
    let project = "/project"

    func test_aDebugBuild_setsDEBUGAndSWIFT_PACKAGE() async throws {
        describing(settings: "[]")

        let conditions = try await conditions()

        XCTAssertEqual(conditions.everyTarget.customConditions, [["DEBUG", "SWIFT_PACKAGE"]])
    }

    func test_aReleaseBuild_doesntSetDEBUG() async throws {
        describing(settings: "[]")

        for arguments in [["-c", "release"], ["--configuration", "release"], ["--configuration=release"]] {
            let conditions = try await conditions(arguments: ["test"] + arguments)

            XCTAssertEqual(conditions.everyTarget.customConditions, [["SWIFT_PACKAGE"]], "\(arguments)")
        }
    }

    func test_theManifestsDefinesAndFlags_forSwiftOnly() async throws {
        describing(settings: """
        [
            {"tool": "swift", "kind": {"define": {"_0": "DEFINED"}}},
            {"tool": "swift", "kind": {"unsafeFlags": {"_0": ["-DFROM_FLAG", "-O", "-D", "SPLIT"]}}},
            {"tool": "c", "kind": {"define": {"_0": "FOR_C"}}},
            {"tool": "swift", "kind": {"enableUpcomingFeature": {"_0": "ExistentialAny"}}}
        ]
        """)

        let conditions = try await conditions()

        XCTAssertEqual(
            conditions.everyTarget.customConditions,
            [["DEBUG", "SWIFT_PACKAGE", "DEFINED", "FROM_FLAG", "SPLIT"]]
        )
    }

    func test_aDefineForAConfiguration_appliesOnlyInIt() async throws {
        describing(settings: """
        [
            {"tool": "swift", "kind": {"define": {"_0": "IN_DEBUG"}}, "condition": {"config": "debug"}},
            {"tool": "swift", "kind": {"define": {"_0": "IN_RELEASE"}}, "condition": {"config": "release"}}
        ]
        """)

        let conditions = try await conditions()

        XCTAssertEqual(conditions.everyTarget.customConditions, [["DEBUG", "SWIFT_PACKAGE", "IN_DEBUG"]])
    }

    func test_aDefineForAPlatform_appliesOnlyOnIt() async throws {
        let host = hostPlatform
        describing(settings: """
        [
            {"tool": "swift", "kind": {"define": {"_0": "HERE"}}, "condition": {"platformNames": ["\(host)"]}},
            {"tool": "swift", "kind": {"define": {"_0": "THERE"}}, "condition": {"platformNames": ["windows"]}},
            {"tool": "swift", "kind": {"define": {"_0": "ALWAYS"}}, "condition": {"platformNames": []}}
        ]
        """)

        let conditions = try await conditions()

        XCTAssertEqual(conditions.everyTarget.customConditions, [["DEBUG", "SWIFT_PACKAGE", "HERE", "ALWAYS"]])
        XCTAssertFalse(conditions.everyTarget.undecidedConditions.contains("THERE"))
    }

    // Which traits are on can be set by whatever depends on the package.
    func test_aTraitsName_andADefineATraitEnables_areUndecided() async throws {
        describing(
            settings: """
            [{"tool": "swift", "kind": {"define": {"_0": "WITH_TRAIT"}}, "condition": {"traits": ["SomeTrait"]}}]
            """,
            traits: #"[{"name": "SomeTrait", "enabledTraits": []}]"#
        )

        let conditions = try await conditions()

        XCTAssertTrue(conditions.everyTarget.undecidedConditions.isSuperset(of: ["WITH_TRAIT", "SomeTrait"]))
        XCTAssertEqual(conditions.everyTarget.customConditions, [["DEBUG", "SWIFT_PACKAGE"]])
    }

    func test_dashXswiftcFlags_applyToEveryTarget() async throws {
        describing(settings: "[]")

        let conditions = try await conditions(arguments: [
            "test", "-Xswiftc", "-DGLUED", "-Xswiftc", "-D", "-Xswiftc", "SPLIT", "-Xcc", "-DFOR_C",
            "-Xswiftc", "-Xcc", "-Xswiftc", "-DPASSED_TO_C",
        ])

        XCTAssertEqual(conditions.everyTarget.customConditions, [["DEBUG", "SWIFT_PACKAGE", "GLUED", "SPLIT"]])
    }

    func test_eachFile_getsItsTargetsConditions() async throws {
        describingTwoTargets()

        let conditions = try await conditions()

        XCTAssertEqual(
            conditions.customConditionsOfFile["Sources/App/App.swift"],
            [["DEBUG", "SWIFT_PACKAGE", "FOR_APP"]]
        )
        XCTAssertEqual(
            conditions.customConditionsOfFile["Sources/Lib/Lib.swift"],
            [["DEBUG", "SWIFT_PACKAGE", "FOR_LIB"]]
        )
        XCTAssertEqual(conditions.everyTarget.customConditions.count, 2)
    }

    func test_theHostsPlatform() async throws {
        describing(settings: "[]")

        let platform = try await conditions().everyTarget.platform

        XCTAssertEqual(platform?.system.lowercased(), hostPlatform)
    }

    func test_crossCompiling_isNoPlatform_andLeavesADefineForAPlatformUndecided() async throws {
        describing(settings: """
        [{"tool": "swift", "kind": {"define": {"_0": "ON_IOS"}}, "condition": {"platformNames": ["ios"]}}]
        """)

        for option in ["--triple", "--arch", "--swift-sdk", "--experimental-swift-sdk", "--destination", "--sdk"] {
            let conditions = try await conditions(arguments: ["test", option, "x"]).everyTarget

            XCTAssertNil(conditions.platform, option)
            XCTAssertTrue(conditions.undecidedConditions.contains("ON_IOS"), option)
        }
        let joined = try await conditions(arguments: ["test", "--triple=x"]).everyTarget
        XCTAssertNil(joined.platform)
    }

    // `--files-to-mutate` can name a test's file, which no target under test holds.
    func test_aTestTargetsDefine_isUndecided() async throws {
        describing(settings: "[]")

        let conditions = try await conditions().everyTarget

        XCTAssertTrue(conditions.undecidedConditions.contains("ONLY_FOR_TESTS"))
        XCTAssertFalse(conditions.undecidedConditions.contains("DEBUG"))
    }

    func test_dumpPackageFailing_isAFailure() async {
        process.commandResult = { [self] command in
            command.contains("describe") ? success(description()) : nil
        }

        let result = await conditionsResult()

        XCTAssertEqual(result, .failure(BuildConditionsUnavailable(
            reason: "`swift package dump-package` gave nothing it could read for /project"
        )))
    }

    // Kept apart from a target with no settings, whose conditions would then be decided wrongly.
    func test_aTargetTheManifestDoesntHold_isAFailure() async {
        process.commandResult = { [self] command in
            command.contains("describe") ? success(description()) : success(#"{"targets": []}"#)
        }

        let result = await conditionsResult()

        XCTAssertEqual(result, .failure(BuildConditionsUnavailable(
            reason: "`swift package dump-package` gave nothing it could read for /project"
        )))
    }

    func test_aSettingInAnOlderFormat_isAFailure() async {
        describing(settings: #"[{"tool": "swift", "name": "define", "value": ["OLD"]}]"#)

        let result = await conditionsResult()

        if case .success = result {
            XCTFail("Took an unread setting for no setting")
        }
    }

    func test_describeFailing_isAFailure_withItsReason() async {
        process.commandResult = { _ in nil }

        let result = await conditionsResult()

        XCTAssertEqual(result, .failure(BuildConditionsUnavailable(reason: "\(swift) couldn't be started")))
    }

    // MARK: Helpers

    /// A package of tools version `toolsVersion` with `swiftLanguageModes` `modes`, its targets' settings `lib` and
    /// `tests`, and `swift --version` printing 6.2.1, if `printsAVersion`.
    func describingModes(
        toolsVersion: String,
        modes: String = "null",
        lib: String = "[]",
        tests: String = "[]",
        plugin: Bool = false,
        printsAVersion: Bool = true
    ) {
        let pluginTarget = plugin ? #", {"name": "Plug", "type": "plugin", "settings": []}"# : ""
        process.commandResult = { [self] command in
            if command == [swift, "--version"] {
                return printsAVersion ? success("Swift version 6.2.1 (swift-6.2.1-RELEASE)\n") : nil
            }
            if command.contains("describe") {
                return success(description())
            }
            return success("""
            {"toolsVersion": {"_version": "\(toolsVersion)"}, "swiftLanguageVersions": \(modes), "targets": [
                {"name": "Lib", "settings": \(lib)},
                {"name": "LibTests", "settings": \(tests)}\(pluginTarget)
            ]}
            """)
        }
    }

    /// A package with one target, and `swift --version` printing 6.2.1.
    func describingWithVersion() {
        describing(settings: "[]")
        let described = process.commandResult
        process.commandResult = { [self] command in
            guard command == [swift, "--version"] else { return described(command) }
            return success("Swift version 6.2.1 (swift-6.2.1-RELEASE)\n")
        }
    }

    var hostPlatform: String {
        #if os(macOS)
        "macos"
        #else
        "linux"
        #endif
    }

    func success(_ output: String) -> CommandResult {
        CommandResult(status: 0, endedBySignal: false, output: output, errors: "")
    }

    func description() -> String {
        """
        {"name": "P", "path": "\(project)", "dependencies": [], "targets": [
            {"name": "Lib", "type": "library", "path": "Sources/Lib", "sources": ["Lib.swift"]},
            {"name": "LibTests", "type": "test", "path": "Tests/LibTests", "sources": ["LibTests.swift"]}
        ]}
        """
    }

    func describing(settings: String, traits: String = "null") {
        process.commandResult = { [self] command in
            if command.contains("describe") {
                return success(description())
            }
            return success("""
            {"traits": \(traits), "targets": [
                {"name": "Lib", "settings": \(settings)},
                {"name": "LibTests", "settings": [{"tool": "swift", "kind": {"define": {"_0": "ONLY_FOR_TESTS"}}}]}
            ]}
            """)
        }
    }

    func describingTwoTargets() {
        process.commandResult = { [self] command in
            if command.contains("describe") {
                return success("""
                {"name": "P", "path": "\(project)", "dependencies": [], "targets": [
                    {"name": "App", "type": "executable", "path": "Sources/App", "sources": ["App.swift"]},
                    {"name": "Lib", "type": "library", "path": "Sources/Lib", "sources": ["Lib.swift"]}
                ]}
                """)
            }
            return success("""
            {"targets": [
                {"name": "App", "settings": [{"tool": "swift", "kind": {"define": {"_0": "FOR_APP"}}}]},
                {"name": "Lib", "settings": [{"tool": "swift", "kind": {"define": {"_0": "FOR_LIB"}}}]}
            ]}
            """)
        }
    }

    func conditionsResult(
        arguments: [String] = ["test"],
        environment: [String: String] = [:]
    ) async -> Result<ProjectBuildConditions, BuildConditionsUnavailable> {
        await SwiftPackageBuildConditions.conditions(
            inProjectAt: project,
            testedBy: MuterConfiguration(executable: swift, arguments: arguments),
            process: current.process,
            fileManager: FileManager.default,
            environment: environment
        )
    }

    func conditions(
        arguments: [String] = ["test"],
        environment: [String: String] = [:]
    ) async throws -> ProjectBuildConditions {
        try await conditionsResult(arguments: arguments, environment: environment).get()
    }
}
