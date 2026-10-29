@testable import muterCore
import XCTest

final class SwiftPackageSourcesTests: MuterTestCase {
    private let swift = "/path/to/swift"
    private var arguments = ["test"]

    // As `swift package describe --type json` gives each type of target, from a package that has one of each.
    func test_listsTheSwiftFilesOfEveryTarget_butTestsPluginsAndSnippets() {
        let targets = [
            target("executable", path: "Sources/Tool", sources: ["main.swift"]),
            target("macro", path: "Sources/Macros", sources: ["Macros.swift"]),
            target("test", path: "Tests/LibTests", sources: ["LibTests.swift"]),
            target("library", path: "Sources/Lib", sources: ["Lib.swift", "Models/Model.swift", "shim.c"]),
            target("plugin", path: "Plugins/Generate", sources: ["plugin.swift"]),
            target("snippet", path: "Snippets", sources: ["Snippet.swift"]),
            #"{"name": "Binary", "type": "binary"}"#,
        ]
        describing(["/project": targets])

        let files = files(in: "/project")

        XCTAssertEqual(files, .success([
            "Sources/Lib/Lib.swift",
            "Sources/Lib/Models/Model.swift",
            "Sources/Macros/Macros.swift",
            "Sources/Tool/main.swift",
        ]))
        XCTAssertEqual(process.commandsRun, [
            [swift, "package", "--package-path", "/project", "describe", "--type", "json"],
        ])
    }

    func test_aTargetAtItsPackagesRoot() {
        describing(["/project": [target("library", path: ".", sources: ["Root.swift"])]])

        XCTAssertEqual(files(in: "/project"), .success(["Root.swift"]))
    }

    // A local package in the project that the package depends on is built with it, and its files are copied with the
    // project, so its own local packages are described too. One outside the project isn't copied, even if its path
    // starts with the project's, and a package from a repository has no path.
    func test_theLocalPackagesInTheProject_thatThePackageDependsOn_areListedToo() {
        describing(
            [
                "/project": [target("library", path: "Sources/App", sources: ["App.swift"])],
                "/project/Packages/Core": [
                    target("library", path: "Sources/Core", sources: ["Core.swift"]),
                    target("test", path: "Tests/CoreTests", sources: ["CoreTests.swift"]),
                ],
                "/project/Packages/Util": [target("library", path: "Sources/Util", sources: ["Util.swift"])],
            ],
            dependencies: [
                "/project": ["/project/Packages/Core", "/elsewhere/Shared", "/project2/Shared", nil],
                "/project/Packages/Core": ["/project/Packages/Util"],
                // Back to Core, which is described only once.
                "/project/Packages/Util": ["/project/Packages/Core"],
            ]
        )

        XCTAssertEqual(files(in: "/project"), .success([
            "Packages/Core/Sources/Core/Core.swift",
            "Packages/Util/Sources/Util/Util.swift",
            "Sources/App/App.swift",
        ]))
        XCTAssertEqual(process.commandsRun.compactMap { $0.dropFirst(3).first }.sorted(), [
            "/project", "/project/Packages/Core", "/project/Packages/Util",
        ])
    }

    // The tests are those of the package the test command names, run from the project's folder, which may hold another
    // package, such as one for the project's tools.
    func test_thePackageTheTestCommandNames_isDescribed() {
        describing([
            "/project": [target("executable", path: "Sources/Tool", sources: ["main.swift"])],
            "/project/Packages/App": [target("library", path: "Sources/App", sources: ["App.swift"])],
        ])

        let givenPaths = [
            ["--package-path", "Packages/App"],
            ["--package-path=Packages/App"],
            ["--package-path", "/project/Packages/App"],
        ]
        for given in givenPaths {
            arguments = ["test"] + given + ["--parallel"]

            XCTAssertEqual(files(in: "/project"), .success(["Packages/App/Sources/App/App.swift"]), "\(given)")
        }
    }

    func test_thePackageTheTestCommandNames_canBeTheProjectsOwn() {
        describing(["/project": [target("library", path: "Sources/Lib", sources: ["Lib.swift"])]])

        let givenPaths = [
            ["--package-path", "."],
            ["--package-path=."],
            ["--package-path", "/project"],
            ["--package-path", "Packages/.."],
        ]
        for given in givenPaths {
            arguments = ["test"] + given

            XCTAssertEqual(files(in: "/project"), .success(["Sources/Lib/Lib.swift"]), "\(given)")
        }
        XCTAssertEqual(Set(process.commandsRun.compactMap { $0.dropFirst(3).first }), ["/project"])
    }

