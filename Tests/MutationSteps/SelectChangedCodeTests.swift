@testable import muterCore
import TestingExtensions
import XCTest

final class SelectChangedCodeTests: MuterTestCase {
    private let state = MutationTestState()
    private let questions = Questions()
    private var asked: [Question] { questions.asked }

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
            questions.append(Question(ref: ref, changedLines: changedLines, project: project))
            return result
        }
    }

    /// One question to git: the ref to compare with, whether only changed lines count, and the project.
    private struct Question {
        let ref: String
        let changedLines: Bool
        let project: URL
    }

    /// What git was asked, from the probe's task.
    private final class Questions: @unchecked Sendable { // `asked` is behind `lock`
        private let lock = NSLock()
        private var stored: [Question] = []

        var asked: [Question] {
            lock.withLock { stored }
        }

        func append(_ question: Question) {
            lock.withLock { stored.append(question) }
        }
    }
}
