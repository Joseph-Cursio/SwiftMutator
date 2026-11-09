@testable import muterCore
import SwiftIfConfig
import XCTest

/// A Swift package's scheme under xcodebuild, whose settings `-showBuildSettings` doesn't report.
final class PackageSchemeBuildConditionsTests: MuterTestCase {
    private let swift = "/Xcode/Toolchain/usr/bin/swift"
    private var project = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        current.fileManager = FileManager.default
        project = try makeTemporaryDirectory()
        try write("// swift-tools-version:6.0", to: "Package.swift")
        try write("public let lib = 1", to: "Sources/Lib/Lib.swift")
    }

    // As an Xcode 27.2 build of a package's scheme compiles its targets: the manifest's conditions for the
    // destination's platform, `DEBUG` in a debug build, `SWIFT_PACKAGE`, and `Xcode`.
    func test_aPackagesScheme_getsItsManifestsConditions_forTheDestinationsPlatform() async throws {
        stubPackage()

        let conditions = try await conditions(arguments: [
            "-scheme", "P-Package", "-configuration", "Debug", "-destination", "platform=iOS Simulator,name=iPhone 17",
            "test",
        ])

        XCTAssertEqual(
            conditions.everyTarget.customConditions,
            [["DEBUG", "SWIFT_PACKAGE", "Xcode", "FROM_MANIFEST", "ONLY_IOS"]]
        )
        XCTAssertEqual(conditions.everyTarget.platform?.system, "iOS")
        XCTAssertEqual(conditions.everyTarget.platform?.environment, "simulator")
        XCTAssertNil(conditions.everyTarget.platform?.architectures)
        XCTAssertEqual(conditions.everyTarget.compiler, VersionTuple(6, 4, 2))
        XCTAssertEqual(conditions.everyTarget.language, VersionTuple(6, 4, 2))
        XCTAssertEqual(
            conditions.customConditionsOfFile["Sources/Lib/Lib.swift"],
            [["DEBUG", "SWIFT_PACKAGE", "Xcode", "FROM_MANIFEST", "ONLY_IOS"]]
        )
        XCTAssertTrue(process.commandsRun.contains(["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]))
    }

    func test_aReleaseBuild_doesntSetDEBUG_andAMacDestinationTheMacsConditions() async throws {
        stubPackage()

        let conditions = try await conditions(arguments: [
            "-scheme", "P-Package", "-configuration", "Release", "-destination", "platform=macOS,arch=arm64", "test",
        ])

        XCTAssertEqual(
            conditions.everyTarget.customConditions,
            [["SWIFT_PACKAGE", "Xcode", "FROM_MANIFEST", "ONLY_MAC"]]
        )
        XCTAssertEqual(conditions.everyTarget.platform?.architectures, ["arm64"])
    }

    // Without a platform, a define for one is undecided, as `#if os(…)` is.
    func test_withoutADestinationItCanRead_platformConditionsAreUndecided() async throws {
        stubPackage()

        let conditions = try await conditions(arguments: [
            "-scheme", "P-Package", "-configuration", "Debug", "-destination", "id=00008110-001A2B3C4D5E", "test",
        ])

        XCTAssertNil(conditions.everyTarget.platform)
        XCTAssertTrue(conditions.everyTarget.undecidedConditions.isSuperset(of: ["ONLY_IOS", "ONLY_MAC"]))
    }

    func test_aToolchainTheCommandOrTheEnvironmentPicks_leavesTheCompilerUnknown() async throws {
        let cases: [(arguments: [String], environment: [String: String])] = [
            (["-toolchain", "swift"], [:]),
            ([], ["TOOLCHAINS": "org.swift.64202510201a"]),
            ([], ["SWIFT_EXEC": "/opt/swift/bin/swiftc"]),
        ]
        for (arguments, environment) in cases {
            stubPackage()

            let conditions = try await result(
                arguments: ["-scheme", "P-Package", "-configuration", "Debug"] + arguments + ["test"],
                environment: environment
            ).get()

            XCTAssertNil(conditions.everyTarget.compiler, "\(arguments) \(environment)")
            XCTAssertNil(conditions.everyTarget.language, "\(arguments) \(environment)")
        }
        stubPackage()
        let xcodesOwn = try await result(
            arguments: ["-scheme", "P-Package", "-configuration", "Debug", "test"],
            environment: ["TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault"]
        ).get()
        XCTAssertEqual(xcodesOwn.everyTarget.compiler, VersionTuple(6, 4, 2))
    }

    // An xcodebuild in an Xcode's Developer folder runs that Xcode, whatever `DEVELOPER_DIR` or `xcode-select` says,
    // so its `swift` and SDKs are that Xcode's.
    func test_anXcodesOwnXcodebuild_readsTheManifestWithThatXcodesSwift() async throws {
        stubPackage()
        let developer = "/Applications/Xcode-beta.app/Contents/Developer"

        let conditions = try await result(
            arguments: ["-scheme", "P-Package", "-configuration", "Debug", "-destination", "platform=macOS", "test"],
            executable: developer + "/usr/bin/xcodebuild"
        ).get()

        XCTAssertEqual(conditions.everyTarget.compiler, VersionTuple(6, 4, 2))
        let env = ["/usr/bin/env", "DEVELOPER_DIR=" + developer, "/usr/bin/xcrun"]
        XCTAssertTrue(process.commandsRun.contains(env + ["--find", "swift"]))
        XCTAssertTrue(process.commandsRun.contains(env + ["--sdk", "macosx", "--show-sdk-path"]))
        XCTAssertFalse(process.commandsRun.contains { $0.first == "/usr/bin/xcrun" })
    }

    // A script that runs xcodebuild may give it a configuration, build settings or a destination of its own; another
    // xcodebuild may run any Xcode.
    func test_anExecutableThatIsntAnXcodesXcodebuild_isAFailure() async throws {
        for (executable, reason) in [
            ("/repo/scripts/test.sh", "xcodebuild reported no build settings"),
            ("/opt/tools/bin/xcodebuild", "can't tell which Xcode"),
        ] {
            stubPackage()

            let result = await result(
                arguments: ["-scheme", "P-Package", "-configuration", "Debug", "test"],
                executable: executable
            )

            guard case let .failure(failure) = result else {
                XCTFail("\(executable): \(result)")
                continue
            }
            XCTAssertTrue(failure.reason.contains(reason), failure.reason)
        }
    }

    // Xcode builds a macro and a plugin's tools for the Mac, whatever the destination, and SwiftMutator doesn't tell
    // which files they and what they depend on are.
    func test_withAMacroOrAPlugin_onlyTheMacsOwnPlatformIsDecided() async throws {
        for type in ["macro", "plugin"] {
            stubPackage(alsoDeclaring: type)
            let forIOS = try await conditions(arguments: [
                "-scheme", "P-Package", "-configuration", "Debug", "-destination", "platform=iOS Simulator,name=A",
                "test",
            ])
            let forAnotherArchitecture = try await conditions(arguments: [
                "-scheme", "P-Package", "-configuration", "Debug", "-destination", "platform=macOS,arch=x86_64",
                "test",
            ])
            let forTheMac = try await conditions(arguments: [
                "-scheme", "P-Package", "-configuration", "Debug", "-destination", "platform=macOS", "test",
            ])

            XCTAssertNil(forIOS.everyTarget.platform, type)
            XCTAssertTrue(forIOS.everyTarget.undecidedConditions.isSuperset(of: ["ONLY_IOS", "ONLY_MAC"]), type)
            XCTAssertNil(forAnotherArchitecture.everyTarget.platform, type)
            XCTAssertEqual(forTheMac.everyTarget.platform?.system, "macOS", type)
        }
    }

    // xcodebuild opens a project or workspace beside the manifest before the package, and `-project`'s or
    // `-workspace`'s; their settings are missing for another reason.
    func test_withAProjectOrWorkspace_noSettingsIsStillAFailure() async throws {
        stubPackage()
        try write("", to: "App.xcodeproj/project.pbxproj")
        let besideAProject = await result(arguments: ["-scheme", "P-Package", "test"])
        project = try makeTemporaryDirectory()
        try write("// swift-tools-version:6.0", to: "Package.swift")
        let namingOne = await result(arguments: ["-workspace", "W.xcworkspace", "-scheme", "P", "test"])

        for result in [besideAProject, namingOne] {
            XCTAssertEqual(
                result,
                .failure(BuildConditionsUnavailable(reason: "xcodebuild reported no build settings"))
            )
        }
    }

    // What the manifest says may then not be what the build compiles with.
    func test_buildSettingsTheManifestDoesntHave_areAFailure() async throws {
        let cases: [(arguments: [String], environment: [String: String], reason: String)] = [
            (["-scheme", "P-Package", "OTHER_SWIFT_FLAGS=-DFOO", "test"], [:], "sets build settings"),
            (["-scheme", "P-Package", "-xcconfig", "/ci/Overrides.xcconfig", "test"], [:], "an `.xcconfig`"),
            (["-scheme", "P-Package", "test"], ["XCODE_XCCONFIG_FILE": "/ci/Overrides.xcconfig"], "an `.xcconfig`"),
            (["-scheme", "P-Package", "-configuration", "Beta", "test"], [:], "another configuration"),
            (["-scheme", "P-Package", "test"], [:], "give it with `-configuration`"),
        ] + [
            "OTHER_SWIFT_FLAGS", "OTHER_SWIFT_FLAGS_Debug", "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "SWIFT_VERSION",
            "ARCHS", "SDKROOT",
        ].map { name in
            (["-scheme", "P-Package", "-configuration", "Debug", "test"], [name: "-DFOO"], "environment sets \(name)")
        }
        for (arguments, environment, reason) in cases {
            stubPackage()

            let result = await result(arguments: arguments, environment: environment)

            guard case let .failure(failure) = result else {
                XCTFail("\(arguments) \(environment): \(result)")
                continue
            }
            XCTAssertTrue(failure.reason.contains(reason), failure.reason)
        }
    }

    func test_theDestinationsPlatform() {
        let read: (String) -> String? = { value in
            PackageSchemeBuildConditions.destination(in: ["-destination", value]).map {
                "\($0.system) \($0.environment ?? "-") \($0.sdk) \($0.architectures?.sorted().joined() ?? "-")"
            }
        }

        XCTAssertEqual(read("platform=iOS Simulator,name=iPhone 17,OS=latest"), "iOS simulator iphonesimulator -")
        XCTAssertEqual(read("generic/platform=iOS"), "iOS - iphoneos -")
        XCTAssertEqual(read("platform=macOS,arch=x86_64"), "macOS - macosx x86_64")
        XCTAssertEqual(read("platform=visionOS Simulator,name=Apple Vision Pro"), "visionOS simulator xrsimulator -")
        XCTAssertNil(read("platform=macOS,variant=Mac Catalyst"))
        XCTAssertNil(read("platform=macOS,variant=Designed for [iPad,iPhone]"))
        XCTAssertNil(read("id=00008110-001A2B3C4D5E"))
        XCTAssertNil(read("platform=Linux"))
        XCTAssertNil(PackageSchemeBuildConditions.destination(in: [
            "-destination", "platform=macOS", "-destination", "platform=iOS Simulator,name=iPhone 17",
        ]))
    }

    // MARK: Helpers

    /// A package with a library, whose manifest defines `FROM_MANIFEST`, and `ONLY_IOS` and `ONLY_MAC` for those
    /// platforms, and its tests; xcodebuild with no settings for its scheme, and a toolchain of Swift 6.4.2.
    private func stubPackage(alsoDeclaring otherType: String? = nil) {
        let manifest = otherType.map {
            manifest.replacingOccurrences(
                of: #"{"name": "LibTests""#,
                with: #"{"name": "Other", "type": "\#($0)", "settings": []}, {"name": "LibTests""#
            )
        } ?? manifest
        process.commandResult = { [self] command in
            // As `xcrun` finds the tools of an Xcode `DEVELOPER_DIR` names.
            let command = command.first == "/usr/bin/env" ? Array(command.dropFirst(2)) : command
            switch command {
            case _ where command.last == "-json" && command.contains("-showBuildSettings"):
                return success("[\n\n]\n")
            case ["/usr/bin/xcrun", "--find", "swift"]:
                return success(swift + "\n")
            case [swift, "--version"]:
                return success("Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)\n")
            case _ where command.first == swift && command.contains("describe"):
                return success(packageDescription)
            case _ where command.first == swift && command.last == "dump-package":
                return success(manifest)
            default:
                return nil
            }
        }
    }

    private var packageDescription: String {
        """
        {"name": "P", "path": "\(project)", "dependencies": [], "targets": [
            {"name": "Lib", "type": "library", "path": "Sources/Lib", "sources": ["Lib.swift"]},
            {"name": "LibTests", "type": "test", "path": "Tests/LibTests", "sources": ["LibTests.swift"]}
        ]}
        """
    }

    private let manifest = """
    {"toolsVersion": {"_version": "6.0.0"}, "swiftLanguageVersions": null, "targets": [
        {"name": "Lib", "type": "regular", "settings": [
            {"tool": "swift", "kind": {"define": {"_0": "FROM_MANIFEST"}}},
            {"tool": "swift", "kind": {"define": {"_0": "ONLY_IOS"}}, "condition": {"platformNames": ["ios"]}},
            {"tool": "swift", "kind": {"define": {"_0": "ONLY_MAC"}}, "condition": {"platformNames": ["macos"]}}
        ]},
        {"name": "LibTests", "type": "test", "settings": []}
    ]}
    """

    private func success(_ output: String) -> CommandResult {
        CommandResult(status: 0, endedBySignal: false, output: output, errors: "")
    }

    private func result(
        arguments: [String],
        environment: [String: String] = [:],
        executable: String = "/usr/bin/xcodebuild"
    ) async -> Result<ProjectBuildConditions, BuildConditionsUnavailable> {
        await XcodeBuildConditions.conditions(
            inProjectAt: project,
            testedBy: MuterConfiguration(executable: executable, arguments: arguments),
            process: current.process,
            fileManager: FileManager.default,
            environment: environment
        )
    }

    private func conditions(arguments: [String]) async throws -> ProjectBuildConditions {
        try await result(arguments: arguments).get()
    }

    private func write(_ contents: String, to path: String) throws {
        let url = URL(fileURLWithPath: project + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
