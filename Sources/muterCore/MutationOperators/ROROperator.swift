import SwiftOperators
import SwiftSyntax

/// RelationalOperatorReplacement's mutants of one comparison, by where each is placed.
struct ComparisonMutants {
    /// The comparison, when it gets a constant.
    let comparison: Comparison?
    /// Its constants, in the order of their places.
    let constants: [(keyword: Keyword, position: MutationPosition)]
    /// Where its operator's swap is, when it gets one.
    let swap: MutationPosition?

    var places: [MutationPosition] {
        constants.map(\.position) + (swap.map { [$0] } ?? [])
    }
}

/// Gives each comparison the mutants of Kaminski, Ammann and Offutt's sufficient set ("Better predicate testing",
/// 2011): any tests that kill these few, with RelationalBoundary's, kill every other mutant of an ordering
/// comparison's operator. An ordering comparison gets its operator swapped, `<` and `>` for `!=`, `<=` and `>=` for
/// `==`, and is replaced whole with the constant it gives when its operands are apart: `false` for `<` and `>`, `true`
/// for `<=` and `>=`. RelationalBoundary gives the third, `<` to `<=`. An equality check, `==` or `!=`, is replaced
/// with `true`, and in a second mutant with `false`: the paper's `<=` and `>=` for `==` don't compile on a type that
/// is only `Equatable`, and the tree has no types.
///
/// A constant replaces the comparison as the standard operator table folds its sequence, so `a + 1 < b` becomes
/// `false`, and `x < y && z` becomes `false && z`. A comparison that gets no constant gets its operator swapped,
/// `==` to `!=` too: one in a sequence the standard table can't fold, as an operator of the project's own precedence
/// is in it; one whose value is thrown away, as a statement of its own, which is an overload with side effects, as
/// Nimble's `expect(x) == 1`, where a literal would be an unused value that tests nothing; and one that holds a
/// closure's only use of its highest `$` argument, as `{ $0 > 1 }`, which as `{ false }` would take no argument. Nor
/// does a comparison that decides a `while` or `repeat`-`while` get the constant that would keep the loop going until
/// the time limit, as `while a <= b` would `true`.
enum ROROperator {
    final class Visitor: TokenAwareVisitor {
        /// Whether the comparison of the operator being visited gets its operator swapped, as `canMutate` answers.
        private var swapsTheOperator = false

        convenience init(
            sourceCodeInfo: SourceCodeInfo,
            configuration: MuterConfiguration? = nil,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .ror,
                coverage: coverage,
                configuration: configuration
            )

            tokensToDiscover = ROROperator.comparisons.map { .binaryOperator($0) }

            // `==` and `!=` are swapped only where they get no constant.
            oppositeOperatorMapping = [
                "<": "!=",
                ">": "!=",
                "<=": "==",
                ">=": "==",
                "==": "!=",
                "!=": "==",
            ]
        }

        override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            swapsTheOperator = false
            guard ROROperator.comparisons.contains(node.operator.text) else { return super.visit(node) }

            let mutants = mutants(ofTheComparisonWith: node)
            // The mutants are one comparison's: a directive that leaves out where any of them is placed leaves out all.
            guard !mutants.places.contains(where: { isLeftOutByADirective($0, in: node.root) }) else {
                return super.visit(node)
            }

