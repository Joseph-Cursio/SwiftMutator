@testable import muterCore
import XCTest

extension DiscoverMutationPointsChangedLinesTests {
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
            files: [ChangedFile(path: "Check.swift", sha256: "", lines: lines, deletionsAfter: deletions)]
        )
        state.apply([.changesSelected(selection)])
        return selection
    }
}
