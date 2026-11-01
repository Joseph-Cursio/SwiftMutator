@testable import muterCore
import TestingExtensions
import XCTest

/// Real folders for the project and its copy, and an injected listing in place of git.
final class FingerprintProjectTreeTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = FingerprintProjectTree()
    private var project = ""
    private var copy = ""
    private let resultsPath = "/project_muter_logs/session 1/results.jsonl"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = try makeTemporaryDirectory()
        project = "\(root)/project"
        copy = "\(root)/project_mutated"
        state.projectDirectoryURL = URL(fileURLWithPath: project)
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: copy)
    }

    // The files are listed in the project and hashed in the copy, as it was tested. The -o report and its partial
    // sibling, which the run itself writes in the project, are left out, and so is the configuration file, whose
    // settings the header records.
    func test_fingerprintsTheCopy_andHandsTheTreeToTheState() async throws {
        state.runOptions = .make(reportURL: URL(fileURLWithPath: "\(project)/mutation-report.txt"))
        try write(["README.md": "readme", "Sources/Sum.swift": "as in the project"], in: project)
        try write(
            [
                "README.md": "readme",
                "Sources/Sum.swift": "as copied",
                "mutation-report.txt": "an earlier report",
                "muter.conf.yml": "mutationTestWorkers: 4",
            ],
            in: copy
        )
        let listed = Locked<[URL]>([])
        current.listProjectFiles = { directory in
            listed.change { $0.append(directory) }
            return ["README.md", "Sources/Sum.swift", "mutation-report.txt", "muter.conf.yml"]
        }

        let changes = try await sut.run(with: state)
        state.apply(changes)

        XCTAssertEqual(listed.value, [state.projectDirectoryURL])
        let files = [
            "README.md": FileDigest.sha256(of: Data("readme".utf8)),
            "Sources/Sum.swift": FileDigest.sha256(of: Data("as copied".utf8)),
        ]
        let tree = ProjectTree(
            listedBy: .git,
            files: files,
            excluded: ["mutation-report.partial.txt", "mutation-report.txt", "muter.conf.yml"],
            treeSHA256: ProjectTree.treeHash(of: files)
        )
        XCTAssertEqual(changes, [.projectTreeFingerprinted(tree)])
        XCTAssertEqual(state.projectTree, tree)
    }

    // A git that stopping the run killed reads as no repository, so the step stops rather than hand on a walk's tree.
    func test_aListingTheStopKilled_throwsCancellation() async throws {
        try write(["Sources/Sum.swift": "sum"], in: copy)
        current.listProjectFiles = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return nil
        }

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertNil(state.projectTree)
    }

    // LoadResumeState found the project as the last session left it, and the copy holds the same files.
    func test_onResume_anUnchangedCopy_passes() async throws {
        let files = ["README.md": "readme", "Sources/Sum.swift": "sum"]
        try write(files, in: copy)
        current.listProjectFiles = { _ in Array(files.keys) }
        let recorded = try projectTree(of: files)
        try resume(recorded)

        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes, [.projectTreeFingerprinted(recorded), .projectChangesWaived([])])
    }

    // A file edited while the project was copied: only this check sees it. Its message doesn't say nothing was copied.
    func test_onResume_aChangeDuringTheCopy_refusesAfterIt() async throws {
        try write(["README.md": "readme", "Sources/Sum.swift": "edited as it was copied"], in: copy)
        current.listProjectFiles = { _ in ["README.md", "Sources/Sum.swift"] }
        try resume(projectTree(of: ["README.md": "readme", "Sources/Sum.swift": "sum"]))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? ResumeRefused,
                ResumeRefused(
                    path: self.resultsPath,
                    reasons: [.filesChanged([.init(path: "Sources/Sum.swift", kind: .changed)])],
                    beforeTheCopy: false
                )
            )
        }
        XCTAssertNil(state.projectTree)
    }

    // The header records which changes were let through.
    func test_onResume_waivedChanges_areHandedToTheState() async throws {
        try write(["README.md": "a changed readme", "notes.txt": "new notes", "Sources/Sum.swift": "sum"], in: copy)
        current.listProjectFiles = { _ in ["README.md", "notes.txt", "Sources/Sum.swift"] }
        try resume(
            projectTree(of: ["README.md": "readme", "Sources/Sum.swift": "sum"]),
            ignoring: ["./README.md", "*.txt"]
        )

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(state.resumeWaived, ["README.md", "notes.txt"])
        XCTAssertEqual(state.projectTree?.files.keys.sorted(), ["README.md", "Sources/Sum.swift", "notes.txt"])
    }

    // A reuse is never refused for changed files: each session's changes since its own tree decide which of its
    // results it keeps. A session that resumed the run after a waived change has another tree than the first.
    func test_onReuse_eachSessionsChanges_areHandedToTheState_testFilesReadFromTheCopy() async throws {
        let first = ["README.md": "readme", "Sources/Sum.swift": "sum", "Tests/SumTests/SumTests.swift": "old tests"]
        let second = first.merging(["README.md": "a changed readme"]) { $1 }
        let tests = "import Testing\n@Test func adds() {}"
        let now = second.merging(["Tests/SumTests/SumTests.swift": tests, "notes.txt": "new"]) { $1 }
        try write(now, in: copy)
        current.listProjectFiles = { _ in Array(now.keys) }
        state.runOptions = .make(reuseURL: URL(fileURLWithPath: resultsPath), resumeIgnoring: ["*.txt"])
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [
                ResultsHeader.make(project: projectTree(of: first)),
                ResultsHeader.make(formatVersion: 2, session: 2, project: projectTree(of: second), waived: ["README.md"]),
            ],
            file: nil
        )

        state.apply(try await sut.run(with: state))

        let changes = try XCTUnwrap(state.reuseChanges)
        XCTAssertEqual(changes.keys.sorted(), [1, 2])
        XCTAssertEqual(changes[1]?.otherFiles, [.init(path: "README.md", kind: .changed)])
        XCTAssertEqual(changes[2]?.otherFiles, [])
        for session in [1, 2] {
            XCTAssertEqual(changes[session]?.waived, ["notes.txt"])
            XCTAssertEqual(changes[session]?.testFiles, [.init(path: "Tests/SumTests/SumTests.swift", kind: .changed)])
            XCTAssertEqual(changes[session]?.testSources, ["Tests/SumTests/SumTests.swift": tests])
        }
        XCTAssertEqual(state.resumeWaived, ["notes.txt"])
        XCTAssertNotNil(state.projectTree)
    }

    // The last session's report is still in the project, although this run writes its report elsewhere, or none.
    func test_onResume_theRecordedReportPaths_arentChanges() async throws {
        try write(["README.md": "readme", "old-report.txt": "the last session's report"], in: copy)
        current.listProjectFiles = { _ in ["README.md", "old-report.txt"] }
        let files = ["README.md": FileDigest.sha256(of: Data("readme".utf8))]
        try resume(
            ProjectTree(
                listedBy: .git,
                files: files,
                excluded: ["old-report.partial.txt", "old-report.txt"],
                treeSHA256: ProjectTree.treeHash(of: files)
            )
        )

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(state.projectTree?.files, files)
        XCTAssertEqual(state.projectTree?.excluded, ["muter.conf.yml", "old-report.partial.txt", "old-report.txt"])
        XCTAssertEqual(state.resumeWaived, [])
    }
}

private extension FingerprintProjectTreeTests {
    /// Resumes a run whose last session recorded `recorded`.
    func resume(_ recorded: ProjectTree, ignoring globs: [String] = []) throws {
        state.runOptions = .make(resumeURL: URL(fileURLWithPath: resultsPath), resumeIgnoring: globs)
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [ResultsHeader.make(project: recorded), ResultsEnd.make()],
            file: resultsFiles.openForResume(at: resultsPath)
        )
    }

    /// The tree of `files`, each a path relative to the project and its contents, as listed by git, and as a run that
    /// loads the project's own configuration records it.
    func projectTree(of files: [String: String]) throws -> ProjectTree {
        let hashes = files.mapValues { FileDigest.sha256(of: Data($0.utf8)) }
        return ProjectTree(
            listedBy: .git,
            files: hashes,
            excluded: ["muter.conf.yml"],
            treeSHA256: ProjectTree.treeHash(of: hashes)
        )
    }

    /// Writes each file, relative to `root`, making its folders.
    func write(_ files: [String: String], in root: String) throws {
        for (path, contents) in files {
            let file = URL(fileURLWithPath: "\(root)/\(path)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
    }
}
