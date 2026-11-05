import SwiftOperators
import SwiftSyntax

/// Wraps each expression condition of `if`, `guard` and `while` in `!( )`, which sends the code down the other branch,
/// so the mutant survives unless a test tells the two branches apart. `if let`, `case` and `#available` conditions
/// aren't expressions, and are left alone.
enum NegateConditionalOperator {
    final class Visitor: MuterVisitor {
        /// Whether to leave a condition that is one `==` or `!=` comparison alone, as RelationalOperatorReplacement's
        /// swap of it is the same mutant: `!(a == b)` is `a != b`. Set when that operator is on, but not for
        /// `--mutant`, which discovers every operator and must still find the mutant a run with this operator alone
        /// reported.
        var leavesEqualityChecksAlone = false

        convenience init(
            configuration: MuterConfiguration? = nil,
            sourceCodeInfo: SourceCodeInfo,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                configuration: configuration,
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .negateConditional,
                coverage: coverage
            )
        }

        override func visit(_ node: ConditionElementSyntax) -> SyntaxVisitorContinueKind {
            // First, as this reads a `muter:disable` comment beside the condition, which is meant for it.
            let next = super.visit(node)
            guard case let .expression(condition) = node.condition,
                  canNegate(condition)
            else {
                return next
            }

            let mutation = negated(condition)
            add(
                mutation: mutation,
                with: condition,
                at: startLocation(for: condition, afterLeadingTrivia: true),
                snapshot: MutationOperator.Snapshot(
                    before: condition.trimmedDescription.inlined,
                    after: mutation.trimmedDescription.inlined,
                    description: "negated the condition"
                )
            )

            return next
        }

        private func canNegate(_ condition: ExprSyntax) -> Bool {
            let core = condition.withoutWrapping
            // `while true` is an endless loop to the compiler, which lets a function end without a `return` after it.
            // Negated, the loop can end, and the function no longer compiles. Nor does a literal test anything.
            guard !core.is(BooleanLiteralExprSyntax.self) else { return false }
            // `#_hasSymbol` can only be a condition itself, though it parses as an expression.
            guard core.as(MacroExpansionExprSyntax.self)?.macroName.text != "_hasSymbol" else { return false }
            guard !leavesEqualityChecksAlone || !core.isEqualityCheck else { return false }
            // The `)` would follow `#endif` on its line, and nothing can.
            return condition.lastToken(viewMode: .sourceAccurate)?.tokenKind != .poundEndif
        }

        /// The condition in `!( )`, with the trivia on either side of it left outside: a `//` comment after the
        /// condition would otherwise swallow the `)`.
        private func negated(_ condition: ExprSyntax) -> ExprSyntax {
            // `if(a)` has nothing between the keyword and the condition, and `if!(a)` doesn't parse: touching on both
            // sides, the `!` reads as an infix operator.
            let isTouchingThePreviousToken = condition.leadingTrivia.isEmpty
                && condition.previousToken(viewMode: .sourceAccurate)?.trailingTrivia.isEmpty == true
            let negation = PrefixOperatorExprSyntax(
                operator: .prefixOperator(
                    "!",
                    leadingTrivia: isTouchingThePreviousToken ? .space : condition.leadingTrivia
                ),
                expression: TupleExprSyntax(
                    elements: LabeledExprListSyntax([LabeledExprSyntax(expression: condition.trimmed)]),
                    rightParen: .rightParenToken(trailingTrivia: condition.trailingTrivia)
                )
            )
            return ExprSyntax(negation)
        }
    }
}

private extension ExprSyntax {
    /// The expression inside any parentheses, `!`, `try` and `await` around it, none of which change what negating it
    /// amounts to.
    var withoutWrapping: ExprSyntax {
        var expression = self
        while true {
            if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
               let only = tuple.elements.first, only.label == nil {
                expression = only.expression
            } else if let prefix = expression.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
                expression = prefix.expression
            } else if let attempt = expression.as(TryExprSyntax.self) {
                expression = attempt.expression
            } else if let wait = expression.as(AwaitExprSyntax.self) {
                expression = wait.expression
            } else {
                return expression
            }
        }
    }

    /// Whether the last thing this works out is one `==` or `!=`, as in `a % 2 == 0`, whose negation is the swap of it.
    /// `a == b && c` isn't, as `&&` is, and nor are `===` and `!==`, as no operator swaps them. The tree isn't folded,
    /// so that takes the operators' precedence. An operator the standard table doesn't hold can't be told apart, and
    /// the condition is negated: at worst a mutant is tested twice.
    var isEqualityCheck: Bool {
        guard let sequence = self.as(SequenceExprSyntax.self),
              let folded = try? OperatorTable.standardOperators.foldSingle(sequence),
              let comparison = folded.withoutWrapping.as(InfixOperatorExprSyntax.self),
              let name = comparison.operator.as(BinaryOperatorExprSyntax.self)?.operator.text
        else { return false }
        return ["==", "!="].contains(name)
    }
}
