import Foundation
import SwiftSyntax

typealias VisitorInitializer = (MuterConfiguration?, SourceCodeInfo, FileCoverage) -> MuterVisitor
typealias MutationOperatorList = [MutationOperator.Id]

extension [MutationOperator.Id] {
    static let allOperators = MutationOperator.Id.allCases

    /// Each operator once, where it first appears: an operator listed twice would test each of its mutants twice.
    var withoutRepeats: Self {
        var seen: Set<MutationOperator.Id> = []
        return filter { seen.insert($0).inserted }
    }
}

enum MutationOperator {
    // swiftlint:disable:next type_name - named in every operator and report as `MutationOperator.Id`
    enum Id: String, Codable, CaseIterable {
        case ror = "RelationalOperatorReplacement"
        case relationalBoundary = "RelationalBoundary"
        case removeSideEffects = "RemoveSideEffects"
        case logicalOperator = "ChangeLogicalConnector"
        case swapTernary = "SwapTernary"
        case negateConditional = "NegateConditional"
        case arithmeticOperator = "ChangeArithmeticOperator"
        case flipBooleanLiteral = "FlipBooleanLiteral"
        case replaceBooleanValue = "ReplaceBooleanValue"
        case replaceReturnValue = "ReplaceReturnValue"

        var visitor: VisitorInitializer {
            switch self {
            case .removeSideEffects:
                return RemoveSideEffectsOperator.Visitor.init
            case .ror:
                return ROROperator.Visitor.init
            case .relationalBoundary:
                return RelationalBoundaryOperator.Visitor.init
            case .logicalOperator:
                return ChangeLogicalConnectorOperator.Visitor.init
            case .swapTernary:
                return SwapTernaryOperator.Visitor.init
            case .negateConditional:
                return NegateConditionalOperator.Visitor.init
            case .arithmeticOperator:
                return ChangeArithmeticOperator.Visitor.init
            case .flipBooleanLiteral:
                return FlipBooleanLiteralOperator.Visitor.init
            case .replaceBooleanValue:
                return ReplaceBooleanValueOperator.Visitor.init
            case .replaceReturnValue:
                return ReplaceReturnValueOperator.Visitor.init
            }
        }

        static var description: String {
            allCases.map(\.rawValue).joined(separator: ", ")
        }

        /// Its name in words, as the HTML report and SARIF's rules show it.
        var friendlyName: String {
            switch self {
            case .ror: "Relational Operator Replacement"
            case .relationalBoundary: "Relational Boundary"
            case .removeSideEffects: "Remove Side Effects"
            case .logicalOperator: "Change Logical Connector"
            case .swapTernary: "Swap Ternary"
            case .negateConditional: "Negate Conditional"
            case .arithmeticOperator: "Change Arithmetic Operator"
            case .flipBooleanLiteral: "Flip Boolean Literal"
            case .replaceBooleanValue: "Replace Boolean Value"
            case .replaceReturnValue: "Replace Return Value"
            }
        }

        /// What it does, in a line, for the reports. In words alone, as the HTML report puts it in an attribute.
        var explanation: String {
            switch self {
            case .ror:
                return "Replaces a comparison with true or false, and turns less than and greater than into not equal, "
                    + "and at most and at least into equal."
            case .relationalBoundary:
                return "Moves a comparison's boundary: less than and at most swap, as do greater than and at least."
            case .removeSideEffects:
                return "Removes a call whose result isn't used, to check that a test notices its side effect is gone."
            case .logicalOperator:
                return "Swaps a logical AND for OR, and OR for AND."
            case .swapTernary:
                return "Swaps the two branches of a ternary expression."
            case .negateConditional:
                return "Negates a condition of an if, guard or while, which sends the code down the other branch."
            case .arithmeticOperator:
                return "Swaps arithmetic: plus and minus swap, as do times and divide, and remainder becomes times."
            case .flipBooleanLiteral:
                return "Turns the literal true into false, and false into true."
            case .replaceBooleanValue:
                return "Replaces a Bool that is returned or stored with true, and in a second mutant with false."
            case .replaceReturnValue:
                return "Replaces a returned value with an empty one of its type: nil, an empty array, dictionary or "
                    + "string, or zero."
            }
        }
    }

    struct Snapshot: Codable, Equatable {
        let before: String
        let after: String
        let description: String
    }
}

extension MutationOperator.Snapshot {
    static var null: MutationOperator.Snapshot {
        MutationOperator.Snapshot(
            before: "",
            after: "",
            description: ""
        )
    }
}

extension MutationOperator.Snapshot: CustomDebugStringConvertible {
    var debugDescription: String {
        """
        MutationOperator.Snapshot(
            before: "\(before)",
            after: "\(after)",
            description: "\(description)"
        )
        """
    }
}
