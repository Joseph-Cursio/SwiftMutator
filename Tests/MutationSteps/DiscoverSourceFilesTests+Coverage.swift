@testable import muterCore
import TestingExtensions
import XCTest

extension DiscoverSourceFilesTests {
    /// Coverage has no regions for a global's or a static property's value, so its data doesn't name a file of nothing
    /// else, though the tests can read them. A file with code that it doesn't name is in no binary the tests ran.
    func test_keepsAFileOfValuesOnly_besideAFileTheCoverageNames_andNoOther() async throws {
        current.fileManager = FileManager.default
        let root = try URL(fileURLWithPath: makeTemporaryDirectory()).resolvingSymlinksInPath()
        let values = "public enum Limits { public static let big = Int.max > 1 }\n"
        for (path, code) in [
            ("Sources/Lib/Lib.swift", "public func lib() {}\n"),
            ("Sources/Lib/Constants.swift", values),
            ("Sources/Lib/Nested/Keys.swift", values),
            ("Sources/Lib/Unlinked.swift", "public func notInTheTests() {}\n"),
            ("Sources/Other/Constants.swift", values),
            ("TopLevel.swift", values),
        ] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try code.write(to: file, atomically: true, encoding: .utf8)
        }
        state.muterConfiguration = MuterConfiguration(executable: "", arguments: [])
        state.mutatedProjectDirectoryURL = root
        state.projectCoverage = Coverage.make(filesInCoverage: ["Sources/Lib/Lib.swift"])

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(root.path)/Sources/Lib/Constants.swift",
                "\(root.path)/Sources/Lib/Lib.swift",
                "\(root.path)/Sources/Lib/Nested/Keys.swift",
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

        // Their mutants are counted as not covered.
        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(filsToDiscoverPath)/Directory1/file3.swift",
                "\(filsToDiscoverPath)/file1.swift",
                "\(filsToDiscoverPath)/file2.swift",
            ]),
            .uncoveredSourceFilesDiscovered([
                "\(filsToDiscoverPath)/Directory2/Directory3/file6.swift",
                "\(filsToDiscoverPath)/ExampleApp/ExampleAppCode.swift",
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

        // Their mutants are counted as not covered.
        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(filsToDiscoverPath)/Directory1/file3.swift",
                "\(filsToDiscoverPath)/file1.swift",
                "\(filsToDiscoverPath)/file2.swift",
            ]),
            .uncoveredSourceFilesDiscovered([
                "\(filsToDiscoverPath)/Directory2/Directory3/file6.swift",
                "\(filsToDiscoverPath)/ExampleApp/ExampleAppCode.swift",
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
            .uncoveredSourceFilesDiscovered(["\(directory)/Project/Uncovered.swift"]),
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
            .uncoveredSourceFilesDiscovered(["\(link)/Project/Uncovered.swift"]),
        ])
    }
}
