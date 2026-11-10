@testable import muterCore
import Rainbow
import SwiftParser
import XCTest

/// An operator's change as its documentation's example shows it: the code before, and after.
private struct DocumentedSwap {
    let id: MutationOperator.Id
    let before: String
    let after: String
}

/// `swift-mutator operator`, which describes a mutation operator, or all of them. The descriptions are read without
/// their colour codes (`raw`), so the tests see the words a terminal shows.
final class OperatorTests: MuterTestCase {
    func test_eachOperator_isDescribedByItsName() throws {
        let titles: [MutationOperator.Id: String] = [
            .ror: "Relational Operator Replacement",
            .relationalBoundary: "Relational Boundary",
            .removeSideEffects: "Remove Side Effects",
            .logicalOperator: "Change Logical Connector",
            .swapTernary: "Swap Ternary",
            .negateConditional: "Negate Conditional",
            .arithmeticOperator: "Change Arithmetic Operator",
            .flipBooleanLiteral: "Flip Boolean Literal",
            .replaceBooleanValue: "Replace Boolean Value",
            .replaceReturnValue: "Replace Return Value",
        ]

        for id in MutationOperator.Id.allCases {
            let printedBefore = printer.linesPassed.count
            try run(id.rawValue)

            let printed = Array(printer.linesPassed.dropFirst(printedBefore))
            XCTAssertEqual(printed, [id.documentation], id.rawValue)
            XCTAssertEqual(printed.first?.raw.contains(try XCTUnwrap(titles[id])), true, id.rawValue)
        }
    }

    // In the order the operators are listed everywhere else, a blank line between each, and with spaces around "all".
    func test_all_describesEveryOperator_inOrder() throws {
        try run("all")
        try run(" all ")

        let expected = MutationOperator.Id.allCases.map(\.documentation).joined(separator: "\n\n")
        XCTAssertEqual(printer.linesPassed, [expected, expected])
    }

    // An operator is named as the configuration and --operators name it, in full and in its case.
    func test_anUnknownOperator_isRefused_namingTheOperators() throws {
        for name in ["ror", "relationaloperatorreplacement", "", "Everything"] {
            do {
                try run(name)
                XCTFail("\(name) was described")
            } catch {
                XCTAssertEqual(error as? MuterError, .literal(reason: MutationOperator.Id.description), name)
            }
        }
        XCTAssertEqual(printer.linesPassed, [])
        XCTAssertEqual(
            MutationOperator.Id.description,
            "RelationalOperatorReplacement, RelationalBoundary, RemoveSideEffects, ChangeLogicalConnector, "
                + "SwapTernary, "
                + "NegateConditional, ChangeArithmeticOperator, FlipBooleanLiteral, ReplaceBooleanValue, "
                + "ReplaceReturnValue"
        )
    }

