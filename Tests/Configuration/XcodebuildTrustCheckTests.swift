@testable import muterCore
import XCTest

final class XcodebuildTrustCheckTests: MuterTestCase {
    private var root = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try makeTemporaryDirectory()
    }

    // A target that uses a package's plugin, as Xcode writes it: the product's name is `plugin:` and the plugin's.
    func test_aProjectWhoseTargetUsesAPackagePlugin_needsThePluginCheckSkipped() throws {
        let project = try write(Self.projectUsingSwiftLintPlugin, to: "App.xcodeproj/project.pbxproj")

        XCTAssertEqual(XcodebuildTrustCheck.needed(by: [project]), [.packagePlugins])
    }

    // swift-syntax in any of the resolved files Xcode or SwiftPM keeps: a macro package depends on it.
    func test_aResolvedFileNamingSwiftSyntax_needsTheMacroCheckSkipped() throws {
        for path in [
            "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "App.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "Package.resolved",
        ] {
            let resolved = try write(Self.resolvedWithSwiftSyntax, to: path)

            XCTAssertEqual(XcodebuildTrustCheck.needed(by: [resolved]), [.macros], path)
        }
    }

    // A local package's manifest that declares a macro, or declares or uses a plugin.
    func test_aManifestWithAMacroOrAPluginTarget_needsItsCheckSkipped() throws {
        let macro = try write(
            #".macro(name: "MacrosImpl", dependencies: [.product(name: "SwiftSyntaxMacros", package: "Syntax")])"#,
            to: "Macros/Package.swift"
        )
        let plugin = try write(
            #"plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]"#,
            to: "Core/Package@swift-6.0.swift"
        )

        XCTAssertEqual(XcodebuildTrustCheck.needed(by: [macro]), [.macros])
        XCTAssertEqual(XcodebuildTrustCheck.needed(by: [plugin]), [.packagePlugins])
        XCTAssertEqual(XcodebuildTrustCheck.needed(by: [macro, plugin]), [.packagePlugins, .macros])
    }

    // A project with neither, whose package products are libraries, and whose resolved file names no swift-syntax.
    func test_aProjectWithNeither_needsNoCheckSkipped() throws {
        let project = try write(
            Self.projectUsingSwiftLintPlugin.replacingOccurrences(of: "plugin:SwiftLint", with: "Alamofire"),
            to: "App.xcodeproj/project.pbxproj"
        )
        let resolved = try write(
            Self.resolvedWithSwiftSyntax.replacingOccurrences(of: "swift-syntax", with: "alamofire"),
            to: "Package.resolved"
        )
        let manifest = try write(#".target(name: "Core")"#, to: "Package.swift")

        XCTAssertEqual(XcodebuildTrustCheck.needed(by: [project, resolved, manifest]), [])
    }

    // Only files of those names are read: a source file that mentions swift-syntax or a plugin says nothing.
    func test_otherFiles_areNotRead() throws {
        let source = try write(
            #"// productName = "plugin:X"; swift-syntax .macro( .plugin("#,
            to: "Sources/A.swift"
        )

        XCTAssertEqual(XcodebuildTrustCheck.needed(by: [source]), [])
    }

    // A dependency's checkout describes the dependency's build, so its manifest and resolved file are left out.
    func test_filesInADependencysCheckout_areLeftOut() throws {
        let checkouts = try [
            write(Self.resolvedWithSwiftSyntax, to: ".build/checkouts/Lib/Package.resolved"),
            write(".plugin(", to: ".build/checkouts/Lib/Package.swift"),
            write(".macro(", to: "SourcePackages/checkouts/Lib/Package.swift"),
        ]

        XCTAssertEqual(XcodebuildTrustCheck.needed(by: checkouts), [])
    }

    // Only the path below the project's folder says it is a checkout: a project that is itself in one, as a CI
    // runner's may be, still has its own files read.
    func test_aProjectInAFolderNamedLikeACheckout_stillHasItsFilesRead() throws {
        let directory = "SourcePackages/App"
        _ = try write(Self.projectUsingSwiftLintPlugin, to: "\(directory)/App.xcodeproj/project.pbxproj")
        let base = URL(fileURLWithPath: "\(root)/\(directory)", isDirectory: true)
        let project = URL(fileURLWithPath: "App.xcodeproj/project.pbxproj", relativeTo: base)

        XCTAssertEqual(XcodebuildTrustCheck.needed(by: [project]), [.packagePlugins])
    }

    // A file that can't be read is passed over.
    func test_aFileThatCantBeRead_isPassedOver() {
        let missing = URL(fileURLWithPath: "\(root)/App.xcodeproj/project.pbxproj")

        XCTAssertEqual(XcodebuildTrustCheck.needed(by: [missing]), [])
    }

    func test_skippedBy_findsTheChecksWhoseArgumentIsGiven_inOrder() {
        XCTAssertEqual(
            XcodebuildTrustCheck.skipped(by: ["-skipMacroValidation", "test", "-skipPackagePluginValidation"]),
            [.packagePlugins, .macros]
        )
        XCTAssertEqual(XcodebuildTrustCheck.skipped(by: ["-skipMacroValidation"]), [.macros])
        XCTAssertEqual(XcodebuildTrustCheck.skipped(by: ["test"]), [])
    }

    private func write(_ contents: String, to path: String) throws -> URL {
        let url = URL(fileURLWithPath: "\(root)/\(path)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The part of a `project.pbxproj` that names a target's plugin, in Xcode's form, as CodeEdit's project has it.
    static let projectUsingSwiftLintPlugin = """
    /* Begin XCSwiftPackageProductDependency section */
    		6C7B1C752A1D57CE005CBBFC /* SwiftLint */ = {
    			isa = XCSwiftPackageProductDependency;
    			package = 287136B1292A407E00E9F5F4 /* XCRemoteSwiftPackageReference "SwiftLintPlugin" */;
    			productName = "plugin:SwiftLint";
    		};
    /* End XCSwiftPackageProductDependency section */
    """

    /// A `Package.resolved` of version 3, as Xcode 16 writes it, with swift-syntax pinned.
    static let resolvedWithSwiftSyntax = """
    {
      "originHash" : "01191ca9685501db65981a6fd21ab2d11c32196633d4cb776b5bb25908ed212f",
      "pins" : [
        {
          "identity" : "swift-syntax",
          "kind" : "remoteSourceControl",
          "location" : "https://github.com/swiftlang/swift-syntax.git",
          "state" : {
            "revision" : "0687f71944021d616d34d922343dcef086855920",
            "version" : "600.0.1"
          }
        }
      ],
      "version" : 3
    }
    """
}
