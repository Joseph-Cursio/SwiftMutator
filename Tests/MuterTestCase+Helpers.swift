@testable import muterCore
import TestingExtensions
import XCTest

extension MuterTestCase {
    func generateSchemataMappings(
        for source: SourceCodeInfo,
        changes: MutationSourceCodePreparationChange = .null,
        regionsWithoutCoverage: [Region] = []
    ) -> [SchemataMutationMapping] {
        generateSchemataMappings(
            for: source,
            changes: changes,
            coverage: .make(regionsWithoutCoverage: regionsWithoutCoverage)
        )
    }

    func generateSchemataMappings(
        for source: SourceCodeInfo,
        changes: MutationSourceCodePreparationChange = .null,
        coverage: FileCoverage
    ) -> [SchemataMutationMapping] {
        operatorsToDiscoverWith
            .accumulate(into: []) { newSchemataMappings, mutationOperatorId in
                let visitor = mutationOperatorId.visitor(
                    .init(),
                    source,
                    coverage
                )

                visitor.sourceCodePreparationChange = changes

                visitor.walk(source.code)

                let schemataMapping = visitor.schemataMappings

                if !schemataMapping.isEmpty {
                    return newSchemataMappings + [schemataMapping]
                }
                return newSchemataMappings
            }.mergeByFilePath()
    }

    func assertThrowsMuterError(
        _ expression: @autoclosure () async throws -> some Any,
        _ expectedError: MuterError,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        try await assertThrowsMuterError(
            await expression(),
            message(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error, expectedError, file: file, line: line)
        }
    }

    func assertThrowsMuterError(
        _ expression: @autoclosure () async throws -> some Any,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ errorHandler: (MuterError) throws -> Void
    ) async {
        try await AssertThrowsError(
            await expression(),
            message(),
            file: file,
            line: line
        ) { error in
            if let muterError = error as? MuterError {
                try errorHandler(muterError)
            } else {
                XCTFail("Expected \(MuterError.self), got \(error)", file: file, line: line)
            }
        }
    }

    func loadFixture(_ path: String) -> String {
        FileManager.default
            .contents(atPath: "\(fixturesDirectory)/\(path)")
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? ""
    }
}
