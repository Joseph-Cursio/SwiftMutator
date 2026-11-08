@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

/// Mutants with no statement list of their own but a file's top level, which can't hold a switch: initial values,
/// default arguments and a `main.swift`'s statements. The tests named for the generated code compile it with the real
/// compiler, and most run it with a mutant on, so they show the switch both builds and works. The others check what
/// discovery and `CompileRecovery` do with these places, from the syntax.
final class GeneratedCodeOutsideFunctionsTests: GeneratedCodeTestCase {
    private let values = """
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

    private var printingEveryValue: String {
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

    private let printingTheDefaults =
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
        func withAnImplicitMember(_ kind: Kind = CommandLine.arguments.count < 5 ? .made(flag: true) : .made()) -> Kind {
            kind
        }
        func withAComment(
            _ flag: Bool = CommandLine.arguments.count > 5 // says why
        ) -> Bool { flag }
        @MainActor func isolated(_ flag: Bool = CommandLine.arguments.count > 5) -> Bool { flag }
        func generic<T: ExpressibleByIntegerLiteral>(_ value: T = CommandLine.arguments.count < 5 ? 1 : 2) -> T { value }
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

/// What the review of these places found.
final class GeneratedCodeUnderAttributesTests: GeneratedCodeTestCase {
    /// `@TaskLocal` copies its value into a call, where an `if` expression doesn't compile, and a macro's error isn't
    /// in any file of the project.
    func test_theGeneratedCodeBuilds_underAMacroThatCopiesTheValueIntoACall() throws {
        let values = """
        import Foundation

        enum Trace {
            @TaskLocal static var on = CommandLine.arguments.count > 5
        }

        @MainActor struct Isolated {
            static let value = CommandLine.arguments.count > 5
        }

        @propertyWrapper struct Kept {
            var wrappedValue: Bool
        }

        struct Wrapped {
            @Kept var value = CommandLine.arguments.count > 5
        }

        @available(macOS 10.15, *) struct Available {
            let value = CommandLine.arguments.count > 5
        }
        """
        let compiled = try compileMutated(
            ["Values.swift": values],
            plain: ["main.swift": driver("print(Trace.on, Wrapped().value)")]
        )

        XCTAssertEqual(try run(compiled.program).output, "false false\n")
        let id = try XCTUnwrap(
            compiled.mutants(in: "Values.swift", onTheLineHolding: "@TaskLocal")
                .first { $0.mutationOperatorId == .ror }?.id
        )
        XCTAssertEqual(try run(compiled.program, switchingOn: id).output, "true false\n")
    }

    /// The closure's brace goes where the value started: touching the `=` doesn't compile, and after a comment on the
    /// `=`'s line it would be part of the comment.
    func test_theGeneratedCodeBuilds_whenAClosuresValueIsOnItsOwnLine() throws {
        let values = """
        func onItsOwnLine(
            _ flag: Bool =
                CommandLine.arguments.count > 5
        ) -> Bool { flag }

        func afterAComment(_ flag: Bool = // says why
            CommandLine.arguments.count > 5) -> Bool { flag }
        """
        let compiled = try compileMutated(
            ["Values.swift": values],
            plain: ["main.swift": driver("print(onItsOwnLine(), afterAComment())")]
        )

        XCTAssertEqual(try run(compiled.program).output, "false false\n")
        // Three of each default, RelationalOperatorReplacement's two and RelationalBoundary's, and
        // ReplaceBooleanValue's two of each body's `flag`.
        XCTAssertEqual(compiled.mutants(in: "Values.swift").count, 10)
    }

    func test_valuesThatCantHoldASwitch_areDropped() throws {
        let source = SourceCodeInfo(path: "/path/to/probe.swift", code: Parser.parse(source: """
        import Foundation

