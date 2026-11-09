@testable import muterCore
import SwiftIfConfig
import XCTest

/// A Swift package's scheme under xcodebuild, whose settings `-showBuildSettings` doesn't report.
final class PackageSchemeBuildConditionsTests: MuterTestCase {
    private let xcodebuild = "/usr/bin/xcodebuild"
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
            "-scheme", "P-Package", "-destination", "platform=iOS Simulator,name=iPhone 17", "test",
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
            "-scheme", "P-Package", "-destination", "id=00008110-001A2B3C4D5E", "test",
        ])

        XCTAssertNil(conditions.everyTarget.platform)
        XCTAssertTrue(conditions.everyTarget.undecidedConditions.isSuperset(of: ["ONLY_IOS", "ONLY_MAC"]))
    }

    func test_aToolchainTheCommandPicks_leavesTheCompilerUnknown() async throws {
        stubPackage()

        let conditions = try await conditions(arguments: ["-scheme", "P-Package", "-toolchain", "swift", "test"])

        XCTAssertNil(conditions.everyTarget.compiler)
        XCTAssertNil(conditions.everyTarget.language)
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
        ]
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

    // Its test action may build another configuration than Debug.
    func test_aSchemeOfThePackagesOwn_needsTheConfigurationGiven() async throws {
        stubPackage()
        try write("<Scheme/>", to: ".swiftpm/xcode/xcshareddata/xcschemes/P-Package.xcscheme")

        let withoutIt = await result(arguments: ["-scheme", "P-Package", "test"])
        let withIt = await result(arguments: ["-scheme", "P-Package", "-configuration", "Debug", "test"])

        guard case let .failure(failure) = withoutIt else { return XCTFail("\(withoutIt)") }
        XCTAssertTrue(failure.reason.contains("give it with `-configuration`"), failure.reason)
        XCTAssertNotNil(try? withIt.get())
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
    private func stubPackage() {
        process.commandResult = { [self] command in
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
        environment: [String: String] = [:]
    ) async -> Result<ProjectBuildConditions, BuildConditionsUnavailable> {
        await XcodeBuildConditions.conditions(
            inProjectAt: project,
            testedBy: MuterConfiguration(executable: xcodebuild, arguments: arguments),
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
