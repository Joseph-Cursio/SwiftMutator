@testable import muterCore
import XCTest

extension SwiftPackageSourcesTests {
    // describe lists a target's files through a link to a folder. Mutated through it, a file outside the project would
    // be rewritten where it is, and one two targets share would be mutated twice. A link to a file is replaced.
    func test_filesThroughALinkToAFolder_areListedWhereTheyAre_andThoseOutsideTheProjectAreLeftOut() async throws {
        let (directory, link) = try makeDirectoryWithSymbolicLink()
        let project = directory + "/Project"
        try makeFiles(
            ["Project/Common/Common.swift", "Project/Sources/Lib/Lib.swift", "Shared/Shared.swift"],
            in: directory
        )
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(atPath: project + "/Sources/Lib/Common", withDestinationPath: "../../Common")
        try fileManager.createDirectory(atPath: project + "/Sources/App", withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: project + "/Sources/App/Common", withDestinationPath: "../../Common")
        try fileManager.createSymbolicLink(
            atPath: project + "/Sources/Lib/Shared",
            withDestinationPath: "../../../Shared"
        )
        try fileManager.createSymbolicLink(
            atPath: project + "/Sources/Lib/Linked.swift",
            withDestinationPath: "../../../Shared/Shared.swift"
        )
        // describe gives the package's path with its links resolved.
        let projectThroughLink = link + "/Project"
        process.commandResult = { _ in
            self.result(output: self.description(path: project, targets: [
                self.target(
                    "library",
                    path: "Sources/Lib",
                    sources: ["Common/Common.swift", "Lib.swift", "Linked.swift", "Shared/Shared.swift"]
                ),
                self.target("library", path: "Sources/App", sources: ["Common/Common.swift"]),
            ]))
        }

        let result = await files(in: projectThroughLink)
        XCTAssertEqual(result, .success([
            "Common/Common.swift",
            "Sources/Lib/Lib.swift",
            "Sources/Lib/Linked.swift",
        ]))
    }

    // SwiftPM's own description of a package on disk, whose local package's path it gives with links resolved, and the
    // project's through a link, as a project in `/tmp` is, and the dependencies and products the tests reach through.
    func test_aRealPackage() async throws {
        let swiftPath = "/usr/bin/swift"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: swiftPath), "no \(swiftPath)")
        let (directory, link) = try makeDirectoryWithSymbolicLink()
        try makePackage(
            in: directory,
            manifest: """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Project",
                dependencies: [.package(path: "Packages/Core")],
                targets: [
                    .target(name: "Lib", dependencies: [.product(name: "Core", package: "Core")]),
                    .executableTarget(name: "Tool", dependencies: ["ToolKit"]),
                    .target(name: "ToolKit"),
                    .target(name: "Unused"),
                    .plugin(name: "Generate", capability: .buildTool()),
                    .testTarget(name: "LibTests", dependencies: ["Lib"]),
                ]
            )
            """,
            files: [
                "Sources/Lib/Lib.swift", "Sources/Tool/main.swift", "Sources/ToolKit/ToolKit.swift",
                "Sources/Unused/Unused.swift", "Plugins/Generate/plugin.swift", "Tests/LibTests/LibTests.swift",
                "ExampleCode/Example.swift",
            ]
        )
        try makeCorePackage(in: directory + "/Packages/Core")

        let files = await SwiftPackageSources.files(
            inProjectAt: link,
            testedBy: MuterConfiguration(executable: swiftPath, arguments: ["test"])
        ) { MuterProcessFactory.makeProcess() }

        // Unused and CoreExtras are in no target the package's tests reach, nor is ExampleCode.
        XCTAssertEqual(files, .success([
            "Packages/Core/Sources/Core/Core.swift",
            "Sources/Lib/Lib.swift",
            "Sources/Tool/main.swift",
            "Sources/ToolKit/ToolKit.swift",
        ]))
    }

    /// A package with a library product, whose own tests reach a target the product doesn't hold.
    private func makeCorePackage(in directory: String) throws {
        try makePackage(
            in: directory,
            manifest: """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Core",
                products: [.library(name: "Core", targets: ["Core"])],
                targets: [
                    .target(name: "Core"),
                    .target(name: "CoreExtras"),
                    .testTarget(name: "CoreTests", dependencies: ["Core", "CoreExtras"]),
                ]
            )
            """,
            files: ["Sources/Core/Core.swift", "Sources/CoreExtras/Extras.swift", "Tests/CoreTests/CoreTests.swift"]
        )
    }
}