    // A package in a folder of the project, which holds the tests, can depend on the one at its root: its files are
    // built and tested too.
    func test_thePackageAtTheProjectsRoot_isListed_whenTheTestedPackageDependsOnIt() {
        arguments = ["test", "--package-path", "Integration"]
        describing(
            [
                "/project": [target("library", path: "Sources/Core", sources: ["Core.swift"])],
                "/project/Integration": [
                    target("library", path: "Sources/Glue", sources: ["Glue.swift"]),
                    target("test", path: "Tests/IntegrationTests", sources: ["IntegrationTests.swift"]),
                ],
            ],
            dependencies: ["/project/Integration": ["/project"]]
        )

        XCTAssertEqual(files(in: "/project"), .success([
            "Integration/Sources/Glue/Glue.swift",
            "Sources/Core/Core.swift",
        ]))
    }

    func test_aPackageTheTestCommandNamesOutsideTheProject_isNotDescribed() {
        arguments = ["test", "--package-path", "../Elsewhere"]

        let files = files(in: "/project")

        XCTAssertEqual(files, .failure(.packageOutsideProject("../Elsewhere")))
        XCTAssertEqual(files.failure?.reason, "the package the test command names, ../Elsewhere, isn't in the project")
        XCTAssertEqual(process.commandsRun, [])
    }

    // Where the tests can't use the sandbox, as in a container, nor can describe compile the manifest in one. The flags
    // the manifest is compiled with can add or take out targets in `#if` blocks.
    func test_theTestCommandsSandboxAndManifestOptions_areForwarded() {
        arguments = [
            "test", "-Xmanifest", "-DWITH_EXTRA", "--disable-sandbox", "--filter", "AppTests",
            "-Xbuild-tools-swiftc=-DTOOLS", "-Xswiftc", "-DNOT_FOR_THE_MANIFEST",
        ]
        describing(["/project": [target("library", path: "Sources/App", sources: ["App.swift"])]])

        XCTAssertEqual(files(in: "/project"), .success(["Sources/App/App.swift"]))
        XCTAssertEqual(process.commandsRun, [
            [
                swift, "package", "--package-path", "/project",
                "-Xmanifest", "-DWITH_EXTRA", "--disable-sandbox", "-Xbuild-tools-swiftc=-DTOOLS",
                "describe", "--type", "json",
            ],
        ])
    }

    // A wrapper may run anything with describe's arguments, even the tests.
    func test_aTestCommandThatIsntSwift_isNotAskedToDescribe() {
        let files = SwiftPackageSources.files(
            inProjectAt: "/project",
            testedBy: MuterConfiguration(executable: "/usr/bin/env", arguments: ["swift", "test"], buildSystem: .swift),
            process: { self.process }
        )

        XCTAssertEqual(files, .failure(.notSwift("/usr/bin/env")))
        XCTAssertEqual(files.failure?.reason, "the test command, /usr/bin/env, isn't swift")
        XCTAssertEqual(process.commandsRun, [])
    }

    // Without a manifest in the folder it's given, SwiftPM describes the first package in the folders above, whose
    // targets' paths are relative to it.
    func test_aPackageThatSwiftPMFoundAboveTheFolder_isRefused() {
        let elsewhere = description(path: "/", targets: [target("library", path: "Sources/X", sources: [])])
        process.commandResult = { _ in self.result(output: elsewhere) }

        let files = files(in: "/project")

        XCTAssertEqual(files, .failure(.noPackage(packagePath: "/project")))
        XCTAssertEqual(files.failure?.reason, "there's no Package.swift in /project")
    }

    func test_aPackageThatCantBeDescribed_failsWithTheErrorDescribeGave() {
        process.commandResult = { _ in
            self.result(status: 1, errors: "warning: an old cache\nerror: Could not find Package.swift in /project\n")
        }

        let files = files(in: "/project")

        XCTAssertEqual(
            files,
            .failure(.describeFailed(packagePath: "/project", error: "error: Could not find Package.swift in /project"))
        )
        XCTAssertEqual(
            files.failure?.reason,
            "`swift package describe` failed for /project: error: Could not find Package.swift in /project"
        )
    }

    // Its files are built with the package, so listing the package's alone would leave them out.
    func test_aLocalPackageThatCantBeDescribed_failsTheWholeListing() {
        describing(
            ["/project": [target("library", path: "Sources/App", sources: ["App.swift"])]],
            dependencies: ["/project": ["/project/Packages/Core"]]
        )

        XCTAssertEqual(
            files(in: "/project"),
            .failure(.describeFailed(packagePath: "/project/Packages/Core", error: ""))
        )
    }

    func test_whenDescribeCantBeStarted() {
        let files = files(in: "/project")

        XCTAssertEqual(files, .failure(.couldNotRun(swift)))
        XCTAssertEqual(files.failure?.reason, "/path/to/swift couldn't be started")
    }

    // Such as a description without the dependencies, which would otherwise leave the local packages out unsaid.
    func test_whenWhatDescribePrintedCantBeRead() {
        for output in ["Fetching https://example.com/dependency\n", #"{"path": "/project", "targets": []}"#] {
            process.commandResult = { _ in self.result(output: output) }

            let files = files(in: "/project")

            XCTAssertEqual(files, .failure(.unreadableDescription(packagePath: "/project")), output)
            XCTAssertEqual(
                files.failure?.reason,
                "what `swift package describe` printed for /project couldn't be read"
            )
        }
    }

