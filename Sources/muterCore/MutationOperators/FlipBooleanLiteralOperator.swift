import SwiftSyntax

/// Turns `true` into `false` and `false` into `true`, so the mutant survives unless a test notices the value.
enum FlipBooleanLiteralOperator {
    final class Visitor: MuterVisitor {
        convenience init(
            sourceCodeInfo: SourceCodeInfo,
            configuration: MuterConfiguration? = nil,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .flipBooleanLiteral,
                coverage: coverage,
                configuration: configuration
            )
        }

        override func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
            // First, as this reads a `muter:disable` comment beside the literal, which is meant for it.
            let next = super.visit(node)
            // Told to skip its children, this is a `#if`'s whole condition, which no operator mutates.
            guard next == .visitChildren, !node.isAWholeCondition, !node.isInAPattern else { return next }

            let before = node.literal
            let after = before.tokenKind == .keyword(.true) ? "false" : "true"
            let mutation = node.with(\.literal, TokenSyntax(
                .keyword(after == "true" ? .true : .false),
                leadingTrivia: before.leadingTrivia,
                trailingTrivia: before.trailingTrivia,
                presence: .present
            ))
            add(
                mutation: mutation,
                with: node,
                at: startLocation(for: node, afterLeadingTrivia: true),
                snapshot: MutationOperator.Snapshot(
                    before: before.text,
                    after: after,
                    description: "changed \(before.text) to \(after)"
                )
            )
            return next
        }
    }
}

private extension BooleanLiteralExprSyntax {
    /// `while true` is an endless loop to the compiler, and `if true` a branch it always takes, which lets the code
    /// after them go without a `return` or a value it needs. Flipped, neither compiles. Nor does either test anything.
    var isAWholeCondition: Bool {
        var parent = parent
        while let tuple = parent?.as(LabeledExprSyntax.self)?.parent?.parent?.as(TupleExprSyntax.self),
              tuple.elements.count == 1 {
            parent = tuple.parent
        }
        return parent?.is(ConditionElementSyntax.self) == true || parent?.is(RepeatStmtSyntax.self) == true
    }

    /// Flipping `case true:` leaves two `case false:` and a `switch` that isn't exhaustive, and so does
    /// `case (true, _):` or `case .on(true):`.
    var isInAPattern: Bool {
        var ancestor = parent
        while let current = ancestor, !current.is(ClosureExprSyntax.self), !current.is(CodeBlockSyntax.self) {
            if current.is(ExpressionPatternSyntax.self) {
                return true
            }
            ancestor = current.parent
        }
        return false
    }
}
