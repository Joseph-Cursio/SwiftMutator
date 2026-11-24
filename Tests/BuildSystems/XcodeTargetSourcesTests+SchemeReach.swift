import Foundation
@testable import muterCore
import XCTest

/// Which targets count when the scheme says what its test action builds (`XcodeTestReach`).
extension XcodeTargetSourcesTests {
    // The scheme builds App for testing and tests AppTests; App links Kit, and depends on Widgets; AppTests runs in
    // App. Tool and its Helper aren't built.
    func test_onlyTheTargetsTheSchemesTestActionBuilds_count() throws {
        try writeReachProject()
        try writeScheme(buildingForTesting: ["APP"], testing: ["TESTS"])

        let listing = try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"])

        XCTAssertEqual(listing.files, [
            root + "/App.swift", root + "/Kit.swift", root + "/Widget.swift",
        ])
    }

    // A test target's host is a target the test action builds, though no build entry names it; a bundle loader that
    // names the test host says nothing more.
    func test_aTestTargetsHost_counts() throws {
        try writeReachProject()
        try writeScheme(buildingForTesting: [], testing: ["TESTS"])

        let listing = try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"])

        XCTAssertTrue(listing.contains(root + "/App.swift"))
        XCTAssertTrue(listing.contains(root + "/Kit.swift"))
        XCTAssertFalse(listing.contains(root + "/Tool.swift"))
    }

