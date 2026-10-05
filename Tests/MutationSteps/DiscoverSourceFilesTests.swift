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
                "\(filesToMutatePath)/Directory2/Directory3/file6.swift",
                "\(filesToMutatePath)/ExampleApp/ExampleAppCode.swift",
                "\(filesToMutatePath)/ProjectName/AnotherFolder/Module.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/AppDelegate.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/Models/file 1.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/Models/file 2.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/Models/file 3.swift",
            ]),
        ])
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