    func test_theOperatorArgument_isRequired_andTheHelpNamesTheOperators() throws {
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["operator"]))
        XCTAssertTrue(try MuterCommand.parseAsRoot(["operator", "SwapTernary"]) is Operator)

        let help = Operator.helpMessage(columns: 400)
        XCTAssertTrue(help.contains(MutationOperator.Id.description), help)
        XCTAssertTrue(help.contains("For all operators use: all"), help)
        XCTAssertTrue(help.contains("Available operators are: "), help)
    }

    // The tables say what the operators change: each of their swaps, and no other.
    func test_theTables_listEachSwapTheOperatorsMake() throws {
        let source = SourceCodeInfo(path: "", code: Parser.parse(source: ""))
        let swaps: [(MutationOperator.Id, [String: String])] = [
            (.logicalOperator, ChangeLogicalConnectorOperator.Visitor(sourceCodeInfo: source).oppositeOperatorMapping),
            (.arithmeticOperator, ChangeArithmeticOperator.Visitor(sourceCodeInfo: source).oppositeOperatorMapping),
        ]

        for (id, mapping) in swaps {
            // `| == | != |`: a row of two operators. Not split on "|", which `||` is made of.
            let row = try NSRegularExpression(pattern: #"^\|\s+(\S+)\s+\|\s+(\S+)\s+\|$"#)
            let tableSwaps = id.documentation.raw.split(separator: "\n").map(String.init).compactMap { line in
                row.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)).map { match in
                    (1...2).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
                }
            }
            XCTAssertEqual(
                Set(tableSwaps.map { $0.joined(separator: " → ") }),
                Set(mapping.map { "\($0.key) → \($0.value)" }),
                id.rawValue
            )
        }
        // RelationalOperatorReplacement's rows give a swap, if any, and the constants: `==` and `!=` are swapped only
        // where a comparison gets no constant, which the text below the table says.
        let rorRow = try NSRegularExpression(pattern: #"^\|\s+(\S+)\s+\|\s*(\S*)\s*\|\s+(.+?)\s+\|$"#)
        let lines = MutationOperator.Id.ror.documentation.raw.split(separator: "\n").map(String.init)
        let rorRows = lines
            .compactMap { line in
                rorRow.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)).map { match in
                    (1...3).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
                }
            }
            .filter { ROROperator.comparisons.contains($0[0]) }
        let mapping = ROROperator.Visitor(sourceCodeInfo: source).oppositeOperatorMapping
        XCTAssertEqual(
            Set(rorRows.filter { !$0[1].isEmpty }.map { "\($0[0]) → \($0[1])" }),
            Set(mapping.filter { !["==", "!="].contains($0.key) }.map { "\($0.key) → \($0.value)" })
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: rorRows.map { ($0[0], $0[2]) }),
            Dictionary(uniqueKeysWithValues: ROROperator.comparisons.map { comparison in
                let constants = ROROperator.constants(for: comparison).map { $0 == .true ? "true" : "false" }
                return (comparison, constants.joined(separator: ", "))
            })
        )
        XCTAssertTrue(
            MutationOperator.Id.swapTernary.documentation.raw
                .contains("<condition> ? <expression1> : <expression2> | <condition> ? <expression2> : <expression1>"),
            MutationOperator.Id.swapTernary.documentation.raw
        )
    }

    // Every call the operator never removes is named, so a reader knows which statements stay.
    func test_removeSideEffects_namesEachCallItNeverRemoves() {
        let documentation = MutationOperator.Id.removeSideEffects.documentation.raw

        for call in RemoveSideEffectsOperator.Visitor.alwaysExcludedCalls {
            XCTAssertTrue(documentation.contains(" \(call),"), call)
        }
        XCTAssertTrue(documentation.contains("under the excludeCalls key."), documentation)
        XCTAssertTrue(documentation.contains("muter.conf.yml"), documentation)
    }

    // Each example's code before and after differs by the operator's change.
    func test_eachExample_showsTheOperatorsChange() {
        let swaps = [
            DocumentedSwap(
                id: .logicalOperator,
                before: "return meetsMinimumLength && passwordsMatch",
                after: "return meetsMinimumLength || passwordsMatch"
            ),
            DocumentedSwap(id: .ror, before: "if myValue == 50 {", after: "if true {"),
            DocumentedSwap(id: .ror, before: "return count < limit", after: "return count != limit"),
            DocumentedSwap(
                id: .swapTernary,
                before: #"return a ? "true" : "false""#,
                after: #"return a ? "false" : "true""#
            ),
        ]
        for swap in swaps {
            XCTAssertTrue(swap.id.documentation.raw.contains(swap.before), "\(swap.id.rawValue): \(swap.before)")
            XCTAssertTrue(swap.id.documentation.raw.contains(swap.after), "\(swap.id.rawValue): \(swap.after)")
        }

        // Each removed statement is in the code before only.
        let removal = MutationOperator.Id.removeSideEffects.documentation.raw
        for statement in ["_ = self.view", "database.persist(userRecord)"] {
            XCTAssertEqual(removal.components(separatedBy: statement).count - 1, 1, statement)
        }
        XCTAssertEqual(removal.components(separatedBy: "view.results = self.results").count - 1, 2)
        // Each example's heading says what it mutates.
        let headings = [
            "Mutating a Logical AND",
            "Mutating an explicitly discarded return result",
            "Mutating a void function call",
            "Mutating an equality check",
            "Mutating a ternary expression",
        ]
        let all = MutationOperator.Id.allCases.map(\.documentation.raw).joined()
        for heading in headings {
            XCTAssertTrue(all.contains(heading), heading)
        }
    }

    private func run(_ name: String) throws {
        var command = try XCTUnwrap(try MuterCommand.parseAsRoot(["operator", name]) as? Operator)
        try command.run()
    }
}
