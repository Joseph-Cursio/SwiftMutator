import Foundation
@testable import muterCore
import XCTest

/// The less usual ways a scheme's test action builds a target or package.
extension XcodeTargetSourcesTests {
    // A package the scheme tests is built whole, though no target the scheme builds uses it.
    func test_aLocalPackageTheSchemeTests_counts() throws {
        try FileManager.default.createDirectory(atPath: root + "/Parsing", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root + "/Parsing/Package.swift", contents: Data())
        try writeProject(objects: [
            "MAIN": group(children: ["APPFILE"]),
            "APPFILE": fileReference("App.swift"),
            "PARSING": ["isa": "XCLocalSwiftPackageReference", "relativePath": "Parsing"],
            "APP": target("App", sources: ["APPFILE"]),
        ])
        try writeScheme(references: [("APP", "App.xcodeproj"), ("ParsingTests", "Parsing")])

        let listing = try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"])

        XCTAssertTrue(listing.contains(root + "/Parsing/Sources/Parsing/Parser.swift"))
    }

    // A test target compiles a file of a folder synced for a tool the scheme doesn't build, by an exception, or the
    // folder is its own too: the file is code under test.
    func test_aFileATestTargetCompilesFromAToolsSyncedFolder_counts() throws {
        try FileManager.default.createDirectory(atPath: root + "/Tool", withIntermediateDirectories: true)
        for file in ["Parser.swift", "main.swift"] {
            FileManager.default.createFile(atPath: root + "/Tool/" + file, contents: Data())
        }
        try writeProject(objects: [
            "MAIN": group(children: ["TOOLFOLDER"]),
            "TOOLFOLDER": [
                "isa": "PBXFileSystemSynchronizedRootGroup", "path": "Tool", "sourceTree": "<group>",
                "exceptions": ["FORTESTS"],
            ],
            "FORTESTS": exceptionSet(target: "TESTS", ["Parser.swift"]),
            "TOOL": target("Tool", type: "com.apple.product-type.tool", folders: ["TOOLFOLDER"]),
            "TESTS": target("ToolTests", type: unitTests),
        ])
        try writeScheme(references: [("TESTS", "App.xcodeproj")])

        let listing = try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"])

        XCTAssertTrue(listing.contains(root + "/Tool/Parser.swift"))
        XCTAssertFalse(listing.contains(root + "/Tool/main.swift"))
    }

    // Xcode builds a local package no product dependency names, as a root package, and one with a remote package's
    // name, which it stands in for, whatever target uses them.
    func test_aLocalPackageNoTargetNames_orStandingInForARemoteOne_counts() throws {
        try writeProject(objects: [
            "MAIN": group(children: ["APPFILE"]),
            "APPFILE": fileReference("App.swift"),
            "ROOTPACKAGE": ["isa": "XCLocalSwiftPackageReference", "relativePath": "Packages/Root"],
            "YAMS": ["isa": "XCLocalSwiftPackageReference", "relativePath": "Vendor/Yams"],
            "YAMSREMOTE": [
                "isa": "XCRemoteSwiftPackageReference", "repositoryURL": "https://example.com/jpsim/Yams.git",
            ],
            "YAMSPRODUCT": ["isa": "XCSwiftPackageProductDependency", "package": "YAMS", "productName": "Yams"],
            "UNUSEDPRODUCT": ["isa": "XCSwiftPackageProductDependency", "package": "UNUSED", "productName": "Unused"],
            "UNUSED": ["isa": "XCLocalSwiftPackageReference", "relativePath": "Packages/Unused"],
            "APP": target("App", sources: ["APPFILE"]),
            "TOOL": target("Tool", type: "com.apple.product-type.tool")
                .merging(["packageProductDependencies": ["YAMSPRODUCT", "UNUSEDPRODUCT"]]) { _, new in new },
        ])
        try writeScheme(references: [("APP", "App.xcodeproj")])

        let listing = try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"])

        XCTAssertTrue(listing.contains(root + "/Packages/Root/Sources/Root/Root.swift"))
        XCTAssertTrue(listing.contains(root + "/Vendor/Yams/Sources/Yams/Yams.swift"))
        XCTAssertFalse(listing.contains(root + "/Packages/Unused/Sources/Unused/Unused.swift"))
    }

