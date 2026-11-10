@testable import muterCore
import SnapshotTesting
import SwiftParser
import SwiftSyntax
import TestingExtensions
import XCTest

extension RewriterTests {
    // A macro expands its arguments from their syntax. Switched in its closure, `#Predicate { $0.id == id }` turned the
    // switch's `if` and its `ProcessInfo` lookup into predicate expressions, which didn't compile ("cannot convert
    // value of type 'PredicateExpressions.Conditional<…>'", MacCloud_client_iOS). Its mutants are switched in the list
    // around the macro instead, each branch holding the macro with or without the mutant.
    func test_switchesAroundAMacro_neverInsideItsArguments() throws {
        let source = SourceCodeInfo(path: "/path/to/fetch.swift", code: Parser.parse(source: """
        func fetch(_ id: String, in items: [Item]) -> [Item] {
            let predicate = #Predicate<Item> { $0.id == id && $0.size > 0 }
            return try items.filter(predicate)
        }
        """))
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)

        // `&&` gets one mutant, `==` two, RelationalOperatorReplacement's constants, and `>` three, that operator's
        // swap and constant and RelationalBoundary's; and the returned array ReplaceReturnValue's `[]`.
        XCTAssertEqual(mapping.mutationSchemata.count, 7)
        XCTAssertEqual(mapping.codeBlocks.count, 1)
        let block = try XCTUnwrap(mapping.codeBlocks.first)
        XCTAssertTrue(block.contains("let predicate") && block.contains("return try"), block)

        let rewritten = MuterRewriter(mapping).rewrite(source.code).description
        let macroBodies = rewritten
            .components(separatedBy: "#Predicate<Item> {")
            .dropFirst()
            .map { $0.prefix { $0 != "}" } }
        XCTAssertEqual(macroBodies.count, mapping.mutationSchemata.count + 1, rewritten)
        XCTAssertFalse(macroBodies.contains { $0.contains("ProcessInfo") || $0.contains("if ") }, rewritten)
    }

    // A body whose value is its one macro, the usual way to write a SwiftData predicate. As the body's value, an `if`
    // expression whose branches are `#Predicate { … }` doesn't compile ("value pack expansion can only appear inside a
    // function argument list"), so each branch returns its macro: an `if` statement.
    func test_aBodyWhoseValueIsAMacro_returnsItInEachBranch() throws {
        let bodies = [
            "func byID(_ id: String) -> Predicate<Item> { #Predicate { $0.id == id } }",
            "var nonEmpty: Predicate<Item> { #Predicate { $0.size > 0 } }",
            "var nonEmpty: Predicate<Item> { get { #Predicate { $0.size > 0 } } }",
            "let byLimit = limits.map { limit in #Predicate<Item> { $0.size < limit } }",
        ]
        for body in bodies {
            let source = SourceCodeInfo(path: "/path/to/Predicates.swift", code: Parser.parse(source: body))
            let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first, body)

            let rewritten = MuterRewriter(mapping).rewrite(source.code).description
            let returns = rewritten.components(separatedBy: "return #Predicate").count - 1
            XCTAssertEqual(returns, mapping.mutationSchemata.count + 1, rewritten)
        }
    }

    // An initializer may return no value, and `return` in a `case` would leave the function, so neither gets one.
    func test_anInitializerOrACaseWhoseOneItemIsAMacro_returnsNothing() throws {
        let bodies = [
            "struct Check { init(_ size: Int) { #expect(size > 0) } }",
            "func check(_ size: Int) { switch size { case 0: #expect(size < 1) default: break } }",
        ]
        for body in bodies {
            let source = SourceCodeInfo(path: "/path/to/Check.swift", code: Parser.parse(source: body))
            let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first, body)

            let rewritten = MuterRewriter(mapping).rewrite(source.code).description
            XCTAssertFalse(rewritten.contains("return #expect"), rewritten)
        }
    }

    // A macro in a closure inside a macro: the list switched is the one around the outermost macro.
    func test_switchesAroundTheOutermostMacro() throws {
        let source = SourceCodeInfo(path: "/path/to/check.swift", code: Parser.parse(source: """
        func check(_ items: [Item]) {
            #outer(items.map { item in
                let fits = #inner { item.size < 9 }
                return fits
            })
        }
        """))
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)

        XCTAssertEqual(mapping.codeBlocks.count, 1)
        let block = try XCTUnwrap(mapping.codeBlocks.first)
        XCTAssertTrue(block.trimmed.hasPrefix("#outer"), block)
    }

    // At a file's top level, around a macro there is only the file's declarations, which a switch can't wrap, so the
    // macro's mutants are left out, as a stored property's are.
    func test_aMacroAtFileScope_hasNoMutants() throws {
        let source = SourceCodeInfo(path: "/path/to/Preview.swift", code: Parser.parse(source: """
        import SwiftUI

        #Preview {
            Text(1 < 2 ? "a" : "b")
        }
        """))

        XCTAssertEqual(generateSchemataMappings(for: source).flatMap(\.mutationSchemata).count, 0)
    }
}
