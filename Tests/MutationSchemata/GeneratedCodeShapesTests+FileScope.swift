@testable import muterCore
import XCTest

extension GeneratedCodeShapesTests {
    /// A `#if` at file scope, around declarations, with mutants in the active clause and in the inactive ones:
    /// discovery visits every clause, and an inactive clause's switches need only parse. A mutant whose nearest
    /// statements are the file's, or those of a clause that declares something, is refused, since a switch can't go
    /// there; that refusal alone keeps out the mutants of a file-scope `#if` condition. A `#if` in a function's
    /// statements, where a switch can go, shows that its condition is never mutated: a switch there would split the
    /// directive. The flag is one nobody defines, so the same clause is active on every machine.
    func test_theGeneratedCodeBuildsAroundAFileScopeIf() throws {
        let modes = Self.fileScopeIfCode
        let compiled = try compileMutated(
            ["Modes.swift": modes],
            plain: ["main.swift": driver("print(mode(5), Settings().level, Limits.isLarge, size(of: 5))")]
        )

        let mutants = { compiled.operators(in: "Modes.swift", onTheLineHolding: $0) }
        XCTAssertEqual(
            mutants("inactive big"),
            [.ror, .relationalBoundary, .swapTernary, .replaceReturnValue],
            "the inactive #if clause"
        )
        XCTAssertEqual(
            mutants("? \"big\""),
            [.ror, .relationalBoundary, .logicalOperator, .swapTernary, .replaceReturnValue],
            "the active #elseif clause"
        )
        XCTAssertEqual(mutants("other big"), [.ror, .swapTernary, .replaceReturnValue], "the inactive #else clause")
        XCTAssertEqual(
            mutants("var level"),
            [.ror, .relationalBoundary, .swapTernary, .replaceReturnValue],
            "a getter in a #if clause of a type's members"
        )
        XCTAssertEqual(mutants("#elseif"), [], "a #if condition, in the file's statements")
        XCTAssertEqual(mutants("#if (SWIFTMUTATOR"), [], "a #if condition in parentheses, in the file's statements")
        XCTAssertEqual(mutants("#if os(Windows)"), [], "a #if condition in a function's statements")
        XCTAssertEqual(
            mutants("return value > 1"),
            [.ror, .relationalBoundary, .swapTernary, .replaceReturnValue],
            "a #if clause of a function's statements"
        )
        XCTAssertEqual(
            mutants("Int.max > 2"),
            [.ror, .relationalBoundary, .replaceBooleanValue],
            "a stored property, switched in its value"
        )
        XCTAssertEqual(
            mutants("Int.max > 1"),
            [.ror, .relationalBoundary, .replaceBooleanValue],
            "a stored property, switched in its value"
        )
        try assertFileScopeIfRuns(compiled)
    }

    /// Checks no switch went in the file's own statements, then runs the program with and without a mutant.
    private func assertFileScopeIfRuns(_ compiled: Compiled) throws {
        let rewritten = compiled.rewritten["Modes.swift"] ?? ""
        XCTAssertFalse(
            rewritten.contains("\nif __SwiftMutator_"),
            "a switch in the file's own statements:\n\(rewritten)"
        )

        XCTAssertEqual(try run(compiled.program).output, "big 2 true 2\n", "no mutant named")
        let inTheActiveClause = try compiled.identifier(in: "Modes.swift") {
            $0.mutationOperatorId == .swapTernary && $0.snapshot.before.hasPrefix("value >= 1")
        }
        XCTAssertEqual(
            try run(compiled.program, switchingOn: inTheActiveClause).output,
            "small 2 true 2\n",
            "the active clause's ternary swapped"
        )
    }

