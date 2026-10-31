import Foundation
@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

final class CheckMutantSwitchesTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = CheckMutantSwitches()

    func test_whenEveryMutantHasItsSwitch_thenItPasses() async throws {
        let file = try mutatedFile(named: "Check")
        XCTAssertGreaterThan(file.mapping.mutationSchemata.count, 1, "the fixture should hold several mutants")
        state.mutationMapping = [file.mapping]
        queueCode(file.rewritten)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [])
        XCTAssertEqual(fileManager.contentsAtPath, [file.mapping.filePath])
    }

    // The rewrite inserted nothing, as when its lookup of each statement list never matched (`CodeBlockKey`).
    func test_whenAFileHoldsNoSwitch_thenThrowErrorNamingItsMutants() async throws {
        let file = try mutatedFile(named: "Check")
        state.mutationMapping = [file.mapping]
        queueCode(file.original)
        let gap = CheckMutantSwitches.Gap(
            mapping: file.mapping,
            missing: file.mapping.mutationSchemata,
            unreadable: false
        )

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .literal(reason: CheckMutantSwitches.reason(for: [gap], usingTestPlan: false))
        )
        let reason = CheckMutantSwitches.reason(for: [gap], usingTestPlan: false)
        let count = file.mapping.mutationSchemata.count
        XCTAssertTrue(reason.contains("\(count) mutants have no switch"), reason)
        XCTAssertTrue(reason.contains("/path/to/muted/Sources/Check.swift lacks the switches of \(count) of"), reason)
        for schema in file.mapping.mutationSchemata {
            XCTAssertTrue(reason.contains("    \(schema.id)\n"), reason)
        }
        XCTAssertTrue(reason.contains("a bug in SwiftMutator's rewriting"), reason)
    }

    // A nested block's switch was once dropped while its enclosing block's was kept.
    func test_whenOneMutantLacksItsSwitch_thenOnlyItIsNamed() async throws {
        let file = try mutatedFile(named: "Check")
        let lost = try XCTUnwrap(file.mapping.mutationSchemata.last)
        state.mutationMapping = [file.mapping]
        queueCode(file.rewritten.replacingOccurrences(of: "\"\(lost.id)\"", with: "\"\""))

        try await assertThrowsMuterError(await sut.run(with: state)) { error in
            guard case let .literal(reason) = error else { return XCTFail("\(error)") }
            let count = file.mapping.mutationSchemata.count
            XCTAssertTrue(reason.contains("1 mutant has no switch"), reason)
            XCTAssertTrue(reason.contains("lacks the switches of 1 of its \(count) mutants:\n    \(lost.id)\n"), reason)
            XCTAssertEqual(reason.components(separatedBy: "\n    ").count, 2, reason)
        }
    }

    // An ID inside a longer string, or in a comment, is no switch.
    func test_anIDThatIsntAWholeQuotedString_isNoSwitch() throws {
        let file = try mutatedFile(named: "Check")
        let ids = file.mapping.mutationSchemata.map(\.id)
        let code = ids.map { "let note = \"see \($0)\" // \($0)" }.joined(separator: "\n")

        XCTAssertEqual(CheckMutantSwitches.mutantsWithoutASwitch(in: code, of: file.mapping).map(\.id), ids)
        XCTAssertEqual(CheckMutantSwitches.mutantsWithoutASwitch(in: file.rewritten, of: file.mapping), [])
    }

    func test_whenAFileCannotBeRead_thenThrowErrorNamingIt() async throws {
        let file = try mutatedFile(named: "Check")
        state.mutationMapping = [file.mapping]

        try await assertThrowsMuterError(await sut.run(with: state)) { error in
            guard case let .literal(reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("/path/to/muted/Sources/Check.swift could not be read"), reason)
        }
    }

    // run-without-mutating: the plan's code may have been edited by hand since it was made.
    func test_whenATestPlansCodeLacksASwitch_thenSayToMakeThePlanAgain() async throws {
        let file = try mutatedFile(named: "Check")
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json"))
        state.mutationMapping = [file.mapping]
        queueCode(file.original)

        try await assertThrowsMuterError(await sut.run(with: state)) { error in
            guard case let .literal(reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("`swift-mutator mutate-without-running`"), reason)
            XCTAssertFalse(reason.contains("bug"), reason)
        }
    }

    // Every file is checked before the run stops, so one error names every gap.
    func test_everyFileWithAGapIsNamed_andOneWithoutMutantsIsNotRead() async throws {
        let first = try mutatedFile(named: "First")
        let second = try mutatedFile(named: "Second")
        let third = try mutatedFile(named: "Third")
        state.mutationMapping = [
            first.mapping,
            SchemataMutationMapping(filePath: "/path/to/muted/Empty.swift"),
            second.mapping,
            third.mapping,
        ]
        queueCode(first.original)
        queueCode(second.rewritten)
        queueCode(third.original)

        try await assertThrowsMuterError(await sut.run(with: state)) { error in
            guard case let .literal(reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("First.swift lacks"), reason)
            XCTAssertFalse(reason.contains("Second.swift"), reason)
            XCTAssertTrue(reason.contains("Third.swift lacks"), reason)
        }
        XCTAssertEqual(
            fileManager.contentsAtPath,
            [first.mapping.filePath, second.mapping.filePath, third.mapping.filePath]
        )
    }

    // A rewrite that missed thousands of mutants still gives an error that can be read.
    func test_aFilesMissingMutantsAreNamedUpToALimit() throws {
        let file = try mutatedFile(named: "Check")
        let missing = Array(repeating: file.mapping.mutationSchemata, count: 10).flatMap { $0 }
        XCTAssertGreaterThan(missing.count, CheckMutantSwitches.namedPerFile)

        let reason = CheckMutantSwitches.reason(
            for: [.init(mapping: file.mapping, missing: missing, unreadable: false)],
            usingTestPlan: false
        )

        XCTAssertEqual(reason.components(separatedBy: "\n    ").count - 1, CheckMutantSwitches.namedPerFile + 1, reason)
        XCTAssertTrue(reason.contains("    and \(missing.count - CheckMutantSwitches.namedPerFile) more"), reason)
    }

    // MARK: - Helpers

    private struct MutatedFile {
        let mapping: SchemataMutationMapping
        let original: String
        let rewritten: String
    }

    /// A file of the mutated project holding several mutants, before and after this SwiftMutator inserts their
    /// switches.
    private func mutatedFile(named name: String) throws -> MutatedFile {
        let source = SourceCodeInfo(
            path: "/path/to/muted/Sources/\(name).swift",
            code: Parser.parse(source: """
            func check(_ value: Int, _ flag: Bool) -> Bool {
                if value > 1 && flag {
                    return value == 2
                }
                return flag ? value < 0 : false
            }

            """)
        )
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)

        return MutatedFile(
            mapping: mapping,
            original: source.code.description,
            rewritten: MuterRewriter(mapping).rewrite(source.code).description
        )
    }

    /// The code the next file read holds, in the order the mappings are read.
    private func queueCode(_ code: String) {
        fileManager.fileContentsToReturn = Data(code.utf8)
    }
}