    // A test plan names the targets it tests, which the test action builds.
    func test_aSchemesTestPlan_namesTheTargetsItTests() throws {
        try writeReachProject()
        try writeScheme(buildingForTesting: [], testing: [], testPlans: ["App.xctestplan"])
        try #"{"version": 1, "testTargets": [{"target": {"containerPath": "container:App.xcodeproj", "#
            .appending(#""identifier": "TOOLTESTS", "name": "ToolTests"}}]}"#)
            .write(toFile: root + "/App.xctestplan", atomically: true, encoding: .utf8)

        let listing = try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"])

        XCTAssertEqual(listing.files, [root + "/Tool.swift", root + "/Helper.swift"])
    }

    // What SwiftMutator can't tell, every target counts for: no scheme named, none found, one that leaves its test
    // plan to Xcode and names no test target, or one naming a target the project hasn't.
    func test_whenTheSchemeCantSayWhatItBuilds_everyTargetCounts() throws {
        try writeReachProject()
        let everyFile: Set = [
            root + "/App.swift", root + "/Kit.swift", root + "/Widget.swift", root + "/Tool.swift",
            root + "/Helper.swift",
        ]

        XCTAssertEqual(try listing(arguments: ["-project", "App.xcodeproj", "test"]).files, everyFile)
        let gone = try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "Gone", "test"])
        XCTAssertEqual(gone.files, everyFile)
        try writeScheme(buildingForTesting: ["KIT"], testing: [], autocreatesATestPlan: true)
        XCTAssertEqual(try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"]).files, everyFile)
        try writeScheme(buildingForTesting: ["GONE"], testing: ["TESTS"])
        XCTAssertEqual(try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"]).files, everyFile)
    }

    // A test target's file that a target under test compiles too counts though the scheme doesn't build that one: the
    // test target compiles the code under test itself.
    func test_aFileATestTargetCompiles_thatATargetUnderTestDoesToo_counts() throws {
        try writeReachProject(testsCompile: ["APPFILE"])
        try writeScheme(buildingForTesting: [], testing: ["SELFTESTS"])

        let listing = try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"])

        XCTAssertEqual(listing.files, [root + "/App.swift"])
    }

    // Only the local packages whose products a target the scheme builds uses count.
    func test_onlyTheLocalPackagesATargetThatCountsUses_count() throws {
        try writeReachProject(packages: true)
        try writeScheme(buildingForTesting: ["KIT"], testing: [])

        let listing = try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"])

        XCTAssertTrue(listing.contains(root + "/Packages/Core/Sources/Core/Core.swift"))
        XCTAssertFalse(listing.contains(root + "/Packages/ToolKit/Sources/ToolKit/ToolKit.swift"))
    }

    // A dependency on a target of another project goes through a proxy naming that project; a product it links by a
    // reference proxy names the target that makes it there.
    func test_aDependencyOnAnotherProjectsTarget_isFollowed() throws {
        var app = target("App", sources: ["APPFILE"])
        app["dependencies"] = ["LIBDEP"]
        app["buildPhases"] = ["App-SOURCES", "APPFRAMEWORKS"]
        try writeProject(objects: [
            "MAIN": group(children: ["APPFILE", "SUBREF"]),
            "APPFILE": fileReference("App.swift"),
            "SUBREF": [
                "isa": "PBXFileReference", "lastKnownFileType": "wrapper.pb-project", "path": "Sub/Sub.xcodeproj",
                "sourceTree": "<group>",
            ],
            "LIBDEP": ["isa": "PBXTargetDependency", "targetProxy": "LIBPROXY"],
            "LIBPROXY": [
                "isa": "PBXContainerItemProxy", "containerPortal": "SUBREF", "proxyType": "1",
                "remoteGlobalIDString": "LIB",
            ],
            "APPFRAMEWORKS": ["isa": "PBXFrameworksBuildPhase", "files": ["UTILLINK"]],
            "UTILLINK": ["isa": "PBXBuildFile", "fileRef": "UTILPROXYREF"],
            "UTILPROXYREF": ["isa": "PBXReferenceProxy", "path": "libUtil.a", "remoteRef": "UTILPRODUCTPROXY"],
            "UTILPRODUCTPROXY": [
                "isa": "PBXContainerItemProxy", "containerPortal": "SUBREF", "proxyType": "2",
                "remoteGlobalIDString": "UTILPRODUCT",
            ],
            "APP": app,
        ])
        var util = target("Util", type: "com.apple.product-type.library.static", sources: ["UTILFILE"])
        util["productReference"] = "UTILPRODUCT"
        try writeProject(objects: [
            "MAIN": group(children: ["LIBFILE", "UTILFILE", "UNUSEDFILE"]),
            "LIBFILE": fileReference("Lib.swift"),
            "UTILFILE": fileReference("Util.swift"),
            "UNUSEDFILE": fileReference("Unused.swift"),
            "UTILPRODUCT": ["isa": "PBXFileReference", "path": "libUtil.a", "sourceTree": "BUILT_PRODUCTS_DIR"],
            "LIB": target("Lib", type: "com.apple.product-type.framework", sources: ["LIBFILE"]),
            "UTIL": util,
            "UNUSED": target("Unused", type: "com.apple.product-type.framework", sources: ["UNUSEDFILE"]),
        ], at: root + "/Sub/Sub.xcodeproj")
        try writeScheme(buildingForTesting: ["APP"], testing: [])

        let listing = try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"])

        XCTAssertEqual(listing.files, [root + "/App.swift", root + "/Sub/Lib.swift", root + "/Sub/Util.swift"])
    }

    // A build configuration file may name a test target's host where the project file doesn't say.
    func test_aTestTargetWhoseSettingsComeFromAFile_withNoHostNamed_letsEveryTargetCount() throws {
        var objects: [String: [String: Any]] = [:]
        objects["TESTSDEBUG"] = ["isa": "XCBuildConfiguration", "baseConfigurationReference": "XCCONFIG"]
        try writeReachProject(overriding: objects)
        try writeScheme(buildingForTesting: [], testing: ["TESTS"])

        let listing = try listing(arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"])

        XCTAssertTrue(listing.contains(root + "/Tool.swift"))
    }

    // MARK: - Helpers

    /// A project whose App depends on Widgets and links Kit's product; AppTests is hosted by App, and SelfTests
    /// compiles `testsCompile`; Tool depends on Helper; ToolTests tests Tool. With `packages`, Kit uses the local
    /// package Core and Tool uses ToolKit.
    private func writeReachProject(
        testsCompile: [String] = [],
        packages: Bool = false,
        overriding overrides: [String: [String: Any]] = [:]
    ) throws {
        let appSettings = ["isa": "XCConfigurationList", "buildConfigurations": ["TESTSDEBUG"]] as [String: Any]
        var app = target("App", sources: ["APPFILE"])
        app["dependencies"] = ["WIDGETDEP"]
        app["buildPhases"] = ["App-SOURCES", "APPFRAMEWORKS"]
        var tests = target("AppTests", type: unitTests)
        tests["buildConfigurationList"] = "TESTSCONFIGS"
        var tool = target("Tool", type: "com.apple.product-type.tool", sources: ["TOOLFILE"])
        tool["dependencies"] = ["HELPERDEP"]
        var kit = target("Kit", type: "com.apple.product-type.framework", sources: ["KITFILE"])
        kit["productReference"] = "KITPRODUCT"
        var objects: [String: [String: Any]] = [
            "MAIN": group(children: ["APPFILE", "KITFILE", "WIDGETFILE", "TOOLFILE", "HELPERFILE"]),
            "APPFILE": fileReference("App.swift"),
            "KITFILE": fileReference("Kit.swift"),
            "WIDGETFILE": fileReference("Widget.swift"),
            "TOOLFILE": fileReference("Tool.swift"),
            "HELPERFILE": fileReference("Helper.swift"),
            "KITPRODUCT": ["isa": "PBXFileReference", "path": "Kit.framework", "sourceTree": "BUILT_PRODUCTS_DIR"],
            "APPPRODUCT": ["isa": "PBXFileReference", "path": "App.app", "sourceTree": "BUILT_PRODUCTS_DIR"],
            "APPFRAMEWORKS": ["isa": "PBXFrameworksBuildPhase", "files": ["KITLINK"]],
            "KITLINK": ["isa": "PBXBuildFile", "fileRef": "KITPRODUCT"],
            "WIDGETDEP": ["isa": "PBXTargetDependency", "target": "WIDGETS"],
            "HELPERDEP": ["isa": "PBXTargetDependency", "targetProxy": "HELPERPROXY"],
            "HELPERPROXY": [
                "isa": "PBXContainerItemProxy", "containerPortal": "PROJECT", "proxyType": "1",
                "remoteGlobalIDString": "HELPER",
            ],
            "TESTSCONFIGS": appSettings,
            "TESTSDEBUG": [
                "isa": "XCBuildConfiguration",
                "buildSettings": [
                    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/App.app/Contents/MacOS/App", "BUNDLE_LOADER": "$(TEST_HOST)",
                ],
            ],
            "APP": app.merging(["productReference": "APPPRODUCT"]) { _, new in new },
            "KIT": kit,
            "WIDGETS": target("Widgets", type: "com.apple.product-type.app-extension", sources: ["WIDGETFILE"]),
            "TESTS": tests,
            "SELFTESTS": target("SelfTests", type: unitTests, sources: testsCompile),
            "TOOL": tool,
            "HELPER": target("Helper", type: "com.apple.product-type.library.static", sources: ["HELPERFILE"]),
            "TOOLTESTS": target("ToolTests", type: unitTests).merging(["dependencies": ["TOOLDEP"]]) { _, new in new },
            "TOOLDEP": ["isa": "PBXTargetDependency", "target": "TOOL"],
        ]
        if packages {
            addPackages(to: &objects)
        }
        objects.merge(overrides) { _, new in new }
        try writeProject(objects: objects)
    }

    /// Adds to `objects` the local packages Core, which Kit uses, and ToolKit, which Tool uses.
    private func addPackages(to objects: inout [String: [String: Any]]) {
        objects["CORE"] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "Packages/Core"]
        objects["TOOLKIT"] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "Packages/ToolKit"]
        objects["COREPRODUCT"] = [
            "isa": "XCSwiftPackageProductDependency", "package": "CORE", "productName": "Core",
        ]
        objects["TOOLKITPRODUCT"] = [
            "isa": "XCSwiftPackageProductDependency", "package": "TOOLKIT", "productName": "ToolKit",
        ]
        objects["KIT"]?["packageProductDependencies"] = ["COREPRODUCT"]
        objects["TOOL"]?["packageProductDependencies"] = ["TOOLKITPRODUCT"]
    }

