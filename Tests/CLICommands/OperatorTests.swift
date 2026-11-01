@testable import muterCore
import Rainbow
import SwiftParser
import XCTest

/// `swift-mutator operator`, which describes a mutation operator, or all of them. The descriptions are read without
/// their colour codes (`raw`), so the tests see the words a terminal shows.
final class OperatorTests: MuterTestCase {
    func test_eachOperator_isDescribedByItsName() async throws {
        let titles: [MutationOperator.Id: String] = [
            .ror: "Relational Operator Replacement",
            .removeSideEffects: "Remove Side Effects",
            .logicalOperator: "Change Logical Connector",
            .swapTernary: "Swap Ternary",
        ]

        for id in MutationOperator.Id.allCases {
            let printedBefore = printer.linesPassed.count
            try await run(id.rawValue)

            let printed = Array(printer.linesPassed.dropFirst(printedBefore))
            XCTAssertEqual(printed, [id.documentation], id.rawValue)
            XCTAssertTrue(printed.first?.raw.contains(try XCTUnwrap(titles[id])) == true, id.rawValue)
        }
    }

    // In the order the operators are listed everywhere else, a blank line between each, and with spaces around "all".
    func test_all_describesEveryOperator_inOrder() async throws {
        try await run("all")
        try await run(" all ")

        let expected = MutationOperator.Id.allCases.map(\.documentation).joined(separator: "\n\n")
        XCTAssertEqual(printer.linesPassed, [expected, expected])
    }

    // An operator is named as the configuration and --operators name it, in full and in its case.
    func test_anUnknownOperator_isRefused_namingTheOperators() async throws {
        for name in ["ror", "relationaloperatorreplacement", "", "Everything"] {
            do {
                try await run(name)
                XCTFail("\(name) was described")
            } catch {
                XCTAssertEqual(error as? MuterError, .literal(reason: MutationOperator.Id.description), name)
            }
        }
        XCTAssertEqual(printer.linesPassed, [])
        XCTAssertEqual(
            MutationOperator.Id.description,
            "RelationalOperatorReplacement, RemoveSideEffects, ChangeLogicalConnector, SwapTernary"
        )
    }

    func test_theOperatorArgument_isRequired_andTheHelpNamesTheOperators() throws {
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["operator"]))
        XCTAssertTrue(try MuterCommand.parseAsRoot(["operator", "SwapTernary"]) is Operator)

        let help = Operator.helpMessage(columns: 200)
        XCTAssertTrue(help.contains(MutationOperator.Id.description), help)
        XCTAssertTrue(help.contains("For all operators use: all"), help)
    }

    // The tables say what the operators change: each of their swaps, and no other.
    func test_theTables_listEachSwapTheOperatorsMake() throws {
        let source = SourceCodeInfo(path: "", code: Parser.parse(source: ""))
        let swaps: [(MutationOperator.Id, [String: String])] = [
            (.ror, ROROperator.Visitor(sourceCodeInfo: source).oppositeOperatorMapping),
            (.logicalOperator, ChangeLogicalConnectorOperator.Visitor(sourceCodeInfo: source).oppositeOperatorMapping),
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
        let swaps: [(MutationOperator.Id, before: String, after: String)] = [
            (.logicalOperator, "return meetsMinimumLength && passwordsMatch", "return meetsMinimumLength || passwordsMatch"),
            (.ror, "if myValue == 50 {", "if myValue != 50 {"),
            (.swapTernary, #"return a ? "true" : "false""#, #"return a ? "false" : "true""#),
        ]
        for (id, before, after) in swaps {
            XCTAssertTrue(id.documentation.raw.contains(before), "\(id.rawValue): \(before)")
            XCTAssertTrue(id.documentation.raw.contains(after), "\(id.rawValue): \(after)")
        }

        // Each removed statement is in the code before only.
        let removal = MutationOperator.Id.removeSideEffects.documentation.raw
        for statement in ["_ = self.view", "database.persist(userRecord)"] {
            XCTAssertEqual(removal.components(separatedBy: statement).count - 1, 1, statement)
        }
        XCTAssertEqual(removal.components(separatedBy: "view.results = self.results").count - 1, 2)
    }
}

private extension OperatorTests {
    func run(_ name: String) async throws {
        var command = try XCTUnwrap(try MuterCommand.parseAsRoot(["operator", name]) as? Operator)
        try await command.run()
    }
}
