@testable import muterCore
import XCTest

/// Real folders for the project and its copy, and an injected listing in place of git.
final class FingerprintProjectTreeTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = FingerprintProjectTree()
    private var project = ""
    private var copy = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = try makeTemporaryDirectory()
        project = "\(root)/project"
        copy = "\(root)/project_mutated"
        state.projectDirectoryURL = URL(fileURLWithPath: project)
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: copy)
    }

    // The files are listed in the project and hashed in the copy, as it was tested; the -o report and its partial
    // sibling, which the run itself writes in the project, are left out.
    func test_fingerprintsTheCopy_andHandsTheTreeToTheState() async throws {
        state.runOptions = .make(reportURL: URL(fileURLWithPath: "\(project)/mutation-report.txt"))
        try write(["README.md": "readme", "Sources/Sum.swift": "as in the project"], in: project)
        try write(
            ["README.md": "readme", "Sources/Sum.swift": "as copied", "mutation-report.txt": "an earlier report"],
            in: copy
        )
        var listed: [URL] = []
        current.listProjectFiles = { directory in
            listed.append(directory)
            return ["README.md", "Sources/Sum.swift", "mutation-report.txt"]
        }

        let changes = try await sut.run(with: state)
        state.apply(changes)

        XCTAssertEqual(listed, [state.projectDirectoryURL])
        let files = try [
            "README.md": XCTUnwrap(FileDigest.sha256(of: Data("readme".utf8))),
            "Sources/Sum.swift": XCTUnwrap(FileDigest.sha256(of: Data("as copied".utf8))),
        ]
        let tree = ProjectTree(
            listedBy: .git,
            files: files,
            excluded: ["mutation-report.partial.txt", "mutation-report.txt"],
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

        let result = await Task { [sut, state] in try await sut.run(with: state) }.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertNil(state.projectTree)
    }
}

private extension FingerprintProjectTreeTests {
    /// Writes each file, relative to `root`, making its folders.
    func write(_ files: [String: String], in root: String) throws {
        for (path, contents) in files {
            let file = URL(fileURLWithPath: "\(root)/\(path)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
    }
}
