@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

/// Mutants with no statement list of their own but a file's top level, which can't hold a switch: initial values,
/// default arguments and a `main.swift`'s statements. The tests named for the generated code compile it with the real
/// compiler, and most run it with a mutant on, so they show the switch both builds and works. The others check what
/// discovery and `CompileRecovery` do with these places, from the syntax.
final class GeneratedCodeOutsideFunctionsTests: GeneratedCodeTestCase {
    let values = """
    let globalValue = CommandLine.arguments.count > 5

    struct Config {
        static let staticValue = CommandLine.arguments.count > 5
        let storedValue = CommandLine.arguments.count > 5 // a comment after the value
        var observedValue = CommandLine.arguments.count > 5 {
            didSet { print("changed") }
        }
        lazy var lazyValue = CommandLine.arguments.count > 5
        let annotatedValue: Double = CommandLine.arguments.count < 5 ? 1 : 2.5
        let first = CommandLine.arguments.count > 5, second = CommandLine.arguments.count < 5
        let onItsOwnLine =
            CommandLine.arguments.count > 5
        let multiline = CommandLine.arguments
            .filter { !$0.isEmpty }
            .count > 5
        #if DEBUG
        let inAClause = CommandLine.arguments.count > 5
        #else
        let inAClause = CommandLine.arguments.count == 1000
        #endif
    }

    final class Holder {
        static let shared = (CommandLine.arguments.count > 5, CommandLine.arguments.count)
    }
    """

    var printingEveryValue: String {
        driver("""
        var config = Config()
        print(
            globalValue, Config.staticValue, config.storedValue, config.observedValue, config.lazyValue,
            config.annotatedValue, config.first, config.second, config.onItsOwnLine, config.multiline,
            config.inAClause, Holder.shared.0
        )
        """)
    }

    func test_theGeneratedCodeBuilds_andWorks_inInitialValues() throws {
        let compiled = try compileMutated(
            ["Values.swift": values],
            plain: ["main.swift": printingEveryValue],
            arguments: ["-D", "DEBUG"]
        )

        let original = "false false false false false 1.0 false true false false false false\n"
        XCTAssertEqual(try run(compiled.program).output, original)

        let cases = [
            ("globalValue =", "true false false false false 1.0 false true false false false false\n"),
            ("staticValue =", "false true false false false 1.0 false true false false false false\n"),
            ("storedValue =", "false false true false false 1.0 false true false false false false\n"),
            ("observedValue =", "false false false true false 1.0 false true false false false false\n"),
            ("lazyValue =", "false false false false true 1.0 false true false false false false\n"),
            (
                "inAClause = CommandLine.arguments.count > 5",
                "false false false false false 1.0 false true false false true false\n"
            ),
            ("shared =", "false false false false false 1.0 false true false false false true\n"),
        ]
        for (text, expected) in cases {
            let id = try XCTUnwrap(
                compiled.mutants(in: "Values.swift", onTheLineHolding: text)
                    .first { $0.mutationOperatorId == .ror }?.id
            )
            XCTAssertEqual(try run(compiled.program, switchingOn: id).output, expected, text)
        }

        XCTAssertEqual(
            compiled.operators(in: "Values.swift", onTheLineHolding: "annotatedValue:"),
            [.ror, .relationalBoundary, .swapTernary]
        )
        // The branches are `if`s, as `CompileRecovery` needs, each with a copy of the value.
        XCTAssertTrue(try XCTUnwrap(compiled.rewritten["Values.swift"]).contains("let staticValue = if __SwiftMutator"))
    }

    let printingTheDefaults =
        "print(plain(), inlinable(), Maker().flag, Maker()[], withAContextualType(), withAComment())"

    func test_theGeneratedCodeBuilds_andWorks_inDefaultArguments() throws {
        let defaults = """
        public enum Kind {
            case made(flag: Bool = CommandLine.arguments.count > 5)
        }

        public struct Maker {
            let flag: Bool
            public init(flag: Bool = CommandLine.arguments.count > 5) { self.flag = flag }
            public subscript(flag: Bool = CommandLine.arguments.count > 5) -> Bool { flag }
        }

        public func plain(_ flag: Bool = CommandLine.arguments.count > 5) -> Bool { flag }
        @inlinable public func inlinable(_ flag: Bool = CommandLine.arguments.count > 5) -> Bool { flag }
        func withAContextualType(_ number: Double = CommandLine.arguments.count < 5 ? 1 : 2.5) -> Double { number }
        func withAnImplicitMember(
            _ kind: Kind = CommandLine.arguments.count < 5 ? .made(flag: true) : .made()
        ) -> Kind {
            kind
        }
        func withAComment(
            _ flag: Bool = CommandLine.arguments.count > 5 // says why
        ) -> Bool { flag }
        @MainActor func isolated(_ flag: Bool = CommandLine.arguments.count > 5) -> Bool { flag }
        func generic<T: ExpressibleByIntegerLiteral>(
            _ value: T = CommandLine.arguments.count < 5 ? 1 : 2
        ) -> T { value }
        """
        let compiled = try compileMutated(
            ["Defaults.swift": defaults],
            plain: ["main.swift": driver(printingTheDefaults)]
        )

        XCTAssertEqual(try run(compiled.program).output, "false false false false 1.0 false\n")

        let id = try XCTUnwrap(
            compiled.mutants(in: "Defaults.swift", onTheLineHolding: "public func plain")
                .first { $0.mutationOperatorId == .ror }?.id
        )
        XCTAssertEqual(try run(compiled.program, switchingOn: id).output, "true false false false 1.0 false\n")
        let swapped = try compiled.identifier(in: "Defaults.swift") {
            $0.mutationOperatorId == .swapTernary && $0.snapshot.before.contains("1 : 2.5")
        }
        XCTAssertEqual(try run(compiled.program, switchingOn: swapped).output, "false false false false 2.5 false\n")
    }