    /// Writes the shared scheme App, whose build action builds the targets `buildingForTesting` for testing, and whose
    /// test action tests `testing` and its test plans `testPlans`, all of App.xcodeproj.
    private func writeScheme(
        buildingForTesting: [String],
        testing: [String],
        testPlans: [String] = [],
        autocreatesATestPlan: Bool = false
    ) throws {
        let reference = { (id: String) in
            #"<BuildableReference BlueprintIdentifier = "\#(id)" ReferencedContainer = "container:App.xcodeproj"/>"#
        }
        let entries = buildingForTesting.map { id in
            #"<BuildActionEntry buildForTesting = "YES">\#(reference(id))</BuildActionEntry>"#
        }
            + [#"<BuildActionEntry buildForTesting = "NO">\#(reference("TOOL"))</BuildActionEntry>"#]
        let testables = testing.map { #"<TestableReference skipped = "NO">\#(reference($0))</TestableReference>"# }
        let plans = testPlans.map { #"<TestPlanReference reference = "container:\#($0)" default = "YES"/>"# }
        let autocreate = autocreatesATestPlan ? "YES" : "NO"
        let scheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version = "1.7">
        <BuildAction><BuildActionEntries>\(entries.joined())</BuildActionEntries></BuildAction>
        <TestAction shouldAutocreateTestPlan = "\(autocreate)"><TestPlans>\(plans.joined())</TestPlans>
        <Testables>\(testables.joined())</Testables></TestAction>
        <LaunchAction><BuildableProductRunnable>\(reference("TOOL"))</BuildableProductRunnable></LaunchAction>
        </Scheme>
        """
        let folder = root + "/App.xcodeproj/xcshareddata/xcschemes"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try scheme.write(toFile: folder + "/App.xcscheme", atomically: true, encoding: .utf8)
    }
}
