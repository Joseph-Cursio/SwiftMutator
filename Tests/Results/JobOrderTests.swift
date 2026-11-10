@testable import muterCore
import SwiftParser
import XCTest

/// A guard on the order a results file's mutants are reported in: mutation testing's jobs, which discovery orders.
final class JobOrderTests: MuterTestCase, RecordedOutcomeTesting {
    private let mutatedProject = URL(fileURLWithPath: "/project_mutated")
    /// Sources in memory, beside the two fixture files: a file whose mutants' lines order differently as text, and
    /// two files of one name.
    private let sources = [
        "/project_mutated/Sources/Zeta.swift": """
        struct Zeta {
            func check(_ value: Int, _ other: Int) -> Bool {
                // Padding, so that the mutants below
                // are on lines 9 to 11, which sort
                // differently as text and as numbers.
                //
                //
                //
                let first = value > 1
                let second = other < 2
                return first && second
            }
        }
        """,
        "/project_mutated/Sources/B/Util.swift": """
        struct Util {
            func isPositive(_ value: Int) -> Bool {
                value > 0
            }
        }
        """,
        "/project_mutated/Sources/A/Util.swift": """
        struct Util {
            func isSmall(_ value: Int) -> Bool {
                value < 10
            }
        }
        """,
    ]

    func test_sortingByJobOrder_givesDiscoverysOrder() async throws {
        let jobs = try await discoveredJobs()
        let keys = MutantKey.keys(for: jobs, under: mutatedProject)
        XCTAssertEqual(Set(jobs.map(\.filePath)).count, 5, "\(jobs.map(\.filePath))")
        let zetaLines = jobs
            .filter { $0.fileName == "Zeta.swift" && $0.mutationOperatorId == .ror }
            .map(\.position.line)
        XCTAssertEqual(zetaLines, [9, 9, 10, 10], "lines compare as numbers, not as the text of a switch ID")
        // In line order whatever the operator, not each operator's mutants in turn.
        for file in Set(jobs.map(\.filePath)) {
            let places = jobs.filter { $0.filePath == file }.map { [$0.position.line, $0.position.column] }
            XCTAssertEqual(places, places.sorted { $0.lexicographicallyPrecedes($1) }, file)
        }
        XCTAssertGreaterThan(Set(jobs.map(\.mutationOperatorId)).count, 1)
        let orders = zip(jobs, keys).map { job, key in
            JobOrder(filePath: job.filePath, inFile: job.orderInFile, occurrence: key.occurrence)
        }

        for shuffled in [Array(orders.reversed()), orders.shuffled(), orders.shuffled()] {
            XCTAssertEqual(shuffled.sorted(), orders)
        }

        // And so the outcome rebuilt from a results file that holds their records in any order.
        let encoder = ResultsCoding.encoder
        let records = try zip(jobs, keys).shuffled().map { try encoder.encode(mutantResult($0, $1)) }
        let file = try ([encoder.encode(ResultsHeader.make())] + records).reduce(Data()) { $0 + $1 + Data("\n".utf8) }
        let rebuilt = try RecordedResults.read(file, path: "/logs/results.jsonl")
            .mutationTestOutcome(resultsFile: "/logs/results.jsonl")
        XCTAssertEqual(rebuilt.mutations.map(\.point), jobs.map {
            MutationPoint(mutationOperatorId: $0.mutationOperatorId, filePath: $0.filePath, position: $0.position)
        })
    }

    // A resumed session keeps an earlier session's result as it was recorded, with an offset that counts the header
    // and import SwiftMutator inserted then. When the import gained an access level since, as another file of the
    // module did, the offset moved but the line and column didn't, and the run tested the two mutants at this place
    // by operator.
    func test_aKeptResultsOlderOffset_doesNotMoveIt() throws {
        let kept = MutantResult.make(line: 9, column: 5, utf8Offset: 120, mutationOperatorId: .swapTernary)
        let tested = MutantResult.make(
            session: 2,
            line: 9,
            column: 5,
            utf8Offset: 129,
            mutationOperatorId: .removeSideEffects
        )
        let encoder = ResultsCoding.encoder
        let lines: [any Encodable] = [ResultsHeader.make(), kept, ResultsHeader.make(session: 2), tested]
        let file = try lines.map { try encoder.encode($0) }.reduce(Data()) { $0 + $1 + Data("\n".utf8) }

        let rebuilt = try RecordedResults.read(file, path: "/logs/results.jsonl")
            .mutationTestOutcome(resultsFile: "/logs/results.jsonl")

        XCTAssertEqual(rebuilt.mutations.map(\.point.mutationOperatorId), [.removeSideEffects, .swapTernary])
    }

    /// The jobs mutation testing makes from what discovery finds in the fixture files and `sources`.
    private func discoveredJobs() async throws -> [MutationSchema] {
        let state = MutationTestState()
        state.mutationOperatorList = .allOperators
        state.sourceFileCandidates = [
            "\(fixturesDirectory)/sampleForDiscoveringMutations.swift",
            "\(fixturesDirectory)/sample With Spaces For Discovering Mutations.swift",
        ] + sources.keys.sorted()
        prepareCode.sourceCodeToReturn = { [sources] path in
            let source = sources[path].map { SourceCodeInfo(path: path, code: Parser.parse(source: $0)) }
                ?? muterCore.sourceCode(fromFileAt: path)
            return source.map { (source: $0, changes: .null) }
        }

        let changes = try await DiscoverMutationPoints().run(with: state)

        guard case let .mutationMappingsDiscovered(mappings)? = changes.first else {
            XCTFail("Expected mappings, got \(changes)")
            return []
        }
        return mappings.flatMap(\.mutationSchemata)
    }
}
