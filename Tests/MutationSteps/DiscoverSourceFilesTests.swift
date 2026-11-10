@testable import muterCore
import TestingExtensions
import XCTest

final class DiscoverSourceFilesTests: MuterTestCase {
    lazy var sut = DiscoverSourceFiles()

    var state = MutationTestState()
    lazy var filesToMutatePath = "\(self.fixturesDirectory)/FilesToMutate"
    lazy var filsToDiscoverPath = "\(self.fixturesDirectory)/FilesToDiscover"

    override func setUp() {
        super.setUp()

        // As outside a repository, unless a test lists the project's files.
        current.listProjectFiles = { _ in nil }
    }

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
                "\(filsToDiscoverPath)/file1.swift",
                "\(filsToDiscoverPath)/file2.swift",
            ]),
        ])
    }

    func test_aSwiftPMProject_thatCantBeDescribed_everyFileInTheProject_andAWarning() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["Sources/Lib/Lib.swift", "ExampleCode/Example.swift"], in: project)
        process.commandResult = { _ in
            CommandResult(status: 1, endedBySignal: false, output: "", errors: "error: invalid manifest\n")
        }
        var warnings: [String] = []
        let observer = runEvents.observe(.packageSourceFilesUnavailable) { warnings.append($0.object as? String ?? "") }
        defer { observer.cancel() }

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

    /// The `--files-to-mutate` entries each `filesToMutateUnmatched` from now on says, in order.
    func unmatchedEntries() -> Recorded {
        let recorded = Recorded()
        let observer = runEvents.observe(.filesToMutateUnmatched) { event in
            recorded.entries += event.object as? [UnmatchedFilesToMutate] ?? []
        }
        addTeardownBlock { observer.cancel() }
        return recorded
    }

    final class Recorded {
        var entries: [UnmatchedFilesToMutate] = []
    }

    func makeFiles(_ files: [String], in directory: String) throws {
        for file in files {
            let path = "\(directory)/\(file)"
            try FileManager.default.createDirectory(
                atPath: path.deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: path, contents: Data())
        }
    }

    /// Answers `swift package describe` of the package at `path` with `targets`.
    func describing(_ path: String, as targets: [String]) {
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
    func workingDirectoriesOfDescribe() -> WorkingDirectories {
        let recorded = WorkingDirectories()
        let answer = process.commandResult
        process.commandResult = { command in
            recorded.paths.append(FileManager.default.currentDirectoryPath.canonicalPath)
            return answer(command)
        }
        return recorded
    }

    final class WorkingDirectories {
        var paths: [String] = []
    }

    func target(_ type: String, path: String, sources: [String]) -> String {
        let sourceList = sources.map { "\"\($0)\"" }.joined(separator: ", ")
        return #"{"name": "Target", "type": "\#(type)", "path": "\#(path)", "sources": [\#(sourceList)]}"#
    }

    func makeProjectWithCoveredAndUncoveredFiles(in directory: String) throws {
        try FileManager.default.createDirectory(
            atPath: "\(directory)/Project",
            withIntermediateDirectories: true
        )

        for file in ["Covered.swift", "Uncovered.swift"] {
            FileManager.default.createFile(atPath: "\(directory)/Project/\(file)", contents: Data())
        }
    }
}
