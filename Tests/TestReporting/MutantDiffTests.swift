@testable import muterCore
import XCTest

final class MutantDiffTests: XCTestCase {
    // An operator's mutant is at its start, so the `>` of `->` on the same line isn't taken for it.
    func test_anOperatorsChange_isTheOneAtItsColumn() throws {
        let source = "func isPositive(_ value: Int) -> Bool { value > 0 }\n"
        let schema = try XCTUnwrap(schemata(MutationOperator.Id.ror.visitor, in: source).first)

        XCTAssertEqual(diff(of: schema, in: source), [
            "-1: func isPositive(_ value: Int) -> Bool { value > 0 }",
            "+1: func isPositive(_ value: Int) -> Bool { value != 0 }",
        ])
    }

    // A replaced Bool's `true` is placed where the value starts, and its `false` where it ends, on the same line.
    func test_bothMutantsOfAReplacedBool_giveTheirLine() throws {
        let source = """
        func isIdle(_ queue: [Int]) -> Bool {
            return queue.isEmpty
        }

        """
        let schemata = schemata(MutationOperator.Id.replaceBooleanValue.visitor, in: source)

        XCTAssertEqual(schemata.map { diff(of: $0, in: source) }, [
            ["-2:     return queue.isEmpty", "+2:     return true"],
            ["-2:     return queue.isEmpty", "+2:     return false"],
        ])
    }

    // `return(a < b)` becomes `return true`, as the mutant keeps the literal apart from the keyword.
    func test_aReplacedBoolTouchingItsKeyword_isShownWithTheSpaceItGets() throws {
        let source = """
        func f(_ a: Int, _ b: Int) -> Bool {
            return(a < b)
        }

        """
        let schemata = schemata(MutationOperator.Id.replaceBooleanValue.visitor, in: source)

        XCTAssertEqual(schemata.map { diff(of: $0, in: source) }, [
            ["-2:     return(a < b)", "+2:     return true"],
            ["-2:     return(a < b)", "+2:     return false"],
        ])
    }

    // `return(x)` becomes `return 0` and `return []`, as the mutant keeps the empty value apart from the keyword.
    func test_aReplacedReturnValueTouchingItsKeyword_isShownWithTheSpaceItGets() throws {
        let source = """
        func count() -> Int {
            return(x)
        }
        func all() -> [Int] {
            return(x)
        }

        """
        let schemata = schemata(MutationOperator.Id.replaceReturnValue.visitor, in: source)

        XCTAssertEqual(schemata.map { diff(of: $0, in: source) }, [
            ["-2:     return(x)", "+2:     return 0"],
            ["-5:     return(x)", "+5:     return []"],
        ])
    }

    // A return value over several lines isn't found at its place, as the snapshot gives it on one line, and its mutant
    // is placed where it starts, so the same code on a line above is another's.
    func test_aReturnValueOverSeveralLines_isntTakenForACopyAbove() throws {
        let source = """
        func f(_ a: [Int], _ b: [Int]) -> [Int] {
            print(a + b)
            return a +
                b
        }

        """
        let schema = try XCTUnwrap(schemata(MutationOperator.Id.replaceReturnValue.visitor, in: source).first)

        XCTAssertEqual(schema.snapshot.before, "a + b")
        XCTAssertNil(diff(of: schema, in: source))
        XCTAssertEqual(
            MutantDiff.fallback(snapshot: schema.snapshot, mutationOperatorId: .replaceReturnValue),
            ["- a + b", "+ []"]
        )
    }

    // A comparison's `true` is placed where it starts, its `false` where it ends, and its swap at its operator.
    func test_eachMutantOfAComparison_givesItsLine() throws {
        let source = """
        func f(_ a: Int, _ b: Int) -> Bool {
            if a == b { return a.count <= b }
            return(a < b)
        }

        """
        let schemata = schemata(MutationOperator.Id.ror.visitor, in: source)

        XCTAssertEqual(schemata.map { diff(of: $0, in: source) }, [
            ["-2:     if a == b { return a.count <= b }", "+2:     if true { return a.count <= b }"],
            ["-2:     if a == b { return a.count <= b }", "+2:     if false { return a.count <= b }"],
            ["-2:     if a == b { return a.count <= b }", "+2:     if a == b { return true }"],
            ["-2:     if a == b { return a.count <= b }", "+2:     if a == b { return a.count == b }"],
            ["-3:     return(a < b)", "+3:     return(a != b)"],
            ["-3:     return(a < b)", "+3:     return(false)"],
        ])
    }

    // A swapped ternary's mutant is at its end, so its change is the only one on its line.
    func test_aOneLineMatch_givesTheLineBeforeAndAfter() throws {
        let source = """
        func pick(_ flag: Bool) -> Int {
            return flag ? 1 : 2
        }

        """
        let schema = try XCTUnwrap(schemata(MutationOperator.Id.swapTernary.visitor, in: source).first)

        XCTAssertEqual(diff(of: schema, in: source), [
            "-2:     return flag ? 1 : 2",
            // As the snapshot gives it, with the space before `2` now before `1`.
            "+2:     return flag ? 2 :  1",
        ])
    }

