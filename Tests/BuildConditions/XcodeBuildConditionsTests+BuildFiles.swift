@testable import muterCore
import XCTest

extension XcodeBuildConditionsTests {
    /// A build file SwiftMutator doesn't read, written at `path` with `text`, or named by the test command's
    /// `arguments` or by its `environment`.
    private struct BuildFile {
        let path: String
        let text: String
        let arguments: [String]
        let environment: [String: String]

        init(_ path: String, _ text: String, _ arguments: [String], _ environment: [String: String]) {
            self.path = path
            self.text = text
            self.arguments = arguments
            self.environment = environment
        }
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

    // A build file SwiftMutator didn't read may set a condition for a target xcodebuild didn't report, as a framework
    // the app only depends on, that no build file it read names.
    // It goes by where a file is, not by its name, which an in-project file of the same name may have.
    func test_withABuildFileItDidntRead_aConditionNoTargetSetsIsUndecided() async throws {
        let app = macOSTarget.merging(["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "APP"]) { _, new in new }
        for buildFile in buildFilesItDidntRead() {
            project = try makeTemporaryDirectory()
            try write("", to: "Base.xcconfig")
            try write("", to: "Configs/Base.xcconfig")
            try write(buildFile.text, to: buildFile.path)
            settings(test: [app], build: [])

            let conditions = try await conditions(
                arguments: buildFile.arguments + ["test"],
                environment: buildFile.environment
            )

            XCTAssertThrowsError(
                try conditions.isCustomConditionSet(name: "CORE_ONLY"),
                "\(buildFile.path) \(buildFile.text) \(buildFile.arguments)"
            )
            XCTAssertTrue(try conditions.isCustomConditionSet(name: "APP"))
        }
    }

    /// Build files, or a command or environment that names one, that SwiftMutator doesn't read, each of which may set a
    /// condition for a target xcodebuild didn't report.
    private func buildFilesItDidntRead() -> [BuildFile] {
        let pbxproj = "App.xcodeproj/project.pbxproj"
        let workspace = "W.xcworkspace/contents.xcworkspacedata"
        return [
            BuildFile(pbxproj, projectFile(basedOn: "Base.xcconfig", inGroupAt: "../Shared"), [], [:]),
            BuildFile(pbxproj, projectFile(basedOn: "Configs/Base.xcconfig", inGroupAt: ".."), [], [:]),
            BuildFile(pbxproj, projectFile(basedOn: "Base.xcconfig", sourceTree: "SHARED_CONFIGS"), [], [:]),
            BuildFile(pbxproj, projectFile(basedOn: "$(SRCROOT)/Base.xcconfig"), [], [:]),
            BuildFile(pbxproj, projectFile(basedOn: "Missing.xcconfig"), [], [:]),
            BuildFile(pbxproj, projectBasedOnASynchronizedFolder, [], [:]),
            BuildFile(pbxproj, "baseConfigurationReference = F; path = Base.xcconfig;", [], [:]),
            BuildFile("Configs/App.xcconfig", #"#include "../../My Configs/Base.xcconfig""#, [], [:]),
            BuildFile("Configs/App.xcconfig", #"#include? "<DEVELOPER_DIR>/Base.xcconfig""#, [], [:]),
            BuildFile("Configs/App.xcconfig", #"# include "../../Shared/Base.xcconfig""#, [], [:]),
            BuildFile("Configs/App.xcconfig", "#\tinclude? \"../../Shared/Base.xcconfig\"", [], [:]),
            BuildFile("Configs/App.xcconfig", #"#import "Base.xcconfig""#, [], [:]),
            BuildFile("Configs/App.xcconfig", "PROJECT_DIR = $(SRCROOT)/../Shared", [], [:]),
            BuildFile(pbxproj, "", ["SRCROOT=/elsewhere"], [:]),
            BuildFile(pbxproj, projectWithItsConfigurationFileTwice, [], [:]),
            BuildFile(pbxproj, projectFile(referencingProject: "../Core/Core.xcodeproj"), [], [:]),
            BuildFile(pbxproj, #"lastKnownFileType = "wrapper.pb-project"; path = C.xcodeproj;"#, [], [:]),
            BuildFile(workspace, workspaceFile(#"<FileRef location = "group:../Core/Core.xcodeproj"/>"#), [], [:]),
            BuildFile(
                workspace,
                workspaceFile(#"<Group location = "group:.."><FileRef location = "group:Core/C.xcodeproj"/></Group>"#),
                [],
                [:]
            ),
            BuildFile(workspace, workspaceFile(#"<FileRef location = "absolute:/src/Core.xcodeproj"/>"#), [], [:]),
            BuildFile(workspace, workspaceFile(#"<FileRef location = "developer:Examples/Core.xcodeproj"/>"#), [], [:]),
            BuildFile(workspace, workspaceFile(#"<FileRef location = "group:$(CORE)/Core.xcodeproj"/>"#), [], [:]),
            BuildFile(workspace, workspaceFile(#"<FileRef location = "container:Nested.xcworkspace"/>"#), [], [:]),
            BuildFile(workspace, #"<FileRef location = "group:Core.xcodeproj">"#, [], [:]),
            BuildFile(pbxproj, "", ["-xcconfig", "/ci/Extra.xcconfig"], [:]),
            BuildFile(pbxproj, "", ["-xcconfig", "Missing.xcconfig"], [:]),
            BuildFile(pbxproj, "", ["-xcconfig", "$(CI)/Extra.xcconfig"], [:]),
            BuildFile(pbxproj, "", ["test", "-xcconfig"], [:]),
            BuildFile(pbxproj, "", [], ["XCODE_XCCONFIG_FILE": "/ci/Extra.xcconfig"]),
        ]
    }

    /// A project file whose configuration is based on a file in a synchronized folder outside the project.
    var projectBasedOnASynchronizedFolder: String {
        projectFile(mainGroup: "S", """
        S = {isa = PBXFileSystemSynchronizedRootGroup; path = ../Shared; sourceTree = "<group>"; };
        C = {isa = XCBuildConfiguration; baseConfigurationReferenceAnchor = S;
            baseConfigurationReferenceRelativePath = Base.xcconfig; buildSettings = {}; name = Debug; };
        """)
    }

    /// A project file whose configuration file is in two groups, as a merge can leave it, so which file Xcode takes
    /// can't be told.
    var projectWithItsConfigurationFileTwice: String {
        projectFile(mainGroup: "G, H", """
        G = {isa = PBXGroup; children = (F); path = Configs; sourceTree = "<group>"; };
        H = {isa = PBXGroup; children = (F); path = ../Shared; sourceTree = "<group>"; };
        F = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Base.xcconfig; sourceTree = "<group>"; };
        C = {isa = XCBuildConfiguration; baseConfigurationReference = F; buildSettings = {}; name = Debug; };
        """)
    }

    // A package outside the project builds with the conditions its manifest sets, which the scan didn't read.
    func test_aWorkspacesPackageOutsideTheProject_leavesAConditionNoTargetSetsUndecided() async throws {
        let package = try makeTemporaryDirectory()
        try #".define("CORE_ONLY")"#.write(toFile: package + "/Package.swift", atomically: true, encoding: .utf8)
        try write(
            workspaceFile(#"<FileRef location = "absolute:\#(package)"/>"#),
            to: "W.xcworkspace/contents.xcworkspacedata"
        )
        settings(test: [macOSTarget], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertThrowsError(try conditions.isCustomConditionSet(name: "CORE_ONLY"))
    }

    func test_withEveryBuildFileRead_aConditionNoTargetSetsIsUnset() async throws {
        let synchronized = projectFile(mainGroup: "S", """
        S = {isa = PBXFileSystemSynchronizedRootGroup; path = Configs; sourceTree = "<group>"; };
        C = {isa = XCBuildConfiguration; baseConfigurationReferenceAnchor = S;
            baseConfigurationReferenceRelativePath = Base.xcconfig; buildSettings = {}; name = Debug; };
        """)
        let projectFiles = [
            projectFile(basedOn: "Base.xcconfig", inGroupAt: "Configs"),
            projectFile(basedOn: "Configs/Base.xcconfig", sourceTree: "SOURCE_ROOT"),
            synchronized,
        ]
        for text in projectFiles + [nil, projectFile(referencingProject: "Sub/Sub.xcodeproj")] {
            project = try makeTemporaryDirectory()
            // An absolute path is taken as it is.
            try write(
                text ?? projectFile(basedOn: project.canonicalPath + "/Configs/Base.xcconfig"),
                to: "App.xcodeproj/project.pbxproj"
            )
            try write("", to: "Sub/Sub.xcodeproj/project.pbxproj")
            try write(
                "#include \"Shared.xcconfig\"\n#include? \"../Configs/Shared.xcconfig\"",
                to: "Configs/Base.xcconfig"
            )
            try write("", to: "Configs/Shared.xcconfig")
            settings(test: [macOSTarget], build: [])

            let conditions = try await conditions(arguments: ["test"])

            XCTAssertFalse(try conditions.isCustomConditionSet(name: "CORE_ONLY"), text ?? "absolute")
        }
    }

    // A workspace's projects and packages in the project, and what it references that nothing builds from, as a
    // file outside it, leave every build file read, and so do `-xcconfig`'s and `XCODE_XCCONFIG_FILE`'s in it.
    func test_aWorkspaceAndCommandWithEveryBuildFileRead_leaveAConditionNoTargetSetsUnset() async throws {
        try write("", to: "App.xcodeproj/project.pbxproj")
        try write(
            workspaceFile(#"<FileRef location = "self:"/>"#),
            to: "App.xcodeproj/project.xcworkspace/contents.xcworkspacedata"
        )
        try write("// swift-tools-version:6.0", to: "Packages/Core/Package.swift")
        try write("", to: "Configs/CI.xcconfig")
        try write(workspaceFile("""
        <FileRef location = "group:App.xcodeproj"/>
        <Group name = "Packages"><FileRef location = "container:Packages/Core"/></Group>
        <Group location = "group:Packages"><FileRef location = "group:Core"/></Group>
        <FileRef location = "group:../Notes/README.md"/>
        """), to: "W.xcworkspace/contents.xcworkspacedata")
        let commands: [(arguments: [String], environment: [String: String])] = [
            ([], [:]),
            (["-xcconfig", "Configs/CI.xcconfig"], [:]),
            (["-xcconfig", project.canonicalPath + "/Configs/CI.xcconfig"], [:]),
            ([], ["XCODE_XCCONFIG_FILE": "Configs/CI.xcconfig"]),
        ]
        for (arguments, environment) in commands {
            settings(test: [macOSTarget], build: [])

            let conditions = try await conditions(arguments: arguments + ["test"], environment: environment)

            XCTAssertFalse(try conditions.isCustomConditionSet(name: "CORE_ONLY"), "\(arguments) \(environment)")
        }
    }

    // Xcode takes `..` off the folder before it, whatever links there are, so `Link/../../X.xcconfig` is outside the
    // project even where `Link` leads two folders down in it.
    func test_aProjectFilesPathsAreResolvedAsXcodeDoes_notThroughLinks() async throws {
        try write("", to: "X.xcconfig")
        try FileManager.default.createDirectory(atPath: project + "/a/b", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project + "/Link", withDestinationPath: "a/b")
        try write(
            projectFile(basedOn: "../../X.xcconfig", inGroupAt: "Link"),
            to: "App.xcodeproj/project.pbxproj"
        )
        settings(test: [macOSTarget], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertThrowsError(try conditions.isCustomConditionSet(name: "CORE_ONLY"))
    }

    // xcodebuild takes `..` off the folder before it in the files `-xcconfig` and `XCODE_XCCONFIG_FILE` name too.
    func test_theCommandsConfigurationFiles_areResolvedAsXcodebuildDoes_notThroughLinks() async throws {
        try write("", to: "X.xcconfig")
        try FileManager.default.createDirectory(atPath: project + "/a/b", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project + "/Link", withDestinationPath: "a/b")
        let commands: [(arguments: [String], environment: [String: String])] = [
            (["-xcconfig", "Link/../../X.xcconfig"], [:]),
            ([], ["XCODE_XCCONFIG_FILE": "Link/../../X.xcconfig"]),
        ]
        for (arguments, environment) in commands {
            settings(test: [macOSTarget], build: [])

            let conditions = try await conditions(arguments: arguments + ["test"], environment: environment)

            XCTAssertThrowsError(try conditions.isCustomConditionSet(name: "CORE_ONLY"), "\(arguments) \(environment)")
        }
    }

    // A condition put together from a setting, or from one Xcode sets itself for each target, is a word in no build
    // file, so it may be set for a target xcodebuild didn't report.
    func test_aConditionASettingMayPutTogether_isUndecided() async throws {
        let composing = [
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) EDITION_$(EDITION)\nEDITION = LITE",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(EDITION)_BUILD\nEDITION = LITE",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(EDITION:upper)\nEDITION = lite",
            "OTHER_SWIFT_FLAGS = $(FLAGS_$(CONFIGURATION))",
            "OTHER_SWIFT_FLAGS = -D$(TARGET_NAME)",
            "OTHER_SWIFT_FLAGS = $(MORE_FLAGS)\nMORE_FLAGS = -DEDITION_${CURRENT_ARCH}",
        ]
        for text in composing {
            project = try makeTemporaryDirectory()
            try write(text, to: "Configs/Shared.xcconfig")
            settings(test: [macOSTarget], build: [])

            let conditions = try await conditions(arguments: ["test"])

            XCTAssertThrowsError(try conditions.isCustomConditionSet(name: "EDITION_PRO"), text)
        }

        project = try makeTemporaryDirectory()
        try write("""
        SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) $(EXTRA)
        EXTRA = FROM_EXTRA
        OTHER_SWIFT_FLAGS = -D$(MORE) -D ${OTHER}
        MORE = FROM_MORE
        """, to: "Configs/Shared.xcconfig")
        settings(test: [macOSTarget], build: [])
        let plain = try await conditions(arguments: ["test"], environment: ["OTHER": "FROM_ENVIRONMENT"])
        XCTAssertFalse(try plain.isCustomConditionSet(name: "EDITION_PRO"))
        for name in ["FROM_EXTRA", "FROM_MORE", "FROM_ENVIRONMENT"] {
            XCTAssertThrowsError(try plain.isCustomConditionSet(name: name), name)
        }
    }

    // A target xcodebuild didn't report may use a setting no reported target does, as `$(CORE_FLAGS)`, that the
    // command, or the environment xcodebuild reads settings from, sets.
    func test_aConditionTheCommandsSettingsName_isUndecided() async throws {
        try write("OTHER_SWIFT_FLAGS = \"$(inherited) $(CORE_FLAGS)\";", to: "App.xcodeproj/project.pbxproj")
        let cases: [(arguments: [String], environment: [String: String])] = [
            (["CORE_FLAGS=-DCORE_ONLY"], [:]),
            ([], ["CORE_FLAGS": "-DCORE_ONLY"]),
            ([], ["CORE_FLAGS": "$(MORE_FLAGS)", "MORE_FLAGS": "-DCORE_ONLY"]),
            ([], ["OTHER_SWIFT_FLAGS": "-DCORE_ONLY"]),
        ]
        for (arguments, environment) in cases {
            settings(test: [macOSTarget], build: [])

            let conditions = try await conditions(arguments: arguments + ["test"], environment: environment)

            XCTAssertThrowsError(try conditions.isCustomConditionSet(name: "CORE_ONLY"), "\(arguments) \(environment)")
        }

        try write(
            "OTHER_SWIFT_FLAGS = \"$(inherited) $(CORE_FLAGS)\";\nCORE_FLAGS = -DLITE;",
            to: "App.xcodeproj/project.pbxproj"
        )
        let unnamed = try await conditions(arguments: ["test"], environment: ["ELSEWHERE": "-DCORE_ONLY"])
        XCTAssertFalse(try unnamed.isCustomConditionSet(name: "CORE_ONLY"))
    }
}
