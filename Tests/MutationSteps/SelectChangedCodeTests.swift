@testable import muterCore
import TestingExtensions
import XCTest

final class SelectChangedCodeTests: MuterTestCase {
    private let state = MutationTestState()
    private let questions = Questions()
    private var asked: [(ref: String, changedLines: Bool, project: URL)] { questions.asked }

    override func setUp() {
        super.setUp()
        state.runOptions = .make(since: "origin/main", changedLinesOnly: true)
        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
    }

    func test_asksGitInTheProject_andKeepsWhatItChose() async throws {
        let selection = ChangeSelection.make(files: [ChangedFile(path: "Sources/Sum.swift", sha256: "ab12")])
        stubSelection(.success(selection))

        let changes = try await SelectChangedCode().run(with: state)

        XCTAssertEqual(changes, [.changesSelected(selection)])
        XCTAssertEqual(asked.map(\.ref), ["origin/main"])
        XCTAssertEqual(asked.map(\.changedLines), [true])
        XCTAssertEqual(asked.map(\.project.path), ["/project"])
    }

    func test_whatGitCouldntAnswer_endsTheRun() async throws {
        stubSelection(.failure(.unknownRef("origin/main")))

        await AssertThrowsError(try await SelectChangedCode().run(with: state)) { error in
            XCTAssertEqual(error as? ChangeSelectionError, .unknownRef("origin/main"))
        }
    }

    func test_noChangedSwiftFile_leavesNothingToMutate() async throws {
        let selection = ChangeSelection.make()
        stubSelection(.success(selection))

        await AssertThrowsError(try await SelectChangedCode().run(with: state)) { error in
            XCTAssertEqual(
                error as? NothingToMutate,
                NothingToMutate(reason: .noSwiftFileChanged, selection: selection)
            )
        }
    }

    // Tests, a manifest and what `exclude` names are never mutated, so a change to only those leaves nothing.
    func test_onlyExcludedFilesChanged_leavesNothingToMutate() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "", arguments: [], excludeList: ["Generated/**"])
        let selection = ChangeSelection.make(files: [
            ChangedFile(path: "Tests/SumTests/SumTests.swift", sha256: "a"),
            ChangedFile(path: "Package.swift", sha256: "b"),
            ChangedFile(path: "Generated/Model.swift", sha256: "c"),
        ])
        stubSelection(.success(selection))

        await AssertThrowsError(try await SelectChangedCode().run(with: state)) { error in
            XCTAssertEqual(
                error as? NothingToMutate,
                NothingToMutate(reason: .everyFileExcluded(count: 3), selection: selection)
            )
        }
    }

    func test_reportsWhatItChose() async throws {
        let selection = ChangeSelection.make(files: [ChangedFile(path: "Sources/Sum.swift", sha256: "ab12")])
        stubSelection(.success(selection))
        var events: [ChangeSelection] = []
        let subscription = runEvents.observe(.changesSelected) { event in
            if case let .changesSelected(chosen) = event { events.append(chosen) }
        }
        defer { subscription.cancel() }

        _ = try await SelectChangedCode().run(with: state)

        XCTAssertEqual(events, [selection])
    }

    func test_isLeftOut_withoutSince() {
        let steps = MutationTestHandler(options: .make(skipCoverage: true)).steps

        XCTAssertFalse(steps.contains { $0 is SelectChangedCode || $0 is ListChangedSources })
        let withSince = MutationTestHandler(options: .make(since: "main", skipCoverage: true)).steps
        let names = withSince.map { "\(type(of: $0))" }
        XCTAssertEqual(
            names.firstIndex(of: "SelectChangedCode"),
            names.firstIndex(of: "LoadConfiguration").map { $0 + 1 }
        )
        XCTAssertLessThan(
            try XCTUnwrap(names.firstIndex(of: "SelectChangedCode")),
            try XCTUnwrap(names.firstIndex(of: "CopyProjectToTempDirectory"))
        )
    }

    func test_theMessages_sayWhyThereIsNothingToMutate() {
        let selection = ChangeSelection.make(ref: "origin/main")

        XCTAssertEqual(
            "\(NothingToMutate(reason: .noSwiftFileChanged, selection: selection))",
            "ℹ️ No Swift file changed since the merge base of origin/main and HEAD (ba5e000), so there is nothing "
                + "to mutate."
        )
        XCTAssertEqual(
            "\(NothingToMutate(reason: .everyFileExcluded(count: 2), selection: selection))",
            "ℹ️ 2 Swift files changed since the merge base of origin/main and HEAD (ba5e000), and the excludes "
                + "leave out every one, so there is nothing to mutate."
        )
        XCTAssertEqual(
            "\(NothingToMutate(reason: .noMutantOnChangedLines, selection: selection))",
            "ℹ️ No mutant is on a line added or changed since the merge base of origin/main and HEAD (ba5e000), so "
                + "there is nothing to mutate."
        )
    }

    private func stubSelection(_ result: Result<ChangeSelection, ChangeSelectionError>) {
        current.selectChanges = { [questions] ref, changedLines, project in
            questions.append((ref, changedLines, project))
            return result
        }
    }

    /// What git was asked, from the probe's task.
    private final class Questions: @unchecked Sendable { // `asked` is behind `lock`
        private let lock = NSLock()
        private var stored: [(ref: String, changedLines: Bool, project: URL)] = []

        var asked: [(ref: String, changedLines: Bool, project: URL)] {
            lock.withLock { stored }
        }

        func append(_ question: (ref: String, changedLines: Bool, project: URL)) {
            lock.withLock { stored.append(question) }
        }
    }
}

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

        guard case let .candidatePathsListed(paths)? = changes.first else { return XCTFail("\(changes)") }
        XCTAssertTrue(paths.contains("file1.swift"), "\(paths)")
        state.apply(changes)
        let discovered = try await DiscoverSourceFiles().run(with: state)
        XCTAssertEqual(discovered, [.sourceFileCandidatesDiscovered(["\(project)/file1.swift"])])
    }

    private func digest(_ path: String) throws -> String {
        try XCTUnwrap(FileDigest.sha256(of: URL(fileURLWithPath: "\(project)/\(path)")))
    }
}
