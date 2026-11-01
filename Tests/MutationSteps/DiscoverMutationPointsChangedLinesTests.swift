@testable import muterCore
import TestingExtensions
import XCTest

/// `--changed-lines`: which of a changed file's mutants discovery keeps.
final class DiscoverMutationPointsChangedLinesTests: MuterTestCase {
    private let state = MutationTestState()

    // Line 2 holds `<`, whose right-hand operand is on line 3; lines 8 and 9 statements RemoveSideEffects removes;
    // line 13 `==`.
    private let source = """
    func check(index: Int, items: [Int]) -> Bool {
        guard index <
            items.count - 1 else { return false }
        return true
    }

    func save(index: Int) {
        _ = record(index)
        _ = record(index + 1)
    }

    func other(a: Int) -> Bool {
        return a == 3
    }

    """

    override func setUp() {
        super.setUp()
        state.mutationOperatorList = .allOperators
        prepareCode.sourceCodeToReturn = {
            muterCore.sourceCode(fromFileAt: $0).map { (source: $0, changes: .null) }
        }
    }

    // The operator alone is on line 2, but what it compares changed.
    func test_anOperatorWhoseOperandChanged_isKept() async throws {
        let kept = try await mutants(changing: [LineRange(first: 3, last: 3)])

        XCTAssertEqual(kept.map(\.operatorAndLine), ["RelationalOperatorReplacement:2"])
    }

    func test_aChangedStatement_isKept_andTheUnchangedOnesAreNot() async throws {
        let kept = try await mutants(changing: [LineRange(first: 8, last: 8)])

        XCTAssertEqual(kept.map(\.operatorAndLine), ["RemoveSideEffects:8"])
    }

    // Lines removed between 2 and 3, from the middle of the condition.
    func test_anExpressionLinesWereRemovedFrom_isKept() async throws {
        let kept = try await mutants(removingAfter: [2])

        XCTAssertEqual(kept.map(\.operatorAndLine), ["RelationalOperatorReplacement:2"])
    }

    func test_withoutChangedLines_everyMutantOfAChangedFileIsKept() async throws {
        let kept = try await mutants(changing: [LineRange(first: 8, last: 8)], changedLines: false)

        XCTAssertEqual(kept.count, 4)
    }

    func test_noMutantOnAChangedLine_leavesNothingToMutate() async throws {
        let selection = try prepare(changing: [LineRange(first: 6, last: 6)])

        await AssertThrowsError(try await DiscoverMutationPoints().run(with: state)) { error in
            XCTAssertEqual(
                error as? NothingToMutate,
                NothingToMutate(reason: .noMutantOnChangedLines, selection: selection)
            )
        }
    }

    // Declarations only: no operator mutates them, which is nothing to mutate rather than a failure.
    func test_aChangedFileWithoutMutants_leavesNothingToMutate() async throws {
        let selection = try prepare(changing: nil, source: "struct Model {\n    let name: String\n}\n")

        await AssertThrowsError(try await DiscoverMutationPoints().run(with: state)) { error in
            XCTAssertEqual(
                error as? NothingToMutate,
                NothingToMutate(reason: .noMutantInChangedFiles(count: 1), selection: selection)
            )
        }
    }
}

private extension DiscoverMutationPointsChangedLinesTests {
    func mutants(
        changing lines: [LineRange]? = nil,
        removingAfter deletions: [Int]? = nil,
        changedLines: Bool = true
    ) async throws -> [MutationSchema] {
        try prepare(changing: lines ?? [], removingAfter: deletions, changedLines: changedLines)
        let changes = try await DiscoverMutationPoints().run(with: state)
        guard case let .mutationMappingsDiscovered(mappings)? = changes.first else {
            XCTFail("Expected mappings, got \(changes)")
            return []
        }
        return mappings.flatMap(\.mutationSchemata).sorted { $0.position.line < $1.position.line }
    }

    @discardableResult
    func prepare(
        changing lines: [LineRange]?,
        removingAfter deletions: [Int]? = nil,
        changedLines: Bool = true,
        source: String? = nil
    ) throws -> ChangeSelection {
        let project = try makeTemporaryDirectory()
        let path = "\(project)/Check.swift"
        try (source ?? self.source).write(toFile: path, atomically: true, encoding: .utf8)
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.sourceFileCandidates = [path]
        let selection = ChangeSelection.make(
            changedLines: changedLines,
            files: [ChangedFile(path: "Check.swift", lines: lines, deletionsAfter: deletions, sha256: "")]
        )
        state.apply([.changesSelected(selection)])
        return selection
    }
}

private extension MutationSchema {
    var operatorAndLine: String {
        "\(mutationOperatorId.rawValue):\(position.line)"
    }
}