    /// The mutation's `#Predicate` branch can't be an `if` expression's value alone, as a body's can't.
    func test_theGeneratedCodeBuilds_whenAnInitialValueIsAMacro() throws {
        let predicates = """
        import Foundation

        struct Filters {
            static let big = #Predicate<Int> { $0 > 5 }
            static let annotated: Predicate<Int> = #Predicate { $0 > 5 }
        }
        """
        let compiled = try compileMutated(
            ["Predicates.swift": predicates],
            plain: ["main.swift": driver("import Foundation\nprint(try Filters.big.evaluate(1))")]
        )

        XCTAssertEqual(try run(compiled.program).output, "false\n")
        let id = try XCTUnwrap(
            compiled.mutants(in: "Predicates.swift", onTheLineHolding: "static let big")
                .first { $0.mutationOperatorId == .ror }?.id
        )
        XCTAssertEqual(try run(compiled.program, switchingOn: id).output, "true\n")
    }

    func test_theGeneratedCodeBuilds_andWorks_inAMainFilesStatements() throws {
        let main = """
        import Darwin

        signal(SIGTRAP) { _ in _exit(70) }
        var total = 0
        if CommandLine.arguments.count > 5 { total += 1 }
        guard CommandLine.arguments.count < 5 else { exit(3) }
        total += CommandLine.arguments.count > 5 ? 10 : 20
        let bigger = total > 100
        for _ in 0 ..< (total > 100 ? 2 : 1) { total += 100 }
        if let found = total > 100 ? "found" : nil { print(found) }
        if total > 100 { print("first") }; print("second")
        #if canImport(Darwin)
        import Foundation
        print(total > 100)
        #endif
        func notSwitchedWithIt() -> Int { total }
        print(bigger, notSwitchedWithIt())
        """
        let compiled = try compileMutated(["main.swift": main], arguments: ["-swift-version", "5"])

        XCTAssertEqual(
            try run(compiled.program).output,
            "found\nfirst\nsecond\ntrue\nfalse 120\n"
        )
        // RelationalOperatorReplacement's mutant on the line that holds `text` that puts `after` in place.
        let mutant = { (text: String, after: String) in
            try XCTUnwrap(
                compiled.mutants(in: "main.swift", onTheLineHolding: text)
                    .first { $0.mutationOperatorId == .ror && $0.snapshot.after == after }?.id
            )
        }
        XCTAssertEqual(
            try run(compiled.program, switchingOn: mutant("> 5 { total", "!=")).output,
            "found\nfirst\nsecond\ntrue\nfalse 121\n"
        )
        XCTAssertEqual(try run(compiled.program, switchingOn: mutant("guard ", "false")).status, 3)
        XCTAssertEqual(
            try run(compiled.program, switchingOn: mutant("let bigger", "!=")).output,
            "found\nfirst\nsecond\ntrue\ntrue 120\n"
        )
        XCTAssertEqual(
            try run(compiled.program, switchingOn: mutant("print(\"first\")", "false")).output,
            "found\nsecond\ntrue\nfalse 120\n"
        )
        XCTAssertEqual(
            try run(compiled.program, switchingOn: mutant("print(total > 100)", "false")).output,
            "found\nfirst\nsecond\nfalse\nfalse 120\n"
        )
    }

    /// NegateConditional wraps a whole condition, so its switch goes around the statement, like any other's.
    func test_aMainFilesCondition_isNegated() throws {
        let main = """
        import Darwin

        signal(SIGTRAP) { _ in _exit(70) }
        var total = 0
        if CommandLine.arguments.count > 0 && total == 0 { total += 1 }
        guard total == 1 && CommandLine.arguments.count > 0 else { exit(3) }
        let chosen = if total == 1 && CommandLine.arguments.count > 0 { "first" } else { "second" }
        print(total, chosen)
        """
        let compiled = try compileMutated(["main.swift": main], arguments: ["-swift-version", "5"])

        XCTAssertEqual(try run(compiled.program).output, "1 first\n")
        let negated = { (text: String) in
            try XCTUnwrap(
                compiled.mutants(in: "main.swift", onTheLineHolding: text)
                    .first { $0.mutationOperatorId == .negateConditional }?.id
            )
        }
        XCTAssertEqual(try run(compiled.program, switchingOn: negated("total += 1")).status, 3)
        XCTAssertEqual(try run(compiled.program, switchingOn: negated("guard ")).status, 3)
        XCTAssertEqual(try run(compiled.program, switchingOn: negated("let chosen")).output, "1 second\n")
    }
}
