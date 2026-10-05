@testable import muterCore
import XCTest

final class MutantKeyTests: XCTestCase {
    private let mutatedRoot = URL(fileURLWithPath: "/project_mutated")

    func test_keysNumberRepeats_inJobOrder() throws {
        let sum = try schema("/project_mutated/Sources/Sum.swift", line: 3, column: 5)
        let product = try schema("/project_mutated/Sources/Product.swift", line: 3, column: 5)
        let sumAtAnotherColumn = try schema("/project_mutated/Sources/Sum.swift", line: 3, column: 9)
        let sumWithAnotherOperator = try schema(
            "/project_mutated/Sources/Sum.swift",
            line: 3,
            column: 5,
            mutationOperatorId: .removeSideEffects
        )

        let keys = MutantKey.keys(
            for: [sum, product, sum, sumAtAnotherColumn, sumWithAnotherOperator, sum],
            under: mutatedRoot
        )

        XCTAssertEqual(keys.map(\.occurrence), [0, 0, 1, 0, 0, 2])
        XCTAssertEqual(keys.map(\.path), [
            "Sources/Sum.swift",
            "Sources/Product.swift",
            "Sources/Sum.swift",
            "Sources/Sum.swift",
            "Sources/Sum.swift",
            "Sources/Sum.swift",
        ])
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func test_key_isWhereAndWhatTheMutantIs_notItsOffsetInThePreparedFile() throws {
        let key = try XCTUnwrap(
            MutantKey.keys(
                for: [
                    schema(
                        "/project_mutated/Sources/Sum.swift",
                        line: 73,
                        column: 22,
                        utf8Offset: 3361,
                        mutationOperatorId: .ror
                    ),
                ],
                under: mutatedRoot
            ).first
        )

        XCTAssertEqual(
            key,
            MutantKey(
                path: "Sources/Sum.swift",
                mutationOperatorId: .ror,
                line: 73,
                column: 22,
                occurrence: 0
            )
        )
    }

    func test_sameNamedFiles_getDistinctKeys_althoughTheyShareASwitchID() throws {
        let example = try schema("/project_mutated/ExampleCode/View.swift", line: 30, column: 10, utf8Offset: 1233)
        let app = try schema("/project_mutated/Sources/App/View.swift", line: 30, column: 10, utf8Offset: 1233)
        XCTAssertEqual(example.id, app.id)

        let keys = MutantKey.keys(for: [example, app], under: mutatedRoot)

        XCTAssertEqual(keys.map(\.path), ["ExampleCode/View.swift", "Sources/App/View.swift"])
        XCTAssertEqual(keys.map(\.occurrence), [0, 0])
    }

    func test_path_isRelativeToTheMutatedProject() {
        XCTAssertEqual(
            RepoRelativePath.of("/project_mutated/Sources/App/Sum.swift", under: mutatedRoot),
            "Sources/App/Sum.swift"
        )
        XCTAssertEqual(
            RepoRelativePath.of("/project_mutated/Sum.swift", under: URL(fileURLWithPath: "/project_mutated/")),
            "Sum.swift"
        )
        XCTAssertEqual(RepoRelativePath.of("/Sources/Sum.swift", under: URL(fileURLWithPath: "/")), "Sources/Sum.swift")
    }

    func test_path_outsideTheMutatedProject_staysAbsolute() {
        XCTAssertEqual(
            RepoRelativePath.of("/elsewhere/Sum.swift", under: mutatedRoot),
            "/elsewhere/Sum.swift"
        )
        // A sibling whose name starts with the project's, such as a worker's clone.
        XCTAssertEqual(
            RepoRelativePath.of("/project_mutated_worker1/Sum.swift", under: mutatedRoot),
            "/project_mutated_worker1/Sum.swift"
        )
        XCTAssertEqual(RepoRelativePath.of("/project_mutated", under: mutatedRoot), "/project_mutated")
        XCTAssertEqual(RepoRelativePath.of("/project_mutated/", under: mutatedRoot), "/project_mutated/")
        // Relative, it would resolve to one slash fewer.
        XCTAssertEqual(
            RepoRelativePath.of("/project_mutated//Sum.swift", under: mutatedRoot),
            "/project_mutated//Sum.swift"
        )
    }

    func test_resolve_invertsBothCases() {
        let paths = [
            "/project_mutated/Sources/App/Sum.swift",
            "/project_mutated/Sum.swift",
            "/elsewhere/Sum.swift",
            "/project_mutated_worker1/Sum.swift",
            "/project_mutated",
            "/project_mutated/",
            "/project_mutated//Sum.swift",
        ]

        for root in ["/project_mutated", "/project_mutated/"] {
            for path in paths {
                XCTAssertEqual(
                    RepoRelativePath.resolve(
                        RepoRelativePath.of(path, under: URL(fileURLWithPath: root)),
                        under: root
                    ),
                    path,
                    "under \(root)"
                )
            }
        }
    }

    func test_description_namesThePlaceAndTheOperator_andARepeat() {
        let key = MutantKey(path: "Sources/Sum.swift", mutationOperatorId: .ror, line: 3, column: 5, occurrence: 0)
        let repeated = MutantKey(path: "Sources/Sum.swift", mutationOperatorId: .ror, line: 3, column: 5, occurrence: 1)

        XCTAssertEqual(key.description, "Sources/Sum.swift:3:5 RelationalOperatorReplacement")
        XCTAssertEqual(repeated.description, "Sources/Sum.swift:3:5 RelationalOperatorReplacement (#2)")
    }

    private func schema(
        _ filePath: String,
        line: Int,
        column: Int,
        utf8Offset: Int = 0,
        mutationOperatorId: MutationOperator.Id = .ror
    ) throws -> MutationSchema {
        try MutationSchema.make(
            filePath: filePath,
            mutationOperatorId: mutationOperatorId,
            position: MutationPosition(utf8Offset: utf8Offset, line: line, column: column)
        )
    }
}
