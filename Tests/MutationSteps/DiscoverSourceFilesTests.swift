@testable import muterCore
import TestingExtensions
import XCTest

final class DiscoverSourceFilesTests: MuterTestCase {
    private lazy var sut = DiscoverSourceFiles()

    private var state = MutationTestState()
    private lazy var filesToMutatePath = "\(self.fixturesDirectory)/FilesToMutate"
    private lazy var filsToDiscoverPath = "\(self.fixturesDirectory)/FilesToDiscover"

    func test_discoveredFilesShouldBeSortedAlphabetically() async throws {
        current.fileManager = FileManager.default

        state.mutatedProjectDirectoryURL = URL(
            fileURLWithPath: filsToDiscoverPath,
            isDirectory: true
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(filsToDiscoverPath)/Directory1/file3.swift",
                "\(filsToDiscoverPath)/Directory2/Directory3/file6.swift",
                "\(filsToDiscoverPath)/ExampleApp/ExampleAppCode.swift",
                "\(filsToDiscoverPath)/ExampleSpec.swift",
                "\(filsToDiscoverPath)/file1.swift",
                "\(filsToDiscoverPath)/file2.swift",
            ]),
        ])
    }

    func test_exclusionList() async throws {
        current.fileManager = FileManager.default

        state.muterConfiguration = MuterConfiguration(
            executable: "",
            arguments: [],
            excludeList: ["ExampleApp"]
        )

        state.mutatedProjectDirectoryURL = URL(
            fileURLWithPath: filsToDiscoverPath,
            isDirectory: true
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(filsToDiscoverPath)/Directory1/file3.swift",
                "\(filsToDiscoverPath)/Directory2/Directory3/file6.swift",
                "\(filsToDiscoverPath)/ExampleSpec.swift",
                "\(filsToDiscoverPath)/file1.swift",
                "\(filsToDiscoverPath)/file2.swift",
            ]),
        ])
    }

    func test_exclusionListWithGlobExpression() async throws {
        current.fileManager = FileManager.default

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: filesToMutatePath, isDirectory: true)
        state.muterConfiguration = MuterConfiguration(
            executable: "",
            arguments: [],
            excludeList: [
                "/Directory2/**/*.swift",
                "file1.swift",
                "/ProjectName/**/*.swift",
            ]
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(filesToMutatePath)/ExampleApp/ExampleAppCode.swift",
            ]),
        ])
    }

    // A glob leaves out only the files it matches. Expanded against the project, it gives full paths, which the
    // relative paths discovery walks never contained, so no glob used to leave out anything.
    func test_exclusionListWithGlobExpression_leavesOutOnlyTheFilesItMatches() async throws {
        current.fileManager = FileManager.default

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: filesToMutatePath, isDirectory: true)
        state.muterConfiguration = MuterConfiguration(
            executable: "",
            arguments: [],
            excludeList: ["/ProjectName/**/Models/*.swift", "Directory5/*.swift"]
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(filesToMutatePath)/Directory2/Directory3/file6.swift",
                "\(filesToMutatePath)/ExampleApp/ExampleAppCode.swift",
                "\(filesToMutatePath)/ProjectName/AnotherFolder/Module.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/AppDelegate.swift",
                "\(filesToMutatePath)/file1.swift",
            ]),
        ])
    }

    // As the README tells it: `**/` stands for any number of folders, none included, and `*` stays within one folder.
    func test_exclusionListWithGlobExpression_matchesFoldersAsDocumented() async throws {
        current.fileManager = FileManager.default

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: filesToMutatePath, isDirectory: true)
        state.muterConfiguration = MuterConfiguration(
            executable: "",
            arguments: [],
            excludeList: ["**/file1.swift", "ProjectName/*.swift", "ProjectName/*/**/file 2.swift"]
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(filesToMutatePath)/Directory2/Directory3/file6.swift",
                "\(filesToMutatePath)/ExampleApp/ExampleAppCode.swift",
                "\(filesToMutatePath)/ProjectName/AnotherFolder/Module.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/AppDelegate.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/Models/file 1.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/Models/file 3.swift",
            ]),
        ])
    }

    // A glob is matched against each file's path in the project, so the project folder's own name, where `[`, `]`,
    // `{` and `}` would be pattern characters, takes no part.
    func test_exclusionListWithGlobExpression_inAProjectFolderNamedWithPatternCharacters() async throws {
        current.fileManager = FileManager.default
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscoverSourceFilesTests-\(UUID().uuidString)")
            .appendingPathComponent("{Client} App [old]")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/App"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for file in ["Sources/App/A.swift", "Other.swift"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(file).path, contents: Data())
        }

        state.mutatedProjectDirectoryURL = root
        state.muterConfiguration = MuterConfiguration(executable: "", arguments: [], excludeList: ["Sources/**/*.swift"])

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(root.path)/Other.swift"])])
    }

    func test_shouldIgnoreFilesWithoutCoverage() async throws {
        current.fileManager = FileManager.default

        state.muterConfiguration = MuterConfiguration(executable: "", arguments: [])
        state.mutatedProjectDirectoryURL = URL(
            fileURLWithPath: filsToDiscoverPath,
            isDirectory: true
        )

        state.projectCoverage = Coverage.make(
            filesWithoutCoverage: [
                "\(filsToDiscoverPath)/ExampleApp/ExampleAppCode.swift",
                "\(filsToDiscoverPath)/Directory2/Directory3/file6.swift",
            ]
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(filsToDiscoverPath)/Directory1/file3.swift",
                "\(filsToDiscoverPath)/ExampleSpec.swift",
                "\(filsToDiscoverPath)/file1.swift",
                "\(filsToDiscoverPath)/file2.swift",
            ]),
        ])
    }

    // As SwiftPM's coverage names them. It used to give paths relative to the files' common folder, which never
    // matched, so no file was ever left out for having no coverage.
    func test_shouldIgnoreFilesWithoutCoverage_givenByTheirPathInTheProject() async throws {
        current.fileManager = FileManager.default

        state.muterConfiguration = MuterConfiguration(executable: "", arguments: [])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: filsToDiscoverPath, isDirectory: true)
        state.projectCoverage = Coverage.make(
            filesWithoutCoverage: ["ExampleApp/ExampleAppCode.swift", "Directory2/Directory3/file6.swift"]
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(filsToDiscoverPath)/Directory1/file3.swift",
                "\(filsToDiscoverPath)/ExampleSpec.swift",
                "\(filsToDiscoverPath)/file1.swift",
                "\(filsToDiscoverPath)/file2.swift",
            ]),
        ])
    }

    func test_shouldIgnoreFilesWithoutCoverage_reportedThroughASymbolicLink() async throws {
        current.fileManager = FileManager.default

        // How xcodebuild reports a project SwiftMutator found in `/private/tmp`: by its `/tmp` path.
        let (directory, link) = try makeDirectoryWithSymbolicLink()
        try makeProjectWithCoveredAndUncoveredFiles(in: directory)

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "\(directory)/Project", isDirectory: true)
        state.projectCoverage = Coverage.make(
            filesWithoutCoverage: ["\(link)/Project/Uncovered.swift"]
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered(["\(directory)/Project/Covered.swift"]),
        ])
    }

    func test_shouldIgnoreFilesWithoutCoverage_inAProjectReachedThroughASymbolicLink() async throws {
        current.fileManager = FileManager.default

        let (directory, link) = try makeDirectoryWithSymbolicLink()
        try makeProjectWithCoveredAndUncoveredFiles(in: directory)

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "\(link)/Project", isDirectory: true)
        state.projectCoverage = Coverage.make(
            filesWithoutCoverage: ["\(directory)/Project/Uncovered.swift"]
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered(["\(link)/Project/Covered.swift"]),
        ])
    }

    func test_versionedPackageManifestsAreExcluded() async throws {
        current.fileManager = FileManager.default

        // Every `swift test` run in a worker folder has one environment, so SwiftPM reuses the baseline's
        // cached manifest and a mutant in any manifest, versioned or not, never switches on.
        let project = try makeTemporaryDirectory()
        try makeFiles(
            [
                "Package.swift",
                "Package@swift-5.9.swift",
                "Package@swift-6.0.swift",
                "LocalPackages/Dependency/Package.swift",
                "LocalPackages/Dependency/Package@swift-6.0.swift",
                "Sources/Library/Library.swift",
            ],
            in: project
        )

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered(["\(project)/Sources/Library/Library.swift"]),
        ])
    }

    // Describe is asked for only when the build system is swift, by the executable's name or by `buildSystem:`, so not
    // even `swift` is asked when `buildSystem:` says otherwise. For any other build system the walk is no fallback, and
    // nothing is said.
    func test_aProjectNotTestedWithSwift_isWalked_withoutAWarning() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["Sources/App.swift"], in: project)
        var warnings: [String] = []
        let observer = notificationCenter.addObserver(
            forName: .packageSourceFilesUnavailable, object: nil, queue: nil
        ) { warnings.append($0.object as? String ?? "") }
        defer { notificationCenter.removeObserver(observer) }
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        for configuration in [
            MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"]),
            MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], buildSystem: .xcodebuild),
        ] {
            state.muterConfiguration = configuration

            let result = try await sut.run(with: state)

            XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/Sources/App.swift"])])
        }
        XCTAssertEqual(process.commandsRun, [])
        XCTAssertEqual(warnings, [])
    }

    // Stopping the run kills describe, which then reads as failed: no warning is due, and the project isn't walked.
    func test_aDescribeTheStopKilled_throwsCancellation() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["Sources/Lib/Lib.swift"], in: project)
        process.commandResult = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return CommandResult(status: 9, endedBySignal: true, output: "", errors: "")
        }
        var warnings: [String] = []
        let observer = notificationCenter.addObserver(
            forName: .packageSourceFilesUnavailable, object: nil, queue: nil
        ) { warnings.append($0.object as? String ?? "") }
        defer { notificationCenter.removeObserver(observer) }
        var listed = false
        current.listProjectFiles = { _ in
            listed = true
            return nil
        }

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        let result = await Task { [sut, state] in try await sut.run(with: state) }.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(warnings, [])
        XCTAssertFalse(listed)
    }

    // An example app's files, and a tool's in a hidden folder, are in no target, so no test could kill their mutants.
    func test_aSwiftPMProject_onlyTheFilesItsTargetsCompile() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(
            [
                "Sources/Lib/Lib.swift",
                "Tests/LibTests/LibTests.swift",
                "ExampleCode/Example.swift",
                ".swiftinfer/Inferred.swift",
            ],
            in: project
        )
        describing(project, as: [
            target("library", path: "Sources/Lib", sources: ["Lib.swift"]),
            target("test", path: "Tests/LibTests", sources: ["LibTests.swift"]),
        ])
        let describedIn = workingDirectoriesOfDescribe()
        let workingDirectory = FileManager.default.currentDirectoryPath

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/Sources/Lib/Lib.swift"])])
        XCTAssertEqual(process.commandsRun, [
            ["/usr/bin/swift", "package", "--package-path", project, "describe", "--type", "json"],
        ])
        // As the coverage run and the tests are.
        XCTAssertEqual(describedIn.paths, [project.canonicalPath])
        XCTAssertEqual(FileManager.default.currentDirectoryPath, workingDirectory)
    }

    // The tests are those of the package the test command names, not of the tools' package at the project's root.
    func test_aSwiftPMProject_thePackageTheTestCommandNames() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["Sources/Tool/main.swift", "Packages/App/Sources/App/App.swift"], in: project)
        describing(project + "/Packages/App", as: [target("library", path: "Sources/App", sources: ["App.swift"])])

        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test", "--package-path", "Packages/App"]
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/Packages/App/Sources/App/App.swift"])])
    }

    // A test helper target under `Tests` is a library, so the default list still leaves it out.
    func test_aSwiftPMProject_theExcludeListAndCoverageStillApply() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(
            [
                "Sources/Lib/Lib.swift",
                "Sources/Lib/Generated.swift",
                "Sources/Lib/Uncovered.swift",
                "Tests/Support/Stub.swift",
            ],
            in: project
        )
        describing(project, as: [
            target("library", path: "Sources/Lib", sources: ["Generated.swift", "Lib.swift", "Uncovered.swift"]),
            target("library", path: "Tests/Support", sources: ["Stub.swift"]),
        ])

        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            excludeList: ["Generated.swift"]
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.projectCoverage = Coverage.make(filesWithoutCoverage: ["Sources/Lib/Uncovered.swift"])

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/Sources/Lib/Lib.swift"])])
    }

    func test_aSwiftPMProject_thatCantBeDescribed_everyFileInTheProject_andAWarning() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["Sources/Lib/Lib.swift", "ExampleCode/Example.swift"], in: project)
        process.commandResult = { _ in
            CommandResult(status: 1, endedBySignal: false, output: "", errors: "error: invalid manifest\n")
        }
        var warnings: [String] = []
        let observer = notificationCenter.addObserver(
            forName: .packageSourceFilesUnavailable, object: nil, queue: nil
        ) { warnings.append($0.object as? String ?? "") }
        defer { notificationCenter.removeObserver(observer) }

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(project)/ExampleCode/Example.swift",
                "\(project)/Sources/Lib/Lib.swift",
            ]),
        ])
        XCTAssertEqual(warnings, ["`swift package describe` failed for \(project): error: invalid manifest"])
    }

    func test_whenDoesntDiscoverFilesInProjectDirectory() async throws {
        state.mutatedProjectDirectoryURL = URL(
            fileURLWithPath: "\(filsToDiscoverPath)/Directory4",
            isDirectory: true
        )

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .noSourceFilesDiscovered
        )
    }

    func test_listOfFilesToMutate() async throws {
        fileManager.subpathsToReturn = []

        state.filesToMutate = [
            "file1.swift",
            "file2.swift",
            "/Directory2/Directory3/file6.swift",
        ]

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: filesToMutatePath, isDirectory: true)
        fileManager.fileExistsToReturn = state.filesToMutate.compactMap { _ in true }

        sut = DiscoverSourceFiles()

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(filesToMutatePath)/Directory2/Directory3/file6.swift",
                "\(filesToMutatePath)/file1.swift",
                "\(filesToMutatePath)/file2.swift",
            ]),
        ])
    }

    func test_listOfFileToMutateWithGlobExpression() async throws {
        current.fileManager = FileManager.default

        state.filesToMutate = [
            "/Directory2/**/*.swift",
            "file1.swift",
            "/ExampleApp/*.swift",
        ]

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: filesToMutatePath, isDirectory: true)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(filesToMutatePath)/Directory2/Directory3/file6.swift",
                "\(filesToMutatePath)/ExampleApp/ExampleAppCode.swift",
                "\(filesToMutatePath)/file1.swift",
            ]),
        ])
    }

    func test_listOfFileToMutateWithRelativePaths() async throws {
        current.fileManager = FileManager.default

        let currentDirectoryPath = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(filesToMutatePath)

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: filesToMutatePath, isDirectory: true)
        state.filesToMutate = [
            "./ProjectName/ProjectName/AppDelegate.swift",
            "../ProjectName/AnotherFolder/Module.swift",
            "./*.swift",
            "./ProjectName/ProjectName/Models/*.swift",
            "./**/*.swift",
        ]

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(filesToMutatePath)/Directory2/Directory3/file6.swift",
                "\(filesToMutatePath)/Directory5/file1.swift",
                "\(filesToMutatePath)/ExampleApp/ExampleAppCode.swift",
                "\(filesToMutatePath)/ProjectName/AnotherFolder/Module.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/AppDelegate.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/AppDelegate.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/Models/file 1.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/Models/file 1.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/Models/file 2.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/Models/file 2.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/Models/file 3.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/Models/file 3.swift",
                "\(filesToMutatePath)/file1.swift",
            ]),
        ])

        FileManager.default.changeCurrentDirectoryPath(currentDirectoryPath)
    }

    func test_listOfFileToMutateWithoutGlobExpressions() async throws {
        fileManager.subpathsToReturn = []

        state.filesToMutate = ["file1.swift", "file2.swift", "/Directory2/Directory3/file6.swift"]
        state.mutatedProjectDirectoryURL = URL(
            fileURLWithPath: filesToMutatePath,
            isDirectory: true
        )

        fileManager.fileExistsToReturn = state.filesToMutate.compactMap { _ in true }

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(filesToMutatePath)/Directory2/Directory3/file6.swift",
                "\(filesToMutatePath)/file1.swift",
                "\(filesToMutatePath)/file2.swift",
            ]),
        ])

        XCTAssertEqual(fileManager.methodCalls, [
            "fileExists(atPath:)",
            "fileExists(atPath:)",
            "fileExists(atPath:)",
        ])
    }

    func test_fileNotFoundFailure() async throws {
        state.filesToMutate = ["doesntExist.swift"]
        state.mutatedProjectDirectoryURL = URL(
            fileURLWithPath: filesToMutatePath,
            isDirectory: true
        )

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .noSourceFilesOnExclusiveList
        )
    }

    func test_noSwiftFileFailure() async throws {
        state.filesToMutate = ["/Directory2/Directory3/file6"]
        state.mutatedProjectDirectoryURL = URL(
            fileURLWithPath: filesToMutatePath,
            isDirectory: true
        )

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .noSourceFilesOnExclusiveList
        )
    }

    private func makeFiles(_ files: [String], in directory: String) throws {
        for file in files {
            let path = "\(directory)/\(file)"
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: path, contents: Data())
        }
    }

    /// Answers `swift package describe` of the package at `path` with `targets`.
    private func describing(_ path: String, as targets: [String]) {
        let description = """
        {"name": "Project", "path": "\(path)", "dependencies": [], "targets": [\(targets.joined(separator: ", "))]}
        """
        process.commandResult = { command in
            command.contains(path) && command.contains("describe")
                ? CommandResult(status: 0, endedBySignal: false, output: description, errors: "")
                : nil
        }
    }

    /// The working directory, with its links resolved, of each describe the process spy answers, which it then
    /// answers as before.
    private func workingDirectoriesOfDescribe() -> WorkingDirectories {
        let recorded = WorkingDirectories()
        let answer = process.commandResult
        process.commandResult = { command in
            recorded.paths.append(FileManager.default.currentDirectoryPath.canonicalPath)
            return answer(command)
        }
        return recorded
    }

    private final class WorkingDirectories {
        var paths: [String] = []
    }

    private func target(_ type: String, path: String, sources: [String]) -> String {
        let sources = sources.map { "\"\($0)\"" }.joined(separator: ", ")
        return #"{"name": "Target", "type": "\#(type)", "path": "\#(path)", "sources": [\#(sources)]}"#
    }

    private func makeProjectWithCoveredAndUncoveredFiles(in directory: String) throws {
        try FileManager.default.createDirectory(
            atPath: "\(directory)/Project",
            withIntermediateDirectories: true
        )

        for file in ["Covered.swift", "Uncovered.swift"] {
            FileManager.default.createFile(atPath: "\(directory)/Project/\(file)", contents: Data())
        }
    }
}
