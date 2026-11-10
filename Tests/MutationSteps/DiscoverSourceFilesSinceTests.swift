@testable import muterCore
import TestingExtensions
import XCTest

final class DiscoverSourceFilesSinceTests: MuterTestCase {
    private let state = MutationTestState()
    private lazy var project = "\(fixturesDirectory)/FilesToDiscover"

    override func setUp() {
        super.setUp()
        current.fileManager = FileManager.default
        current.listProjectFiles = { _ in nil }
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
    }

    // The excludes still apply: of the changed files, the test file is left out.
    func test_discoversOnlyTheChangedFiles_thatAreLeftAfterTheExcludes() async throws {
        let files = [
            ChangedFile(path: "file1.swift", sha256: try digest("file1.swift")),
            ChangedFile(path: "Directory1/file3.swift", sha256: try digest("Directory1/file3.swift")),
            ChangedFile(path: "Tests/SumTests.swift", sha256: "a"),
        ]
        state.apply([.changesSelected(.make(files: files))])

        let result = try await DiscoverSourceFiles().run(with: state)

        let expected = ["\(project)/Directory1/file3.swift", "\(project)/file1.swift"]
        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(expected)])
    }

    func test_aFileTheCopyHoldsOtherwise_endsTheRun() async throws {
        state.apply([
            .changesSelected(.make(files: [ChangedFile(path: "file1.swift", sha256: "as git saw it")])),
            .projectTreeFingerprinted(ProjectTree(
                listedBy: .git,
                files: ["file1.swift": "as copied"],
                excluded: [],
                treeSHA256: ""
            )),
        ])

        await AssertThrowsError(try await DiscoverSourceFiles().run(with: state)) { error in
            XCTAssertEqual(error as? ChangeSelectionError, .changedDuringTheRun(path: "file1.swift"))
        }
    }

    // A file no target compiles, or without coverage, isn't one discovery mutates.
    func test_changedFilesDiscoveryLeavesOut_leaveNothingToMutate() async throws {
        let selection = ChangeSelection.make(files: [
            ChangedFile(path: "NotInTheProject.swift", sha256: "a"),
            ChangedFile(path: "Tests/SumTests.swift", sha256: "b"),
        ])
        state.apply([.changesSelected(selection)])

        await AssertThrowsError(try await DiscoverSourceFiles().run(with: state)) { error in
            XCTAssertEqual(
                error as? NothingToMutate,
                NothingToMutate(reason: .noFileDiscovered(count: 1), selection: selection)
            )
        }
    }

    // Before the coverage run, which runs the whole test suite: a change no target builds ends the run there.
    func test_listingBeforeCoverage_endsTheRun_whenNoTargetCompilesAChangedFile() async throws {
        let selection = ChangeSelection.make(files: [
            ChangedFile(path: "NotInTheProject.swift", sha256: "a"),
            ChangedFile(path: "Tests/SumTests.swift", sha256: "b"),
        ])
        state.apply([.changesSelected(selection)])

        await AssertThrowsError(try await ListChangedSources().run(with: state)) { error in
            XCTAssertEqual(
                error as? NothingToMutate,
                NothingToMutate(reason: .noTargetCompiles(count: 1), selection: selection)
            )
        }
        let steps = MutationTestHandler(options: .make(since: "main")).steps.map { "\(type(of: $0))" }
        XCTAssertEqual(
            steps.firstIndex(of: "ListChangedSources"),
            steps.firstIndex(of: "DiscoverProjectCoverage").map { $0 - 1 }
        )
    }

    func test_listingBeforeCoverage_isWhatDiscoveryPicksFrom() async throws {
        let file = ChangedFile(path: "file1.swift", sha256: try digest("file1.swift"))
        state.apply([.changesSelected(.make(files: [file]))])

        let changes = try await ListChangedSources().run(with: state)

        guard case let .candidatePathsListed(paths)? = changes.first else {
            XCTFail("\(changes)")
            return
        }
        XCTAssertTrue(paths.contains("file1.swift"), "\(paths)")
        state.apply(changes)
        let discovered = try await DiscoverSourceFiles().run(with: state)
        XCTAssertEqual(discovered, [.sourceFileCandidatesDiscovered(["\(project)/file1.swift"])])
    }

    private func digest(_ path: String) throws -> String {
        try XCTUnwrap(FileDigest.sha256(of: URL(fileURLWithPath: "\(project)/\(path)")))
    }
}
