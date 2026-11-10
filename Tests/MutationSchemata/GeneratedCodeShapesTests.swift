@testable import muterCore
import XCTest

/// Compiles the generated code of shapes of Swift whose switches are easy to get wrong, with the real compiler, and
/// runs it where that's cheap. Each test is named for its shape, so a failure names the shape that broke, and each
/// checks that the rewrite found mutants of that shape, so a fixture can't pass by holding none.
final class GeneratedCodeShapesTests: GeneratedCodeTestCase {
    /// The operators a test leaves out of its files. ReplaceReturnValue's empty value in place of a value that alone
    /// reads a local, as `return label` after `let label = ...`, leaves that local never used, which warns, and these
    /// files compile with warnings as errors; a test of other operators' shapes that has such a value leaves it out.
    /// Its own shapes compile in `test_theGeneratedCodeBuildsForReplacedReturnValues` and the tests beside it.
    var leftOutOperators: MutationOperatorList = []

    override var operatorsToDiscoverWith: MutationOperatorList {
        super.operatorsToDiscoverWith.filter { !leftOutOperators.contains($0) }
    }

    /// A result builder takes a switch as an `if` with an `else`, so it needs `buildEither`. A mutant in a builder
    /// closure's statement or `if` condition is switched in the closure's statements, and one in an `if` or `for`
    /// body in that body's, each of which is a component the builder combines. A builder property's or function's
    /// own statements are switched as well.
    func test_theGeneratedCodeBuildsInAResultBuilder() throws {
        let lines = Self.resultBuilderCode
        let compiled = try compileMutated(
            ["Lines.swift": lines],
            plain: ["main.swift": driver(#"print((report([5, 0]) + banner + footer(2)).joined(separator: ","))"#)]
        )

        let mutants = { compiled.operators(in: "Lines.swift", onTheLineHolding: $0) }
        XCTAssertEqual(
            mutants("if values.count > 1"), [.ror, .relationalBoundary, .negateConditional], "an if's condition"
        )
        XCTAssertEqual(
            mutants("values.isEmpty || values"), [.ror, .logicalOperator, .negateConditional], "an else if's condition"
        )
        XCTAssertEqual(mutants("value > 1 ?"), [.ror, .relationalBoundary, .swapTernary], "a component in a for body")
        XCTAssertEqual(
            mutants("values.count >= 3"), [.ror, .relationalBoundary, .logicalOperator, .swapTernary], "a component"
        )
        XCTAssertEqual(
            mutants("CommandLine.arguments"),
            [.ror, .relationalBoundary, .negateConditional],
            "a builder property's if condition"
        )
        XCTAssertEqual(mutants("count != 1"), [.ror, .swapTernary], "a builder function's component")

        let original = "start,many,big,small,short,banner,with arguments,items"
        XCTAssertEqual(try run(compiled.program).output, original + "\n", "no mutant named")
        let inTheForBody = try compiled.identifier(in: "Lines.swift") {
            $0.mutationOperatorId == .swapTernary && $0.snapshot.before.hasPrefix("value > 1")
        }
        XCTAssertEqual(
            try run(compiled.program, switchingOn: inTheForBody).output,
            "start,many,small,big,short,banner,with arguments,items\n",
            "the for body's ternary swapped"
        )
    }

    private static let resultBuilderCode = """
    @resultBuilder enum Lines {
        static func buildExpression(_ line: String) -> [String] { [line] }
        static func buildBlock(_ parts: [String]...) -> [String] { parts.flatMap { $0 } }
        static func buildOptional(_ part: [String]?) -> [String] { part ?? [] }
        static func buildEither(first part: [String]) -> [String] { part }
        static func buildEither(second part: [String]) -> [String] { part }
        static func buildArray(_ parts: [[String]]) -> [String] { parts.flatMap { $0 } }
    }

    func lines(@Lines _ make: () -> [String]) -> [String] { make() }

    func report(_ values: [Int]) -> [String] {
        lines {
            "start"
            if values.count > 1 {
                "many"
            } else if values.isEmpty || values.count == 1 {
                "few"
            }
            for value in values {
                value > 1 ? "big" : "small"
            }
            values.count >= 3 && values.first != nil ? "long" : "short"
        }
    }

    @Lines var banner: [String] {
        "banner"
        if CommandLine.arguments.count > 0 { "with arguments" }
    }

    @Lines func footer(_ count: Int) -> [String] {
        count != 1 ? "items" : "item"
    }
    """

    /// SwiftUI's `ViewBuilder`: a view's `body` is a builder, so the mutants nested in it are kept, and a modifier's
    /// argument there switches the whole body. A view property that isn't `body` is an opaque body that isn't a
    /// builder: a switch there is an `if` expression.
    func test_theGeneratedCodeBuildsInASwiftUIViewBuilder() throws {
        #if canImport(SwiftUI)
        let row = """
        import SwiftUI

        struct Row: View {
            var count: Int

            var body: some View {
                VStack {
                    Text(count > 1 ? "many" : "one")
                    if count >= 3 && count < 10 {
                        Text("several")
                    } else {
                        EmptyView()
                    }
                    badge
                }
                .opacity(count > 0 ? 1 : 0.5)
            }

            private var badge: some View {
                Text(count != 1 ? "items" : "item").bold()
            }
        }
        """
        let compiled = try compileMutated(["Row.swift": row])

        let mutants = { compiled.operators(in: "Row.swift", onTheLineHolding: $0) }
        XCTAssertEqual(
            mutants("Text(count > 1"), [.ror, .relationalBoundary, .swapTernary], "a component in the body's VStack"
        )
        XCTAssertEqual(
            mutants("if count >= 3"),
            [.ror, .relationalBoundary, .logicalOperator, .negateConditional],
            "an if's condition in the VStack"
        )
        XCTAssertEqual(mutants(".opacity"), [.ror, .relationalBoundary, .swapTernary], "a modifier's argument")
        XCTAssertEqual(mutants("count != 1"), [.ror, .swapTernary], "a view property that isn't body")
        #else
        throw XCTSkip("SwiftUI is only on Apple's platforms")
        #endif
    }

    /// A result builder with no `buildEither` can't take an `if` with an `else`, so a switch in its closure doesn't
    /// compile: "closure containing control flow statement cannot be used with result builder 'Sum'" (#206). Which
    /// builder a closure gets can't be told from its syntax, so after that build the closure's one expression is
    /// switched in a closure called on the spot, as one expression, with a `try` or an `await` where it needs one.
    func test_theGeneratedCodeBuildsInAResultBuilderWithoutBuildEither() throws {
        let sum = """
        @resultBuilder enum Sum {
            static func buildBlock(_ parts: Int...) -> Int { parts.reduce(0, +) }
        }

        func sum(@Sum _ make: () -> Int) -> Int { make() }
        func sum(of value: Int, @Sum _ make: (Int) -> Int) -> Int { make(value) }
        func trying(@Sum _ make: () throws -> Int) rethrows -> Int { try make() }
        func later(@Sum _ make: () async -> Int) async -> Int { await make() }
        func checked(_ value: Int) throws -> Int { value }
        func awaited(_ value: Int) async -> Int { value }

        func total(_ value: Int) -> Int { sum { value > 1 ? 10 : 20 } }
        func named(_ value: Int) -> Int {
            sum(of: value) { given in
                given > 1 ? 10 : 20
            }
        }
        func thrown(_ value: Int) throws -> Int { try trying { try checked(value) > 1 ? 10 : 20 } }
        func eventually(_ value: Int) async -> Int { await later { await awaited(value) > 1 ? 10 : 20 } }
        """
        let compiled = try compileMutated(
            ["Sum.swift": sum],
            plain: ["main.swift": driver(#"print(total(2), named(2), try thrown(2), await eventually(2))"#)],
            recovering: true
        )

        let code = try XCTUnwrap(compiled.rewritten["Sum.swift"])
        XCTAssertTrue(code.contains("sum { { if "), code)
        XCTAssertTrue(code.contains("try trying { try { if "), code)
        XCTAssertTrue(code.contains("await later { await { if "), code)
        XCTAssertEqual(try run(compiled.program).output, "10 10 10 10\n", "no mutant named")
        for function in ["func total", "given > 1", "func thrown", "func eventually"] {
            let swapped = try compiled.identifier(in: "Sum.swift") {
                $0.mutationOperatorId == .swapTernary && $0.position.line == Self.line(of: function, in: sum)
            }
            let output = try run(compiled.program, switchingOn: swapped).output
            let swappedValues = output.split(separator: " ").filter { $0.hasPrefix("20") }
            XCTAssertEqual(swappedValues.count, 1, "\(function): \(output)")
        }
    }

    /// The line of `code` that holds `text`, counting from 1.
    private static func line(of text: String, in code: String) -> Int {
        (code.components(separatedBy: "\n").firstIndex { $0.contains(text) } ?? -1) + 1
    }
}
