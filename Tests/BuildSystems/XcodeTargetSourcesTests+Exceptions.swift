import Foundation
@testable import muterCore
import XCTest

/// How synced folders' exceptions, local packages' own dependencies and workspaces inside a project or package are
/// read.
extension XcodeTargetSourcesTests {
    // An app extension's files are often added, by an exception, from a folder no target owns.
    func test_aFolderNoTargetOwns_addsTheFilesItsExceptionsGiveATarget() throws {
        try writeProject(objects: [
            "MAIN": group(children: ["EXTFOLDER"]),
            "EXTFOLDER": [
                "isa": "PBXFileSystemSynchronizedRootGroup", "path": "Notifications", "sourceTree": "<group>",
                "exceptions": ["EXTEXCEPTIONS", "TESTEXCEPTIONS"],
            ],
            "EXTEXCEPTIONS": exceptionSet(target: "EXT", ["NotificationService.swift", "Support"]),
            "TESTEXCEPTIONS": exceptionSet(target: "TESTS", ["ServiceStub.swift"]),
            "EXT": target("Notifications", type: "com.apple.product-type.app-extension"),
            "TESTS": target("ExtTests", type: unitTests),
        ])
        let support = root + "/Notifications/Support"
        try FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)

        let listing = try listing()

        XCTAssertTrue(listing.contains(root + "/Notifications/NotificationService.swift"))
        XCTAssertTrue(listing.contains(root + "/Notifications/Support/Formatting.swift"))
        XCTAssertFalse(listing.contains(root + "/Notifications/ServiceStub.swift"))
        XCTAssertFalse(listing.contains(root + "/Notifications/Unused.swift"))
    }

    // For a target that owns the folder too, an exception takes files out: one every owner takes out doesn't count.
    func test_aFolderTwoTargetsOwn_leavesOutAFileOnlyWhenBothTakeItOut() throws {
        try writeProject(objects: [
            "MAIN": group(children: ["SHARED"]),
            "SHARED": [
                "isa": "PBXFileSystemSynchronizedRootGroup", "path": "Shared", "sourceTree": "<group>",
                "exceptions": ["MACOUT", "IOSOUT"],
            ],
            "MACOUT": exceptionSet(target: "MAC", ["Legacy.swift", "MacOnly.swift"]),
            "IOSOUT": exceptionSet(target: "IOS", ["Legacy.swift"]),
            "MAC": target("Mac", folders: ["SHARED"]),
            "IOS": target("iOS", folders: ["SHARED"]),
        ])

        let listing = try listing()

        XCTAssertFalse(listing.contains(root + "/Shared/Legacy.swift"))
        XCTAssertTrue(listing.contains(root + "/Shared/MacOnly.swift"))
        XCTAssertTrue(listing.contains(root + "/Shared/Model.swift"))
    }

    // Xcode builds the packages a local package depends on by path, though no project names them.
    func test_theLocalPackagesALocalPackageDependsOn_countToo() throws {
        let engine = root + "/Packages/Engine"
        let rules = root + "/Packages/Rules"
        for folder in [engine, rules] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        try #"let package = Package(name: "Engine", dependencies: [.package(path: "../Rules")])"#
            .write(toFile: engine + "/Package.swift", atomically: true, encoding: .utf8)
        try #"let package = Package(name: "Rules")"#
            .write(toFile: rules + "/Package.swift", atomically: true, encoding: .utf8)
        try writeProject(objects: [
            "MAIN": group(children: []),
            "ENGINE": ["isa": "XCLocalSwiftPackageReference", "relativePath": "Packages/Engine"],
        ])

        XCTAssertTrue(try listing().contains(rules + "/Sources/Rules/Rule.swift"))
    }

    // A project's own workspace opens the project, and a package's in `.swiftpm/xcode` the package; a workspace that
    // names neither can't say what builds.
    func test_aWorkspaceInsideAProjectOrPackage_opensIt_andOneNamingNothingFails() throws {
        try writeProject(objects: [
            "MAIN": group(children: ["MODEL"]),
            "MODEL": fileReference("Model.swift"),
            "APP": target("App", sources: ["MODEL"]),
        ])
        FileManager.default.createFile(atPath: root + "/Package.swift", contents: Data())

        let ofTheProject = try listing(arguments: ["-workspace", "App.xcodeproj/project.xcworkspace", "test"])
        XCTAssertEqual(ofTheProject.files, [root + "/Model.swift"])
        let ofThePackage = try listing(arguments: ["-workspace", ".swiftpm/xcode/package.xcworkspace", "test"])
        XCTAssertTrue(ofThePackage.contains(root + "/Sources/Lib/Lib.swift"))

        try writeWorkspace([])
        XCTAssertEqual(
            try listingFailure(arguments: ["-workspace", "App.xcworkspace", "test"]),
            "App.xcworkspace names no project or package"
        )
    }
}

/// Links in counted folders, local dependencies by a computed path, and the container xcodebuild picks.
extension XcodeTargetSourcesTests {
    // SwiftPM compiles the file a link in a package leads to, and the files of a folder one leads to, wherever they
    // are: the walk lists them by their own paths too.
    func test_whatLinksInALocalPackageLeadTo_counts() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: root + "/Shared/Models", withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: root + "/Core/Sources/Core", withIntermediateDirectories: true)
        for file in ["/Shared/Shared.swift", "/Shared/Models/Model.swift", "/Core/Package.swift"] {
            fileManager.createFile(atPath: root + file, contents: Data())
        }
        try fileManager.createSymbolicLink(
            atPath: root + "/Core/Sources/Core/Shared.swift",
            withDestinationPath: "../../../Shared/Shared.swift"
        )
        try fileManager.createSymbolicLink(
            atPath: root + "/Core/Sources/Core/Models",
            withDestinationPath: "../../../Shared/Models"
        )
        try writeProject(objects: [
            "MAIN": group(children: []),
            "CORE": ["isa": "XCLocalSwiftPackageReference", "relativePath": "Core"],
        ])

        let listing = try listing()

        XCTAssertTrue(listing.contains(root + "/Shared/Shared.swift"))
        XCTAssertTrue(listing.contains(root + "/Shared/Models/Model.swift"))
        XCTAssertFalse(listing.contains(root + "/Shared/Unlinked.swift"))
    }

    // A path the manifest computes can't be followed, so what the targets compile can't be told.
    func test_aLocalDependencyByAComputedPath_failsTheListing() throws {
        try FileManager.default.createDirectory(atPath: root + "/Core", withIntermediateDirectories: true)
        try #"let package = Package(name: "Core", dependencies: [.package(path: base + "/Rules")])"#
            .write(toFile: root + "/Core/Package.swift", atomically: true, encoding: .utf8)
        try writeProject(objects: [
            "MAIN": group(children: []),
            "CORE": ["isa": "XCLocalSwiftPackageReference", "relativePath": "Core"],
        ])

        XCTAssertEqual(
            try listingFailure(),
            "Core/Package.swift depends on a local package by a path it can't read"
        )
    }

    // Without `-project` or `-workspace`, xcodebuild opens the one project at the top of the folder, even beside a
    // workspace.
    func test_withoutAContainerNamed_theOneProjectAtTheTop_isRead() throws {
        try writeProject(objects: [
            "MAIN": group(children: ["MODEL"]),
            "MODEL": fileReference("Model.swift"),
            "APP": target("App", sources: ["MODEL"]),
        ])
        try writeWorkspace(["group:Example/Example.xcodeproj"])

        XCTAssertEqual(try listing(arguments: ["test"]).files, [root + "/Model.swift"])
    }
}
