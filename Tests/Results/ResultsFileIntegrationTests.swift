@testable import muterCore
import XCTest

/// Mutation testing writing a real results file, read back as `report` will read it.
final class ResultsFileIntegrationTests: MuterTestCase {
    private let state = MutationTestState()

    func test_aRunWritesHeaderOneLinePerMutantAndEnd_eachBeforeTheNextMutant() async throws {
        let directory = try makeTemporaryDirectory()
        let path = "\(directory)/results.jsonl"
        current.resultsFiles = ResultsFile.Opener()
        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = directory
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutationMapping = try (1...3).map { try makeSchemataMapping(line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .buildError]
        var linesOnDiskAtEachRun: [Int] = []
        ioDelegate.whileRunningMutant = { _ in
            let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            linesOnDiskAtEachRun.append(data.split(separator: UInt8(ascii: "\n")).count)
        }

        _ = try await PerformMutationTesting().run(with: state)

        // The header, then each mutant tested before.
        XCTAssertEqual(linesOnDiskAtEachRun, [1, 2, 3])
        let recorded = try RecordedResults.read(Data(contentsOf: URL(fileURLWithPath: path)), path: path)
        XCTAssertEqual(recorded.headers.map(\.mutantsToTest), [3])
        XCTAssertEqual(recorded.sessions.first?.end?.reason, .finished)
        XCTAssertEqual(recorded.sessions.first?.end?.recorded, 3)
        XCTAssertEqual(recorded.unreadableLines, [])
        XCTAssertFalse(recorded.endsWithCutOffLine)
        XCTAssertEqual(
            recorded.latest.mapValues(\.outcome),
            [
                key(line: 1): .failed,
                key(line: 2): .passed,
                key(line: 3): .buildError,
            ]
        )
        // Closed, so its lock is released.
        let descriptor = open(path, O_RDONLY)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
    }
}

private extension ResultsFileIntegrationTests {
    func key(line: Int) -> MutantKey {
        MutantKey(path: "Sources/File\(line).swift", mutationOperatorId: .ror, line: line, column: 5, occurrence: 0)
    }

    func makeSchemataMapping(line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/project_mutated/Sources/File\(line).swift",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/project_mutated/Sources/File\(line).swift",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line * 10, line: line, column: 5),
                        snapshot: .make(before: ">", after: "<", description: "changed > to <")
                    ),
                ]
            )
        )
    }
}
