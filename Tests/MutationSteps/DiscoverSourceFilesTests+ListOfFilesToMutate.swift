import Foundation
@testable import muterCore
import TestingExtensions

extension DiscoverSourceFilesTests {
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
                "\(filesToMutatePath)/ProjectName/ProjectName/Models/file 1.swift",
                "\(filesToMutatePath)/ProjectName/ProjectName/Models/file 2.swift",
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
            "isDirectory(atPath:)",
            "isDirectory(atPath:)",
            "isDirectory(atPath:)",
            "fileExists(atPath:)",
            "fileExists(atPath:)",
            "fileExists(atPath:)",
        ])
    }
}
