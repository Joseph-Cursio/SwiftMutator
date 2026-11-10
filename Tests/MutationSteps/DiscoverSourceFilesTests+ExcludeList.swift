import Foundation
@testable import muterCore
import TestingExtensions

extension DiscoverSourceFilesTests {
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
        state.muterConfiguration = MuterConfiguration(
            executable: "",
            arguments: [],
            excludeList: ["Sources/**/*.swift"]
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(root.path)/Other.swift"])])
    }
}