            swapsTheOperator = mutants.swap != nil
            if let comparison = mutants.comparison {
                for (keyword, position) in mutants.constants {
                    let after = keyword == .true ? "true" : "false"
                    add(
                        mutation: comparison.replaced(with: keyword),
                        with: comparison.sequence,
                        at: position,
                        snapshot: MutationOperator.Snapshot(
                            before: comparison.before,
                            after: after,
                            description: "replaced the comparison with \(after)"
                        ),
                        // As the swap is: coverage, the directives and an inactive `#if` go by the operator, and
                        // `--changed-lines` by the whole sequence.
                        changing: node,
                        spanning: comparison.sequence
                    )
                }
            }
            return super.visit(node)
        }

        override func canMutate(_: BinaryOperatorExprSyntax) -> Bool {
            swapsTheOperator
        }
    }

    /// The comparison operators this operator mutates. `===` and `!==` aren't among them, as nothing swaps an
    /// identity check for another.
    static let comparisons: Set<String> = ["==", "!=", "<", "<=", ">", ">="]

    /// The constants that replace a comparison of `comparison`: the one it gives when its operands are apart for an
    /// ordering operator, and both for an equality operator, the one it gives when they're equal first.
    static func constants(for comparison: String) -> [Keyword] {
        switch comparison {
        case "<", ">": [.false]
        case "<=", ">=": [.true]
        case "==": [.true, .false]
        default: [.false, .true]
        }
    }

    /// The operator of the comparison this operator replaces `expression` with a constant for, or nil: the last thing
    /// `expression` works out, inside any parentheses, `try` and `await`, is one of its comparisons, and that
    /// comparison gets a constant, as one whose value is used and that the standard table folds does. In a loop's
    /// condition, where it leaves out the constant that would keep the loop going, the swap or the other constant
    /// stands for it. NegateConditional and ReplaceBooleanValue leave such an expression to it.
    static func comparisonGivenAConstant(in expression: ExprSyntax) -> BinaryOperatorExprSyntax? {
        var expression = expression
        while true {
            if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
               let only = tuple.elements.first, only.label == nil {
                expression = only.expression
            } else if let attempt = expression.as(TryExprSyntax.self), attempt.questionOrExclamationMark?.text != "?" {
                expression = attempt.expression
            } else if let wait = expression.as(AwaitExprSyntax.self) {
                expression = wait.expression
            } else {
                break
            }
        }
        guard let sequence = expression.as(SequenceExprSyntax.self),
              let folded = try? OperatorTable.standardOperators.foldSingle(sequence)
        else { return nil }
        var outermost = folded
        while outermost.isAnEffectMarker, let inner = outermost.children(viewMode: .sourceAccurate).last {
            guard let innerExpression = inner.as(ExprSyntax.self) else { return nil }
            outermost = innerExpression
        }
        guard let comparison = outermost.as(InfixOperatorExprSyntax.self)?.operator.as(BinaryOperatorExprSyntax.self),
              comparisons.contains(comparison.operator.text),
              let token = Comparison.token(
                  at: comparison.operator.positionAfterSkippingLeadingTrivia,
                  from: folded,
                  in: sequence
              ),
              let node = token.parent?.as(BinaryOperatorExprSyntax.self),
              Comparison(withOperator: node) != nil
        else { return nil }
        return node
    }
}

extension MuterVisitor {
    /// Where RelationalOperatorReplacement places its mutants of the comparison whose operator is `node`, which a
    /// directive leaves out together.
    func placesOfTheMutants(ofTheComparisonWith node: BinaryOperatorExprSyntax) -> [MutationPosition] {
        mutants(ofTheComparisonWith: node).places
    }

    func mutants(ofTheComparisonWith node: BinaryOperatorExprSyntax) -> ComparisonMutants {
        let name = node.operator.text
        let comparison = Comparison(withOperator: node)
        // `true` where the comparison starts, and `false` where it ends, so that each mutant has a place, and so a
        // switch, of its own: two mutants of one operator at one place share a switch, and can't be told apart.
        let constants: [(keyword: Keyword, position: MutationPosition)] = comparison.map { comparison in
            ROROperator.constants(for: name)
                .filter { $0 != comparison.endlessLoopConstant }
                .map { keyword in
                    keyword == .true
                        ? (keyword, startLocation(for: comparison.first, afterLeadingTrivia: true))
                        : (keyword, endLocation(for: comparison.last, afterTrailingTrivia: false))
                }
                .sorted { $0.position.utf8Offset < $1.position.utf8Offset }
        } ?? []
        let swaps = !["==", "!="].contains(name) || constants.isEmpty
        return ComparisonMutants(
            comparison: comparison,
            constants: constants,
            swap: swaps ? startLocation(for: node) : nil
        )
    }
}