    private static let fileScopeIfCode = """
    #if SWIFTMUTATOR_NEVER_DEFINED
    func mode(_ value: Int) -> String { value > 1 ? "inactive big" : "inactive small" }
    #elseif !SWIFTMUTATOR_NEVER_DEFINED && (os(macOS) || os(Linux))
    func mode(_ value: Int) -> String { value >= 1 && value < 100 ? "big" : "small" }
    #else
    func mode(_ value: Int) -> String { value != 0 ? "other big" : "other small" }
    #endif

    #if (SWIFTMUTATOR_NEVER_DEFINED || os(Windows))
    enum Limits { static let isLarge = Int.max > 2 }
    #else
    enum Limits { static let isLarge = Int.max > 1 }
    #endif

    struct Settings {
        var count = 1
        #if !SWIFTMUTATOR_NEVER_DEFINED
        var level: Int { count > 0 ? 2 : 3 }
        #endif
    }

    func size(of value: Int) -> Int {
        #if os(Windows) || !SWIFTMUTATOR_NEVER_DEFINED
        return value > 1 ? 2 : 3
        #else
        return 0
        #endif
    }
    """

    /// A `main.swift` of top-level code. Its own statements hold a declaration, the `ProcessInfo` import added in
    /// front if nothing else, so a mutant there is switched in its statement or a global's value alone; one in a `for`
    /// or `if` body, a closure, a function, or a `#if` clause of statements only is switched there. The switches read
    /// the cache declared after them, at the file's end.
    func test_theGeneratedCodeBuildsInTopLevelCode() throws {
        let main = driver(Self.topLevelCode)
        let compiled = try compileMutated(["main.swift": main])

        let mutants = { compiled.operators(in: "main.swift", onTheLineHolding: $0) }
        XCTAssertEqual(
            mutants("func doubled"),
            [.ror, .relationalBoundary, .swapTernary, .arithmeticOperator, .replaceReturnValue],
            "a function"
        )
        XCTAssertEqual(mutants("let values"), [.ror, .relationalBoundary, .swapTernary], "a global's value")
        XCTAssertEqual(mutants("total += value"), [.ror, .relationalBoundary, .swapTernary], "a for body")
        XCTAssertEqual(mutants("let isLarge"), [.ror, .relationalBoundary, .replaceBooleanValue], "a closure")
        XCTAssertEqual(
            mutants("total >= 5"),
            [.ror, .relationalBoundary, .logicalOperator, .swapTernary],
            "a #if clause of statements"
        )
        XCTAssertEqual(mutants("if total < 100"), [.negateConditional, .ror, .relationalBoundary], "an if's condition")
        XCTAssertEqual(mutants("print(isLarge"), [.swapTernary], "an if body")

        XCTAssertEqual(try run(compiled.program).output, "large\noriginal 10\n", "no mutant named")
        let inTheClosure = try XCTUnwrap(
            compiled.mutants(in: "main.swift", onTheLineHolding: "let isLarge")
                .first { $0.mutationOperatorId == .ror && $0.snapshot.after == "false" }
        ).id
        XCTAssertEqual(
            try run(compiled.program, switchingOn: inTheClosure).output,
            "large\nmutant 10\n",
            "the closure's comparison changed"
        )
        let inTheIf = try compiled.identifier(in: "main.swift") {
            $0.mutationOperatorId == .swapTernary && $0.snapshot.before.hasPrefix("total >= 5")
        }
        XCTAssertEqual(
            try run(compiled.program, switchingOn: inTheIf).output,
            "small\noriginal 10\n",
            "the #if clause's ternary swapped"
        )
    }

    private static let topLevelCode = """
    func doubled(_ value: Int) -> Int { value > 0 ? value * 2 : 0 }

    let values = CommandLine.arguments.count > 5 ? [9] : [1, 5]
    var total = 0
    for value in values {
        total += value > 1 ? value : 0
    }
    let isLarge = { (value: Int) -> Bool in value > 1 }
    #if !SWIFTMUTATOR_NEVER_DEFINED
    print(total >= 5 && values.count != 0 ? "large" : "small")
    #endif
    if total < 100 {
        print(isLarge(total) ? "original" : "mutant", doubled(total))
    }
    """
}
