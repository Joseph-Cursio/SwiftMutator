import Foundation
@testable import muterCore
import XCTest

final class XcodeTargetSourcesTests: MuterTestCase {
    var root = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try makeTemporaryDirectory().canonicalPath
    }

    // An old-style project file, as Xcode writes it: its target's files, through its groups.
    func test_aProjectFileXcodeWrote_listsItsTargetsFiles() throws {
        let fixture = fixturesDirectory + "/XcodeProjectFiles/iOSApp.xcodeproj"
        try FileManager.default.copyItem(atPath: fixture, toPath: root + "/iOSApp.xcodeproj")

        let listing = try listing(arguments: ["-project", "iOSApp.xcodeproj", "test"])

        XCTAssertEqual(listing.files, [root + "/DeleteMe/AppDelegate.swift", root + "/DeleteMe/ViewController.swift"])
    }

    // A file a test target alone compiles is a test file, one no target compiles an example's, and a file the build
    // makes is outside the project.
    func test_onlyFilesATargetUnderTestCompiles_areListed() throws {
        try writeProject(objects: [
            "MAIN": group(children: ["APPGROUP", "TESTGROUP", "DEMO"]),
            "APPGROUP": group(children: ["MODEL", "VIEW"], path: "App"),
            "TESTGROUP": group(children: ["MODELTESTS"], path: "AppTests"),
            "MODEL": fileReference("Model.swift"),
            "VIEW": fileReference("View.swift"),
            "MODELTESTS": fileReference("ModelTests.swift"),
            "DEMO": fileReference("Examples/Demo.swift"),
            "GENERATED": ["isa": "PBXFileReference", "path": "Strings.swift", "sourceTree": "DERIVED_FILE_DIR"],
            "APP": target("App", sources: ["MODEL", "VIEW", "GENERATED"]),
            "TESTS": target("AppTests", type: unitTests, sources: ["MODELTESTS", "MODEL"]),
        ])

        let listing = try listing()

        XCTAssertEqual(listing.files, [root + "/App/Model.swift", root + "/App/View.swift"])
        XCTAssertFalse(listing.contains(root + "/Examples/Demo.swift"))
        XCTAssertFalse(listing.contains(root + "/AppTests/ModelTests.swift"))
    }

    // A folder synced with a group counts whole for the target it belongs to, but the files its exceptions take out
    // of that target; an exception of another target's adds files to that one, unless it is a test target.
    func test_aFolderSyncedWithAGroup_countsWhole_butItsOwnersExceptions() throws {
        try writeProject(objects: [
            "MAIN": group(children: ["APPFOLDER"]),
            "APPFOLDER": [
                "isa": "PBXFileSystemSynchronizedRootGroup", "path": "App", "sourceTree": "<group>",
                "exceptions": ["APPEXCEPTIONS", "WIDGETEXCEPTIONS", "TESTEXCEPTIONS"],
            ],
            "APPEXCEPTIONS": exceptionSet(target: "APP", ["Old.swift", "Intents/Intent.swift", "Fixtures/Stub.swift"]),
            "WIDGETEXCEPTIONS": exceptionSet(target: "WIDGET", ["Intents/Intent.swift"]),
            "TESTEXCEPTIONS": exceptionSet(target: "TESTS", ["Fixtures/Stub.swift"]),
            "APP": target("App", folders: ["APPFOLDER"]),
            "WIDGET": target("Widget"),
            "TESTS": target("AppTests", type: unitTests),
        ])

        let listing = try listing()

        XCTAssertTrue(listing.contains(root + "/App/Model.swift"))
        XCTAssertTrue(listing.contains(root + "/App/Nested/Deep.swift"))
        XCTAssertFalse(listing.contains(root + "/App/Old.swift"))
        XCTAssertTrue(listing.contains(root + "/App/Intents/Intent.swift"))
        XCTAssertFalse(listing.contains(root + "/App/Fixtures/Stub.swift"))
        XCTAssertFalse(listing.contains(root + "/AppSupport/Other.swift"))
    }

    // A kind of exception SwiftMutator doesn't know may add files, so every file in the folder counts.
    func test_aFolderWithAnUnknownKindOfException_countsWhole() throws {
        try writeProject(objects: [
            "MAIN": group(children: ["APPFOLDER"]),
            "APPFOLDER": [
                "isa": "PBXFileSystemSynchronizedRootGroup", "path": "App", "sourceTree": "<group>",
                "exceptions": ["KNOWN", "UNKNOWN"],
            ],
            "KNOWN": exceptionSet(target: "APP", ["Old.swift"]),
            "UNKNOWN": ["isa": "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet"],
            "APP": target("App", folders: ["APPFOLDER"]),
        ])

        XCTAssertTrue(try listing().contains(root + "/App/Old.swift"))
    }

    // Its own manifest says what a local package compiles, by a package reference or as a folder in a group; a
    // project it references is read too.
    func test_localPackages_countWhole_andAReferencedProjectIsRead() throws {
        try FileManager.default.createDirectory(atPath: root + "/Packages/Kit", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root + "/Packages/Kit/Package.swift", contents: Data())
        try writeProject(objects: [
            "MAIN": group(children: ["KIT", "SUB"]),
            "CORE": ["isa": "XCLocalSwiftPackageReference", "relativePath": "Packages/Core"],
            "KIT": [
                "isa": "PBXFileReference", "lastKnownFileType": "wrapper", "path": "Packages/Kit",
                "sourceTree": "<group>",
            ],
            "SUB": [
                "isa": "PBXFileReference", "lastKnownFileType": "wrapper.pb-project", "path": "Sub/Sub.xcodeproj",
                "sourceTree": "<group>",
            ],
        ])
        try writeProject(objects: [
            "MAIN": group(children: ["LIB"]),
            "LIB": fileReference("Lib.swift"),
            "SUBLIB": target("SubLib", sources: ["LIB"]),
        ], at: root + "/Sub/Sub.xcodeproj")

        let listing = try listing()

        XCTAssertTrue(listing.contains(root + "/Packages/Core/Sources/Core/Core.swift"))
        XCTAssertTrue(listing.contains(root + "/Packages/Kit/Sources/Kit/Kit.swift"))
        XCTAssertTrue(listing.contains(root + "/Sub/Lib.swift"))
    }

    // A workspace's projects, and its packages, as `-workspace` names it or as xcodebuild finds it at the top of the
    // project.
    func test_aWorkspacesProjectsAndPackages_areRead() throws {
        try writeProject(objects: [
            "MAIN": group(children: ["MODEL"]),
            "MODEL": fileReference("Model.swift"),
            "APP": target("App", sources: ["MODEL"]),
        ], at: root + "/App/App.xcodeproj")
        try FileManager.default.createDirectory(atPath: root + "/Core", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root + "/Core/Package.swift", contents: Data())
        try writeWorkspace(["group:App/App.xcodeproj", "group:Core"])

        for arguments in [["-workspace", "App.xcworkspace", "test"], ["test"]] {
            let listing = try listing(arguments: arguments)

            XCTAssertEqual(listing.files, [root + "/App/Model.swift"], "\(arguments)")
            XCTAssertTrue(listing.contains(root + "/Core/Sources/Core/Core.swift"), "\(arguments)")
        }
    }

    // What an external tool builds, a project or workspace it can't read, or none to read: SwiftMutator can't tell
    // what the targets compile, and discovery walks the project.
    func test_whenWhatTheTargetsCompileCantBeTold_itFails() throws {
        XCTAssertEqual(
            try listingFailure(arguments: ["test"]),
            "it can't tell which project or workspace the test command opens"
        )
        XCTAssertEqual(
            try listingFailure(arguments: ["-project", "Gone.xcodeproj", "test"]),
            "Gone.xcodeproj has no project file it can read"
        )

        try writeProject(objects: [
            "MAIN": group(children: []),
            "TOOL": ["isa": "PBXLegacyTarget", "name": "Tool"],
        ])
        XCTAssertEqual(try listingFailure(), "App.xcodeproj's target Tool is built by an external tool")

        try writeWorkspace(["group:Other.xcworkspace"])
        XCTAssertEqual(
            try listingFailure(arguments: ["-workspace", "App.xcworkspace", "test"]),
            "the workspace names another workspace, Other.xcworkspace"
        )
    }

    // An object in two groups has no one place.
    func test_aFileItCantPlace_failsTheListing() throws {
        try writeProject(objects: [
            "MAIN": group(children: ["A", "B"]),
            "A": group(children: ["MODEL"], path: "A"),
            "B": group(children: ["MODEL"], path: "B"),
            "MODEL": fileReference("Model.swift"),
            "APP": target("App", sources: ["MODEL"]),
        ])

        XCTAssertEqual(try listingFailure(), "it can't place a file, Model.swift, of App.xcodeproj's target App")
    }

    // MARK: - Helpers

    let unitTests = "com.apple.product-type.bundle.unit-test"

    func listing(
        arguments: [String] = ["-project", "App.xcodeproj", "test"]
    ) throws -> XcodeTargetSources.Listing {
        let result = XcodeTargetSources.listing(
            inProjectAt: root,
            testedBy: MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: arguments),
            fileManager: FileManager.default
        )
        return try result.get()
    }

    func listingFailure(arguments: [String] = ["-project", "App.xcodeproj", "test"]) throws -> String? {
        let result = XcodeTargetSources.listing(
            inProjectAt: root,
            testedBy: MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: arguments),
            fileManager: FileManager.default
        )
        guard case let .failure(failure) = result else { return nil }
        return failure.reason
    }

    /// Writes a project file with `objects` and a project object whose main group is `MAIN`, as an XML property list,
    /// which the project file reader takes as it takes Xcode's own format.
    func writeProject(objects: [String: [String: Any]], at project: String? = nil) throws {
        let folder = project ?? root + "/App.xcodeproj"
        var all = objects
        all["PROJECT"] = ["isa": "PBXProject", "mainGroup": "MAIN", "projectDirPath": ""]
        for (name, sources) in sourcesPhases {
            all["\(name)-SOURCES"] = ["isa": "PBXSourcesBuildPhase", "files": sources.map { "\(name)-\($0)" }]
            for source in sources {
                all["\(name)-\(source)"] = ["isa": "PBXBuildFile", "fileRef": source]
            }
        }
        sourcesPhases = [:]
        let plist: [String: Any] = ["objectVersion": "77", "rootObject": "PROJECT", "objects": all]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: folder + "/project.pbxproj"))
    }

    func writeWorkspace(_ locations: [String]) throws {
        let folder = root + "/App.xcworkspace"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let references = locations.map { "<FileRef location = \"\($0)\"></FileRef>" }.joined()
        try "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Workspace version = \"1.0\">\(references)</Workspace>"
            .write(toFile: folder + "/contents.xcworkspacedata", atomically: true, encoding: .utf8)
    }

    func group(children: [String], path: String? = nil) -> [String: Any] {
        var group: [String: Any] = ["isa": "PBXGroup", "children": children, "sourceTree": "<group>"]
        group["path"] = path
        return group
    }

    func fileReference(_ path: String) -> [String: Any] {
        ["isa": "PBXFileReference", "lastKnownFileType": "sourcecode.swift", "path": path, "sourceTree": "<group>"]
    }

    func exceptionSet(target: String, _ paths: [String]) -> [String: Any] {
        ["isa": "PBXFileSystemSynchronizedBuildFileExceptionSet", "target": target, "membershipExceptions": paths]
    }

    /// A native target whose Sources phase compiles the file references `sources`, and that owns the synced folders
    /// `folders`. Its phase and build files are named after it.
    func target(
        _ name: String,
        type: String = "com.apple.product-type.application",
        sources: [String] = [],
        folders: [String] = []
    ) -> [String: Any] {
        sourcesPhases[name] = sources
        return [
            "isa": "PBXNativeTarget", "name": name, "productType": type, "buildPhases": ["\(name)-SOURCES"],
            "fileSystemSynchronizedGroups": folders,
        ]
    }

    private var sourcesPhases: [String: [String]] = [:]
}
