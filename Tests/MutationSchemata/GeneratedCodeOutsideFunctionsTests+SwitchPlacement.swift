@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

extension GeneratedCodeOutsideFunctionsTests {
    func test_mutantsWithNoPlaceForASwitch_areLeftOut_andSaidToBe() throws {
        let source = SourceCodeInfo(
            path: "/path/to/project/Sources/main.swift",
            code: Parser.parse(source: """
            import Foundation

            let value = CommandLine.arguments.count
            guard let name = value > 1 ? "name" : nil else { exit(1) }
            guard case let .some(other) = value > 1 ? "name" : nil else { exit(1) }
            @Wrapper(value > 1) var wrapped = 1
            #freestanding(value > 1)
            print(name, other, wrapped)
            """)
        )
        let visitor = MutationOperator.Id.ror.visitor(.init(), source, .empty)
        visitor.projectRoot = URL(fileURLWithPath: "/path/to/project")
        visitor.walk(source.code)

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.count, 0)
        XCTAssertEqual(visitor.droppedMutants.map(\.position.line), [4, 4, 5, 5, 6, 6, 7, 7])
        XCTAssertEqual(Set(visitor.droppedMutants.map(\.reason)), [.noPlaceForASwitch])
        XCTAssertEqual(
            visitor.droppedMutants.first?.line,
            "Sources/main.swift:4:27 RelationalOperatorReplacement (replaced the comparison with false): "
                + "in code at a file's or a type's top level that can hold no switch"
        )
    }

    /// A body whose one statement holds the mutant has the same offset and text as the statement.
    func test_aBodysOneStatement_isSwitchedOnce() throws {
        let source = SourceCodeInfo(
            path: "/path/to/probe.swift",
            code: Parser.parse(source: "func check(_ value: Int) -> Bool { value > 1 }\n")
        )
        let visitor = MutationOperator.Id.ror.visitor(.init(), source, .empty)
        visitor.walk(source.code)

        let rewritten = MuterRewriter(visitor.schemataMappings).rewrite(source.code).description
        // The swap and the constant, each once.
        XCTAssertEqual(rewritten.components(separatedBy: ".environment[").count - 1, 2, rewritten)
    }

    /// `CompileRecovery` can only pin an error on a mutant whose branch is an `if` of a switch.
    func test_aCompileErrorInAValuesOrADefaultArgumentsBranch_isThatMutants() throws {
        let source = SourceCodeInfo(
            path: "/path/to/probe.swift",
            code: Parser.parse(source: """
            import Foundation

            let value = 1 > 2
            func check(_ flag: Bool = 3 > 4) {}
            """)
        )
        let visitor = MutationOperator.Id.ror.visitor(.init(), source, .empty)
        visitor.walk(source.code)
        let mapping = visitor.schemataMappings
        let code = MuterRewriter(mapping).rewrite(source.code).description
        let locator = MutantLocator(rewritten: code, filePath: source.path)
        let converter = SourceLocationConverter(fileName: source.path, tree: Parser.parse(source: code))

        for (mutated, line) in [("1 != 2", 3), ("3 != 4", 4)] {
            let id = try XCTUnwrap(
                mapping.mutationSchemata.first { $0.position.line == line && $0.snapshot.after == "!=" }?.id
            )
            let place = try XCTUnwrap(code.range(of: mutated))
            let location = converter.location(for: AbsolutePosition(utf8Offset: code.utf8.distance(
                from: code.utf8.startIndex,
                to: place.lowerBound
            )))
            // The swap and the constant share the value's switch, each a branch of its own, the later one first.
            let chain = Array(mapping.mutationSchemata.filter { $0.position.line == line }.map(\.id).reversed())
            XCTAssertEqual(locator.place(line: location.line, column: location.column), .branch(id, chain: chain))
        }
    }
}