    func test_aLaterLinkOfAChain_givesItsLine() throws {
        let source = """
        func pick(_ a: Bool, _ b: Bool) -> Int {
            return a ? 1 : b ? 2 : 3
        }

        """
        let schema = try XCTUnwrap(
            schemata(MutationOperator.Id.swapTernary.visitor, in: source).first { $0.snapshot.before == "b ? 2 : 3" }
        )

        XCTAssertEqual(diff(of: schema, in: source), [
            "-2:     return a ? 1 : b ? 2 : 3",
            "+2:     return a ? 1 : b ? 3 :  2",
        ])
    }

    // A later link is placed at its `?`, so the same code on a line above is another ternary, not its own.
    func test_aLaterLinkOverSeveralLines_isntTakenForTheSameCodeOnALineAbove() throws {
        let source = """
        func pick(_ a: Bool, _ b: Bool) -> Int {
            let first = b ? 2 : 3
            let second = a ? 1
                : b ? 2
                : 3
            return first + second
        }

        """
        let schema = try XCTUnwrap(
            schemata(MutationOperator.Id.swapTernary.visitor, in: source).first { $0.position.line == 4 }
        )

        XCTAssertNil(diff(of: schema, in: source))
    }

    // The nearest line above, up to 5, as for a mutant at the end of code that a comment follows on its own lines.
    func test_theChangeIsLookedForUpToFiveLinesAbove_nearestFirst() {
        let snapshot = MutationOperator.Snapshot(before: "x ? 1 : 2", after: "x ? 2 : 1", description: "")
        let original = ["let a = x ? 1 : 2", "let b = x ? 1 : 2", "", "", "", "", "", ""].joined(separator: "\n")

        let fromLine = { (line: Int) in
            MutantDiff.lines(
                original: original, snapshot: snapshot, mutationOperatorId: .swapTernary, line: line, column: 1
            )
        }

        XCTAssertEqual(fromLine(7), ["-2: let b = x ? 1 : 2", "+2: let b = x ? 2 : 1"])
        XCTAssertNil(fromLine(8))
    }

    // A condition over several lines isn't found at its place, as the snapshot gives it on one line, and its mutant is
    // placed at its start, so a copy above is another condition's.
    func test_aNegatedConditionOverSeveralLines_isntTakenForACopyAbove() {
        let snapshot = MutationOperator.Snapshot(before: "a && b", after: "!(a && b)", description: "")
        let original = "    if a && b { return 1 }\n    if a &&\n        b { return 2 }\n"

        XCTAssertNil(
            MutantDiff.lines(
                original: original, snapshot: snapshot, mutationOperatorId: .negateConditional, line: 2, column: 8
            )
        )
    }

    // `if!(` doesn't parse, and isn't what the operator writes.
    func test_aNegatedConditionTouchingItsKeyword_isShownWithTheSpaceItGets() {
        let snapshot = MutationOperator.Snapshot(before: "(b)", after: "!((b))", description: "")

        XCTAssertEqual(
            MutantDiff.lines(
                original: "} else if(b) {",
                snapshot: snapshot,
                mutationOperatorId: .negateConditional,
                line: 1,
                column: 10
            ),
            ["-1: } else if(b) {", "+1: } else if !((b)) {"]
        )
    }

    func test_aNegatedCondition_isShownWithoutASpaceItDoesntGet() {
        let snapshot = MutationOperator.Snapshot(before: "b", after: "!(b)", description: "")

        XCTAssertEqual(
            MutantDiff.lines(
                original: "if b {", snapshot: snapshot, mutationOperatorId: .negateConditional, line: 1, column: 4
            ),
            ["-1: if b {", "+1: if !(b) {"]
        )
    }

    // A removed statement leaves nothing of its line, or what else the line holds.
    func test_aRemovedStatement_hasNoPlusLine_unlessSomethingIsLeftOfItsLine() {
        let snapshot = MutationOperator.Snapshot(before: "save()", after: "removed line", description: "removed line")

        XCTAssertEqual(
            MutantDiff.lines(
                original: "func f() {\n    save()\n}\n",
                snapshot: snapshot,
                mutationOperatorId: .removeSideEffects,
                line: 2,
                column: 11
            ),
            ["-2:     save()"]
        )
        XCTAssertEqual(
            MutantDiff.lines(
                original: "func f() {\n    load(); save()\n}\n",
                snapshot: snapshot,
                mutationOperatorId: .removeSideEffects,
                line: 2,
                column: 19
            ),
            ["-2:     load(); save()", "+2:     load(); "]
        )
        XCTAssertEqual(MutantDiff.fallback(snapshot: snapshot, mutationOperatorId: .removeSideEffects), ["- save()"])
    }

    // A line ending of CR LF isn't part of the line.
    func test_crlfLineEndings_areLeftOut() {
        let snapshot = MutationOperator.Snapshot(before: "x ? 1 : 2", after: "x ? 2 : 1", description: "")

        XCTAssertEqual(
            MutantDiff.lines(
                original: "let a = 0\r\nlet b = x ? 1 : 2\r\n",
                snapshot: snapshot,
                mutationOperatorId: .swapTernary,
                line: 2,
                column: 18
            ),
            ["-2: let b = x ? 1 : 2", "+2: let b = x ? 2 : 1"]
        )
    }
}
