@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

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
