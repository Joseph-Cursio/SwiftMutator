import Foundation
@testable import muterCore
import XCTest

/// How a test plan is written: a file people read, diff and commit, whose bytes depend only on its mutants.
final class TestPlanCodingTests: XCTestCase {
    private let copy = "/path/to/project_mutated"

    // A file's mutants are kept in a dictionary by code block, so the second plan's are added in the other order.
    func test_twoEqualPlans_areTheSameBytes() throws {
        let first = try plan()
        let second = try plan(addingBlocksInReverse: true)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try TestPlanCoding.encode(first), try TestPlanCoding.encode(second))
    }

    // Declared order would put mutatedProjectPath first, and a mutant's id before its filePath.
    func test_keysAreSorted() throws {
        let text = try TestPlanCoding.encode(plan())

        assertInOrder(text, ["\"mappings\"", "\"mutatedProjectPath\"", "\"projectCoverage\""])
        let mutant = try String(
            decoding: TestPlanCoding.encoder.encode(mutant(in: "\(copy)/Sources/Sum.swift", line: 1)),
            as: UTF8.self
        )
        assertInOrder(mutant, ["\"filePath\"", "\"id\"", "\"mutationOperatorId\"", "\"position\"", "\"snapshot\""])
    }

    func test_pathsKeepTheirSlashes() throws {
        let text = try TestPlanCoding.encode(plan())

        XCTAssertFalse(text.contains("\\/"))
        XCTAssertTrue(text.contains("\"mutatedProjectPath\" : \"\(copy)\""))
    }

    func test_eachKeyIsOnALineOfItsOwn_andThePlanEndsInOneNewline() throws {
        let text = try TestPlanCoding.encode(plan())

        XCTAssertTrue(text.hasPrefix("{\n  \"mappings\" : ["))
        XCTAssertTrue(text.hasSuffix("}\n"))
        XCTAssertFalse(text.hasSuffix("\n\n"))
    }

    // A plan records no syntax, so what it reads back as is compared by the text it would write.
    func test_aPlanReadsBackAsItWasWritten() throws {
        let text = try TestPlanCoding.encode(plan())

        let read = try JSONDecoder().decode(MuterTestPlan.self, from: Data(text.utf8))

        XCTAssertEqual(try TestPlanCoding.encode(read), text)
    }

    // A plan written by a SwiftMutator from before plans were pretty-printed is one line, in declared key order.
    func test_aPlanOnOneLine_readsAsBefore() throws {
        let plan = try plan()
        let line = try JSONEncoder().encode(plan)

        let read = try JSONDecoder().decode(MuterTestPlan.self, from: line)

        XCTAssertEqual(try TestPlanCoding.encode(read), try TestPlanCoding.encode(plan))
    }

    private func plan(addingBlocksInReverse: Bool = false) throws -> MuterTestPlan {
        var sum = SchemataMutationMapping(filePath: "\(copy)/Sources/Sum.swift")
        // Each block's leading spaces put its first statement at an offset of its own.
        for number in addingBlocksInReverse ? Array((1 ... 8).reversed()) : Array(1 ... 8) {
            let block = try sourceCode(String(repeating: " ", count: number) + "let block\(number) = \(number)")
            try sum.add(block.statements, mutant(in: sum.filePath, line: number))
        }
        return .make(
            mutatedProjectPath: copy,
            projectCoverage: 47,
            mappings: [
                try .make(
                    filePath: "\(copy)/Sources/Max.swift",
                    (source: "let max = 1", schemata: [mutant(in: "\(copy)/Sources/Max.swift", line: 3)])
                ),
                sum,
            ]
        )
    }

    private func mutant(in filePath: String, line: Int) throws -> MutationSchema {
        try .make(
            filePath: filePath,
            mutationOperatorId: .ror,
            position: MutationPosition(utf8Offset: line * 100 + 5, line: line, column: 5),
            snapshot: .make(before: "a > b", after: "a < b", description: "changed > to <"),
            under: URL(fileURLWithPath: copy)
        )
    }

    private func assertInOrder(
        _ text: String,
        _ keys: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let offsets = keys.map { text.range(of: $0)?.lowerBound }
        XCTAssertFalse(offsets.contains(nil), "Missing one of \(keys) in \(text)", file: file, line: line)
        let found = offsets.compactMap { $0 }
        XCTAssertEqual(found, found.sorted(), "\(keys) aren't in this order in \(text)", file: file, line: line)
    }
}
