@testable import muterCore
import XCTest

/// Which targets compiled each file in an xcodebuild build, from the lists of files the build leaves in derived data.
final class XcodeFileListsTests: MuterTestCase {
    private let xcodebuild = "/usr/bin/xcodebuild"
    private var project = ""
    private var objectRoot = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        current.fileManager = FileManager.default
        project = try makeTemporaryDirectory()
        objectRoot = project + "/DerivedData/Build/Intermediates.noindex"
        for file in ["App/App.swift", "App/My View.swift", "Shared/Shared.swift", "Core/Core.swift", "Tests/T.swift"] {
            try write("let x = 1", to: project + "/" + file)
        }
        // A Release-only flag, and the flags of the framework the app embeds, which xcodebuild doesn't report.
        try write(
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS = RELEASE_ONLY CORE_FLAG",
            to: project + "/P.xcodeproj/project.pbxproj"
        )
    }

    // The app's own files are compiled by the app alone; a file the embedded framework compiles too may be built with
    // its conditions, which xcodebuild doesn't report.
    func test_aFileOnlyReportedTargetsCompiled_getsAllTheirConditions() async throws {
        try writeTheBuildsLists()

        let conditions = try await conditions(afterABuild: true)

        let app = conditions.conditions(ofFile: "App/App.swift")
        XCTAssertTrue(try XCTUnwrap(holds("APP_FLAG", in: app)))
        XCTAssertFalse(try XCTUnwrap(holds("RELEASE_ONLY", in: app)))
        XCTAssertFalse(try XCTUnwrap(holds("CORE_FLAG", in: app)))
        XCTAssertFalse(try XCTUnwrap(holds("TEST_FLAG", in: app)))
        XCTAssertFalse(try XCTUnwrap(holds("RELEASE_ONLY", in: conditions.conditions(ofFile: "App/My View.swift"))))
        XCTAssertNil(holds("CORE_FLAG", in: conditions.conditions(ofFile: "Shared/Shared.swift")))
        XCTAssertNil(holds("RELEASE_ONLY", in: conditions.conditions(ofFile: "Shared/Shared.swift")))
        XCTAssertNil(conditions.customConditionsOfFile["Core/Core.swift"])
        // A name starting with SWIFT_ may be one Xcode sets itself.
        XCTAssertNil(holds("SWIFT_PACKAGE", in: app))
    }

    // Without a build, a list may be an earlier build's.
    func test_withoutABuild_noFileGetsItsTargets() async throws {
        try writeTheBuildsLists()

        let conditions = try await conditions(afterABuild: false)

        XCTAssertTrue(conditions.customConditionsOfFile.isEmpty)
        XCTAssertNil(holds("RELEASE_ONLY", in: conditions.conditions(ofFile: "App/App.swift")))
    }

    // A list from an earlier build of another configuration is no reported target's, and its files are left alone.
    func test_aListOfAnotherConfiguration_leavesItsFilesAlone() async throws {
        try writeTheBuildsLists()
        try writeList("P.build/Release/App.build/Objects-normal/arm64/App.SwiftFileList", files: ["App/App.swift"])

        let conditions = try await conditions(afterABuild: true)

        XCTAssertNil(holds("RELEASE_ONLY", in: conditions.conditions(ofFile: "App/App.swift")))
        XCTAssertFalse(try XCTUnwrap(holds("RELEASE_ONLY", in: conditions.conditions(ofFile: "App/My View.swift"))))
    }

    // xcodebuild spells a project in /private/var as /var, and a package's lists keep /private.
    func test_aFileSpelledAnotherWay_isTheSameFile() async throws {
        try writeTheBuildsLists()
        let otherSpelling = project.hasPrefix("/private/")
            ? String(project.dropFirst("/private".count))
            : project.canonicalPath
        try write(
            otherSpelling + "/App/App.swift\n",
            to: objectRoot + "/Pkg.build/Debug/Lib-t.build/Objects-normal/arm64/Lib.SwiftFileList"
        )

        let conditions = try await conditions(afterABuild: true)

        XCTAssertNil(holds("RELEASE_ONLY", in: conditions.conditions(ofFile: "App/App.swift")))
    }

    func test_whatMayCompileOutOfSight_leavesEveryFileAlone() async throws {
        let buildFiles: [(path: String, text: String)] = [
            ("P.xcodeproj/project.pbxproj", #""SWIFT_ACTIVE_COMPILATION_CONDITIONS[arch=arm64]" = ARM;"#),
            ("P.xcodeproj/project.pbxproj", "isa = PBXLegacyTarget;"),
            ("P.xcodeproj/project.pbxproj", "lastKnownFileType = \"wrapper.pb-project\"; path = ../Other.xcodeproj;"),
            ("P.xcodeproj/project.pbxproj", "shellScript = \"xcrun swiftc Gen.swift\";"),
            ("Configs/Base.xcconfig", "TARGET_TEMP_DIR = /elsewhere"),
            ("Configs/Base.xcconfig", "OBJECT_FILE_DIR_normal = /elsewhere"),
            ("W.xcworkspace/contents.xcworkspacedata", #"<FileRef location = "group:../Other/Other.xcodeproj">"#),
            ("W.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings", "<key>BuildLocationStyle</key>"),
            // Set for each architecture by a reference -showBuildSettings resolves with none.
            ("Configs/Base.xcconfig", "OTHER_SWIFT_FLAGS = $(inherited) $(NEON_FLAGS_$(CURRENT_ARCH))"),
            ("Configs/Base.xcconfig", "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) $(FLAGS_$(arch))"),
            // A Run Script phase that runs a script that compiles, outside the project, or that isn't there.
            ("P.xcodeproj/project.pbxproj", #"shellScript = "\"${SRCROOT}/Scripts/compile.sh\"\n";"#),
            ("P.xcodeproj/project.pbxproj", #"shellScript = "\"${SRCROOT}/../Tools/gen.sh\"\n";"#),
            ("P.xcodeproj/project.pbxproj", #"shellScript = "Scripts/missing.py\n";"#),
            // A build configuration file outside the project, which may do any of that.
            ("P.xcodeproj/project.pbxproj", "baseConfigurationReference = 1; path = ../Shared/Base.xcconfig;"),
        ]
        for (path, text) in buildFiles {
            project = try makeTemporaryDirectory()
            objectRoot = project + "/DerivedData/Build/Intermediates.noindex"
            try write("let x = 1", to: project + "/App/App.swift")
            try write("let x = 1", to: project + "/App/My View.swift")
            try write("let x = 1", to: project + "/Shared/Shared.swift")
            try write(text, to: project + "/" + path)
            try write("xcrun swiftc -o gen Gen.swift", to: project + "/Scripts/compile.sh")
            try writeTheBuildsLists()

            let conditions = try await conditions(afterABuild: true)

            XCTAssertTrue(conditions.customConditionsOfFile.isEmpty, "\(path): \(text)")
        }
    }

    // A script the project runs that doesn't compile leaves the lists all that compiles a file.
    func test_aScriptThatDoesntCompile_leavesTheListsToTell() async throws {
        try write(
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS = CORE_FLAG;\n"
                + #"shellScript = "\"${SRCROOT}/Scripts/lint.sh\"\n";"#,
            to: project + "/P.xcodeproj/project.pbxproj"
        )
        try write("swiftlint lint --strict", to: project + "/Scripts/lint.sh")
        try writeTheBuildsLists()

        let conditions = try await conditions(afterABuild: true)

        XCTAssertFalse(try XCTUnwrap(holds("CORE_FLAG", in: conditions.conditions(ofFile: "App/App.swift"))))
    }

    // `-xcconfig` and `XCODE_XCCONFIG_FILE` name a build configuration file outside the project's build files.
    func test_aBuildConfigurationFileTheCommandNames_leavesEveryFileAlone() async throws {
        try writeTheBuildsLists()

        let named = try await conditions(afterABuild: true, extraArguments: ["-xcconfig", "/ci/Extra.xcconfig"])
        let inTheEnvironment = try await conditions(
            afterABuild: true,
            environment: ["XCODE_XCCONFIG_FILE": "/ci/Extra.xcconfig"]
        )

        XCTAssertTrue(named.customConditionsOfFile.isEmpty)
        XCTAssertTrue(inTheEnvironment.customConditionsOfFile.isEmpty)
    }

    func test_intermediateFilesOutsideDerivedData_leaveEveryFileAlone() async throws {
        objectRoot = project + "/build"
        try writeTheBuildsLists()

        let conditions = try await conditions(afterABuild: true)

        XCTAssertTrue(conditions.customConditionsOfFile.isEmpty)
    }

    // `customConditions(of:)` doesn't read quotes, escapes, variables or a response file of flags as the compiler
    // would.
    func test_aTargetWhoseFlagsMayHideConditions_isNoReportedTarget() async throws {
        for flags in [#"-D"QUOTED""#, "@/tmp/flags.resp", "-D$(NAME)"] {
            try writeTheBuildsLists(appFlags: flags)

            let conditions = try await conditions(afterABuild: true)

            XCTAssertNil(conditions.customConditionsOfFile["App/App.swift"], flags)
        }
    }

    func test_listsThatDontReadAsXcodeWritesThem_leaveEveryFileAlone() async throws {
        try writeTheBuildsLists()
        try write(
            "App/App.swift\n",
            to: objectRoot + "/P.build/Debug/Core.build/Objects-normal/arm64/Core.SwiftFileList"
        )
        let relative = try await conditions(afterABuild: true)

        try writeTheBuildsLists()
        try FileManager.default.removeItem(atPath: project + "/App/App.swift")
        try FileManager.default.removeItem(atPath: project + "/App/My View.swift")
        try FileManager.default.removeItem(atPath: project + "/Tests/T.swift")
        let nothingThere = try await conditions(afterABuild: true)

        XCTAssertTrue(relative.customConditionsOfFile.isEmpty)
        XCTAssertTrue(nothingThere.customConditionsOfFile.isEmpty)
    }

    func test_aFileListsPaths() {
        XCTAssertEqual(
            XcodeBuildConditions.filePaths(
                inFileList: "/p/My\\ View.swift\n/p/a\\'b\\ \\\"c\\\"\\\\.swift\n\n/p/x.swift\n"
            ),
            ["/p/My View.swift", "/p/a'b \"c\"\\.swift", "/p/x.swift"]
        )
        XCTAssertNil(XcodeBuildConditions.filePaths(inFileList: "p/x.swift\n"))
        XCTAssertNil(XcodeBuildConditions.filePaths(inFileList: "/p/x\\"))
    }

    // MARK: Helpers

    /// The lists an Xcode 27.2 build of the app and its tests leaves: the app's, the tests' and those of the framework
    /// the app embeds, which compiles a file of the app's too; and `-showBuildSettings` reporting the app and its
    /// tests.
    private func writeTheBuildsLists(appFlags: String = "") throws {
        let app = "P.build/Debug/App.build/Objects-normal/arm64/App.SwiftFileList"
        let tests = "P.build/Debug/AppTests.build/Objects-normal/arm64/AppTests.SwiftFileList"
        try writeList(app, files: ["App/App.swift", "App/My View.swift", "Shared/Shared.swift"])
        try writeList(tests, files: ["Tests/T.swift"])
        try writeList(
            "P.build/Debug/Core.build/Objects-normal/arm64/Core.SwiftFileList",
            files: ["Core/Core.swift", "Shared/Shared.swift"]
        )
        let target = ["PLATFORM_NAME": "macosx", "ARCHS": "arm64", "CONFIGURATION": "Debug", "OBJROOT": objectRoot]
        let appSettings = target.merging([
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG APP_FLAG",
            "OTHER_SWIFT_FLAGS": appFlags,
            "SWIFT_RESPONSE_FILE_PATH_normal_arm64": objectRoot + "/" + app,
        ]) { _, new in new }
        let testSettings = target.merging([
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG TEST_FLAG",
            "SWIFT_RESPONSE_FILE_PATH_normal_arm64": objectRoot + "/" + tests,
        ]) { _, new in new }
        process.commandResult = { [self] command in
            result(of: command.contains("test") ? [testSettings] : [appSettings])
        }
    }

    private func writeList(_ path: String, files: [String]) throws {
        let lines = files.map { (project + "/" + $0).replacingOccurrences(of: " ", with: "\\ ") + "\n" }
        try write(lines.joined(), to: objectRoot + "/" + path)
    }

    private func result(of targets: [[String: String]]) -> CommandResult {
        let objects = targets.map { ["action": "test", "target": "T", "buildSettings": $0] as [String: Any] }
        let json = try? JSONSerialization.data(withJSONObject: objects)
        return CommandResult(
            status: 0,
            endedBySignal: false,
            output: json.map { String(lossyUTF8: $0) } ?? "",
            errors: ""
        )
    }

    private func conditions(
        afterABuild: Bool,
        extraArguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws -> ProjectBuildConditions {
        try await XcodeBuildConditions.conditions(
            inProjectAt: project,
            testedBy: MuterConfiguration(
                executable: xcodebuild,
                arguments: ["-scheme", "App"] + extraArguments + ["test"]
            ),
            process: current.process,
            fileManager: FileManager.default,
            environment: environment,
            afterABuild: afterABuild
        ).get()
    }

    /// Whether `name` is set, or nil if it's undecided.
    private func holds(_ name: String, in conditions: BuildConditions) -> Bool? {
        try? conditions.isCustomConditionSet(name: name)
    }

    private func write(_ contents: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