    // Xcode builds a target whose product the linker flags name, or a phase copies, first.
    func test_aTargetLinkedByFlags_orCopiedAsAResource_counts() throws {
        var app = target("App", sources: ["APPFILE"])
        app["buildConfigurationList"] = "APPCONFIGS"
        app["buildPhases"] = ["App-SOURCES", "APPRESOURCES"]
        var kit = target("Kit", type: "com.apple.product-type.framework", sources: ["KITFILE"])
        kit["productReference"] = "KITPRODUCT"
        var bundle = target("Assets", type: "com.apple.product-type.bundle", sources: ["ASSETSFILE"])
        bundle["productReference"] = "ASSETSPRODUCT"
        try writeProject(objects: [
            "MAIN": group(children: ["APPFILE", "KITFILE", "ASSETSFILE"]),
            "APPFILE": fileReference("App.swift"),
            "KITFILE": fileReference("Kit.swift"),
            "ASSETSFILE": fileReference("Assets.swift"),
            "KITPRODUCT": ["isa": "PBXFileReference", "path": "Kit.framework", "sourceTree": "BUILT_PRODUCTS_DIR"],
            "ASSETSPRODUCT": ["isa": "PBXFileReference", "path": "Assets.bundle", "sourceTree": "BUILT_PRODUCTS_DIR"],
            "APPRESOURCES": ["isa": "PBXResourcesBuildPhase", "files": ["ASSETSCOPY"]],
            "ASSETSCOPY": ["isa": "PBXBuildFile", "fileRef": "ASSETSPRODUCT"],
            "APPCONFIGS": ["isa": "XCConfigurationList", "buildConfigurations": ["APPDEBUG"]],
            "APPDEBUG": [
                "isa": "XCBuildConfiguration",
                "buildSettings": ["OTHER_LDFLAGS": ["$(inherited)", "-ObjC", "-framework", "Kit", "-lz"]],
            ],
            "APP": app,
            "KIT": kit,
            "ASSETS": bundle,
        ])
        try writeScheme(references: [("APP", "App.xcodeproj")])

        let listing = try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"])

        XCTAssertEqual(listing.files, [root + "/App.swift", root + "/Kit.swift", root + "/Assets.swift"])
    }

    // xcodebuild reads only the user's own schemes, so another user's leaves the scheme to Xcode.
    func test_anotherUsersScheme_isNotRead() throws {
        try writeProject(objects: [
            "MAIN": group(children: ["APPFILE", "TOOLFILE"]),
            "APPFILE": fileReference("App.swift"),
            "TOOLFILE": fileReference("Tool.swift"),
            "APP": target("App", sources: ["APPFILE"]),
            "TOOL": target("Tool", type: "com.apple.product-type.tool", sources: ["TOOLFILE"]),
        ])
        try writeScheme(references: [("APP", "App.xcodeproj")], in: "xcuserdata/someone-else.xcuserdatad")

        let listing = try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"])

        XCTAssertTrue(listing.contains(root + "/Tool.swift"))
    }

    /// Writes the scheme App, in `folder` of App.xcodeproj, whose build action builds for testing each of
    /// `references`, a target's ID and its container.
    private func writeScheme(references: [(id: String, container: String)], in folder: String = "xcshareddata") throws {
        let entries = references.map { reference in
            #"<BuildActionEntry buildForTesting = "YES"><BuildableReference BlueprintIdentifier = "\#(reference.id)" "#
                + #"ReferencedContainer = "container:\#(reference.container)"/></BuildActionEntry>"#
        }
        let scheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme><BuildAction><BuildActionEntries>\(entries.joined())</BuildActionEntries></BuildAction></Scheme>
        """
        let schemes = root + "/App.xcodeproj/\(folder)/xcschemes"
        try FileManager.default.createDirectory(atPath: schemes, withIntermediateDirectories: true)
        try scheme.write(toFile: schemes + "/App.xcscheme", atomically: true, encoding: .utf8)
    }
}
