import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

final class SelectMutantTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = SelectMutant()
    private let project = URL(fileURLWithPath: "/code/project")
    private let copy = URL(fileURLWithPath: "/code/project_mutated")

    override func setUpWithError() throws {
        try super.setUpWithError()
        state.projectDirectoryURL = project
        state.mutatedProjectDirectoryURL = copy
        state.mutationMapping = try [
            mapping("Sources/Foo/Bar.swift", [(12, 9, .ror), (12, 20, .ror), (30, 5, .swapTernary)]),
            mapping("Sources/Other/Bar.swift", [(12, 9, .ror)]),
            mapping("Sources/Sum.swift", [(3, 4, .ror), (3, 4, .ror), (7, 1, .ror)]),
        ]
    }

    // The copy gets only that mutant's switch, and its key is the one the whole run gives it.
    func test_keepsTheOneMutantNamed_inItsOwnFile() async throws {
        state.runOptions = .make(mutant: try MutantReference.parse("Foo/Bar.swift:30:5 SwapTernary"))

        let changes = try await sut.run(with: state)
        state.apply(changes)

        let key = MutantKey(
            path: "Sources/Foo/Bar.swift",
            mutationOperatorId: .swapTernary,
            line: 30,
            column: 5,
            occurrence: 0
        )
        XCTAssertEqual(state.selectedMutant, key)
        XCTAssertEqual(state.mutationMapping.map(\.filePath), [copy.appendingPathComponent(key.path).path])
        XCTAssertEqual(MutantKey.keys(for: state.mutationMapping.flatMap(\.mutationSchemata), under: copy), [key])
    }

    // The progress lines name the file alone, and the plain-text report leaves out the column: either names it when
    // only one mutant is there. So does an absolute path in the project or in its copy.
    func test_aReferenceAsTheOutputGivesIt_orAnAbsolutePath_namesTheMutant() async throws {
        let texts = [
            "Sum.swift:7:1",
            "Sum.swift:7",
            "/code/project/Sources/Sum.swift:7",
            "/code/project_mutated/Sources/Sum.swift:7:1 RelationalOperatorReplacement",
        ]
        for text in texts {
            state.runOptions = .make(mutant: try MutantReference.parse(text))

            let changes = try await sut.run(with: state)

            XCTAssertEqual(
                changes.last,
                .mutantSelected(
                    MutantKey(path: "Sources/Sum.swift", mutationOperatorId: .ror, line: 7, column: 1, occurrence: 0)
                ),
                text
            )
        }
    }

    // In a run of a test plan it reads only the plan's mappings, never the copy, which may have been fixed by hand.
    func test_readsNothing() async throws {
        state.runOptions = .make(
            testPlanURL: URL(fileURLWithPath: "/code/project/muter-mappings.json"),
            mutant: try MutantReference.parse("Sum.swift:7:1")
        )

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.methodCalls, [])
    }

    func test_withoutMutant_itChangesNothing() async throws {
        state.runOptions = .make()

        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes, [])
    }

    func test_aPlaceWithNoMutant_listsTheNearestInTheFilesItNames() async throws {
        let reference = try MutantReference.parse("Bar.swift:13")
        state.runOptions = .make(mutant: reference)

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                "\(error)",
                """
                No mutant is at Bar.swift:13. Mutants near line 13 in the 2 files it names:
                  --mutant 'Sources/Foo/Bar.swift:12:9 RelationalOperatorReplacement'
                  --mutant 'Sources/Foo/Bar.swift:12:20 RelationalOperatorReplacement'
                  --mutant 'Sources/Foo/Bar.swift:30:5 SwapTernary'
                  --mutant 'Sources/Other/Bar.swift:12:9 RelationalOperatorReplacement'
                Nothing was tested.
                """
            )
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: error), .stoppedOnAnError)
            XCTAssertEqual(Run.message(showing: error), "\(error)")
        }
    }

    // At most five, the nearest by line, listed in the run's order.
    func test_aPlaceWithNoMutant_listsAtMostFive() async throws {
        state.mutationMapping = try [
            mapping("Sources/Long.swift", (1...9).map { (line: $0 * 10, column: 1, mutationOperatorId: .ror) }),
        ]
        state.runOptions = .make(mutant: try MutantReference.parse("Long.swift:52"))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            let listed = "\(error)".components(separatedBy: "\n").filter { $0.hasPrefix("  --mutant") }
            XCTAssertEqual(
                listed,
                [30, 40, 50, 60, 70].map { "  --mutant 'Sources/Long.swift:\($0):1 RelationalOperatorReplacement'" }
            )
            XCTAssertTrue("\(error)".hasPrefix("No mutant is at Long.swift:52. Mutants near line 52 in the file"))
        }
    }

    // A file name has to be whole: `ar.swift` isn't `Bar.swift`.
    func test_aPathThatNamesNoFile_saysSo() async throws {
        state.runOptions = .make(mutant: try MutantReference.parse("ar.swift:12:9"))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                "\(error)",
                "No mutant is at ar.swift:12:9: no file with mutants matches ar.swift. Nothing was tested."
            )
        }
    }

    func test_aReferenceThatNamesSeveralMutants_listsEveryOne() async throws {
        state.runOptions = .make(mutant: try MutantReference.parse("Bar.swift:12"))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                "\(error)",
                """
                Bar.swift:12 names 3 mutants; give one of these:
                  --mutant 'Sources/Foo/Bar.swift:12:9 RelationalOperatorReplacement'
                  --mutant 'Sources/Foo/Bar.swift:12:20 RelationalOperatorReplacement'
                  --mutant 'Sources/Other/Bar.swift:12:9 RelationalOperatorReplacement'
                Nothing was tested.
                """
            )
        }
    }

    // Two mutants one operator makes at one place share one switch ID, so neither can be switched on alone.
    func test_aPlaceWithRepeats_isRefused_forEveryOccurrence() async throws {
        let first = "Sources/Sum.swift:3:4 RelationalOperatorReplacement"
        for (text, named) in [(first, first), ("Sum.swift:3:4", first), (first + " (#2)", first + " (#2)")] {
            state.runOptions = .make(mutant: try MutantReference.parse(text))

            await AssertThrowsError(try await sut.run(with: state)) { error in
                XCTAssertEqual(
                    "\(error)",
                    "'\(named)' is one of 2 RelationalOperatorReplacement mutants at the same place. They share one "
                        + "switch, so none of them can be tested on its own. Nothing was tested.",
                    text
                )
            }
        }
    }

    /// A file's mapping in the copy, with a mutant at each of `places`, in their order, each in a code block of its
    /// own.
    private func mapping(
        _ path: String,
        _ places: [(line: Int, column: Int, mutationOperatorId: MutationOperator.Id)]
    ) throws -> SchemataMutationMapping {
        let filePath = copy.appendingPathComponent(path).path
        var mapping = SchemataMutationMapping(filePath: filePath)
        for (index, place) in places.enumerated() {
            try mapping.add(
                sourceCode("let value\(index) = a == b").statements,
                MutationSchema.make(
                    filePath: filePath,
                    mutationOperatorId: place.mutationOperatorId,
                    syntaxMutation: "let value\(index) = a != b",
                    position: MutationPosition(utf8Offset: index * 100, line: place.line, column: place.column)
                )
            )
        }
        return mapping
    }
}