        func direct(_ make: () -> Int = 1 > 2 ? { 1 } : { 2 }) -> Int { make() }
        func attributed(_ make: @Sendable () -> Int = 1 > 2 ? { 1 } : { 2 }) -> Int { make() }
        func kept(_ make: @escaping () -> Int = 1 > 2 ? { 1 } : { 2 }) -> Int { make() }
        func auto(_ flag: @autoclosure () -> Bool = 1 > 2) -> Bool { flag() }
        let lineFirst = #line > 100
        """))
        let visitor = MutationOperator.Id.ror.visitor(.init(), source, .empty)
        visitor.walk(source.code)

        XCTAssertEqual(visitor.droppedMutants.map(\.position.line), [3, 3, 4, 4, 7, 7])
        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.position.line), [5, 5, 6, 6])
    }

    /// A value's switch is an `if` expression, whose branches must share a type: a switch in a builder closure of a
    /// generic type's initializer gives the original's branch another one.
    func test_aSwitchNestedInAValuesBuilderClosure_isDropped() throws {
        let source = SourceCodeInfo(path: "/path/to/probe.swift", code: Parser.parse(source: """
        let inferred = Card(1 > 2) { 3 > 4 ? 1 : 2 }
        let opaque: some Equatable = Card(1 > 2) { 3 > 4 ? 1 : 2 }
        let named: AnyCard = AnyCard(Card(1 > 2) { 3 > 4 ? 1 : 2 })
        let noOwnMutants = Card { 3 > 4 ? 1 : 2 }
        let notAType = items.filter { $0 > 4 }.count > 1
        """))
        var mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)

        let dropped = mapping.dropNestedSchemataInOpaqueBodies(of: source.code)

        XCTAssertEqual(Set(dropped.map(\.position.line)), [1, 2])
        XCTAssertEqual(Set(mapping.mutationSchemata.map(\.position.line)), [1, 2, 3, 4, 5])
        XCTAssertEqual(
            mapping.mutationSchemata.filter { $0.position.line == 1 }.map(\.snapshot.before), [">", ">", "1 > 2"]
        )
    }

    func test_aMacroExpansionsError_isPlacedWhereItsCodeCameFrom() {
        let log = """
        macro expansion @TaskLocal:1:30: \u{1B}[1;31merror: \u{1B}[1;39m'if' may only be used as expression\u{1B}[0;0m
        `- /p/Sources/Values.swift:4:40: \u{1B}[1;39mnote: \u{1B}[1;39mexpanded code originates here\u{1B}[0;0m
        macro expansion @Other:2:3: error: no note follows
        /p/Sources/Elsewhere.swift:9:1: error: another
        """

        XCTAssertEqual(CompilerError.all(in: log), [
            CompilerError(
                filePath: "/p/Sources/Values.swift",
                line: 4,
                column: 40,
                message: "'if' may only be used as expression"
            ),
            CompilerError(filePath: "macro expansion @Other", line: 2, column: 3, message: "no note follows"),
            CompilerError(filePath: "/p/Sources/Elsewhere.swift", line: 9, column: 1, message: "another"),
        ])
    }

    func test_aFileOfValuesOnly_isToldFromOneWithCode() throws {
        let file = directory.appendingPathComponent("Values.swift")
        let holdsOnlyValues = { (code: String) in
            try code.write(to: file, atomically: true, encoding: .utf8)
            return CoverageRegions.holdsOnlyValues(file.path)
        }

        XCTAssertTrue(try holdsOnlyValues("enum Limits { static let big = Int.max > 1 }\nlet global = 1 > 2\n"))
        XCTAssertFalse(try holdsOnlyValues("enum Empty {}\n"), "nothing to mutate")
        XCTAssertFalse(try holdsOnlyValues("let global = 1 > 2\nfunc code() {}\n"), "a function")
        XCTAssertFalse(try holdsOnlyValues("let global = { 1 > 2 }\n"), "a closure")
        XCTAssertFalse(try holdsOnlyValues("struct S { let stored = 1 > 2 }\n"), "an instance's value")
        XCTAssertFalse(try holdsOnlyValues("struct S { static var size: Bool { 1 > 2 } }\n"), "a getter")
        XCTAssertFalse(try holdsOnlyValues("let global = 1 > 2\nprint(global)\n"), "a statement")
    }
}