    // describe lists a target's files through a link to a folder. Mutated through it, a file outside the project would
    // be rewritten where it is, and one two targets share would be mutated twice. A link to a file is replaced.
    func test_filesThroughALinkToAFolder_areListedWhereTheyAre_andThoseOutsideTheProjectAreLeftOut() throws {
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
        try fileManager.createSymbolicLink(atPath: project + "/Sources/Lib/Shared", withDestinationPath: "../../../Shared")
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

        XCTAssertEqual(files(in: projectThroughLink), .success([
            "Common/Common.swift",
            "Sources/Lib/Lib.swift",
            "Sources/Lib/Linked.swift",
        ]))
    }

    // SwiftPM's own description of a package on disk, whose local package's path it gives with links resolved, and the
    // project's through a link, as a project in `/tmp` is.
    func test_aRealPackage() throws {
        let swift = "/usr/bin/swift"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: swift), "no \(swift)")
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
                    .executableTarget(name: "Tool"),
                    .plugin(name: "Generate", capability: .buildTool()),
                    .testTarget(name: "LibTests", dependencies: ["Lib"]),
                ]
            )
            """,
            files: [
                "Sources/Lib/Lib.swift", "Sources/Tool/main.swift", "Plugins/Generate/plugin.swift",
                "Tests/LibTests/LibTests.swift", "ExampleCode/Example.swift",
            ]
        )
        try makePackage(
            in: directory + "/Packages/Core",
            manifest: """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Core",
                products: [.library(name: "Core", targets: ["Core"])],
                targets: [.target(name: "Core"), .testTarget(name: "CoreTests", dependencies: ["Core"])]
            )
            """,
            files: ["Sources/Core/Core.swift", "Tests/CoreTests/CoreTests.swift"]
        )

        let files = SwiftPackageSources.files(
            inProjectAt: link,
            testedBy: MuterConfiguration(executable: swift, arguments: ["test"]),
            process: MuterProcessFactory.makeProcess
        )

        XCTAssertEqual(files, .success([
            "Packages/Core/Sources/Core/Core.swift",
            "Sources/Lib/Lib.swift",
            "Sources/Tool/main.swift",
        ]))
    }

    private func files(in root: FilePath) -> Result<[FilePath], SwiftPackageSources.Failure> {
        SwiftPackageSources.files(
            inProjectAt: root,
            testedBy: MuterConfiguration(executable: swift, arguments: arguments),
            process: { self.process }
        )
    }

    /// Answers `swift package describe` of each package path with a description of its `targets`, whose local
    /// packages are its `dependencies` (nil for a package from a repository), and fails for any other.
    private func describing(_ targets: [String: [String]], dependencies: [String: [String?]] = [:]) {
        process.commandResult = { command in
            guard let path = command.firstIndex(of: "--package-path").map({ command[$0 + 1] }),
                  let packageTargets = targets[path]
            else {
                return self.result(status: 1)
            }
            return self.result(
                output: self.description(path: path, dependencies: dependencies[path] ?? [], targets: packageTargets)
            )
        }
    }

    /// A description as `swift package describe --type json` gives it.
    private func description(path: String, dependencies: [String?] = [], targets: [String]) -> String {
        let dependencies = dependencies.map { path in
            path.map { #"{"identity": "local", "path": "\#($0)", "type": "fileSystem"}"# }
                ?? #"{"identity": "remote", "type": "sourceControl", "url": "https://example.com/remote.git"}"#
        }
        return """
        {"name": "Project", "path": "\(path)", "dependencies": [\(dependencies.joined(separator: ", "))],
         "targets": [\(targets.joined(separator: ", "))]}
        """
    }

    private func target(_ type: String, path: String, sources: [String]) -> String {
        let sources = sources.map { "\"\($0)\"" }.joined(separator: ", ")
        return #"{"name": "Target", "type": "\#(type)", "path": "\#(path)", "sources": [\#(sources)]}"#
    }

    private func makePackage(in directory: String, manifest: String, files: [String]) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try manifest.write(toFile: directory + "/Package.swift", atomically: true, encoding: .utf8)
        try makeFiles(files, in: directory)
    }

    private func makeFiles(_ files: [String], in directory: String) throws {
        for file in files {
            let path = directory + "/" + file
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try "let value = 1\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func result(status: Int32 = 0, output: String = "", errors: String = "") -> CommandResult {
        CommandResult(status: status, endedBySignal: false, output: output, errors: errors)
    }
}

private extension Result {
    var failure: Failure? {
        guard case let .failure(failure) = self else {
            return nil
        }
        return failure
    }
}
