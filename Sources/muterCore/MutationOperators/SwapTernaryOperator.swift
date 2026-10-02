import SwiftSyntax

enum SwapTernaryOperator {
    final class Visitor: MuterVisitor {
        convenience init(
            configuration: MuterConfiguration? = nil,
            sourceCodeInfo: SourceCodeInfo,
            regionsWithoutCoverage: [Region] = []
        ) {
            self.init(
                configuration: configuration,
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .swapTernary,
                regionsWithoutCoverage: regionsWithoutCoverage
            )
        }

        override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
            guard !node.containsComplexCauses else {
                return super.visit(node)
            }

            let mutatedSyntax = mutated(node)
            // A swap that could not be made returns the node unchanged. Registering it would run
            // the original code as a "mutant" and report it as survived.
            guard mutatedSyntax.description != node.description else {
                return super.visit(node)
            }
            let position = endLocation(for: node)
            let snapshot = MutationOperator.Snapshot(
                before: node.description.trimmed.inlined,
                after: mutatedSyntax.description.trimmed.inlined,
                description: "swapped ternary operator"
            )

            add(
                mutation: mutatedSyntax,
                with: node,
                at: position,
                snapshot: snapshot
            )

            return super.visit(node)
        }

        override func visit(_ node: ExprListSyntax) -> SyntaxVisitorContinueKind {
            guard containsTernayExpression(node) else {
                return super.visit(node)
            }

            guard !containsComplexExpressions(cast(node)) else {
                return super.visit(node)
            }

            let mutatedSyntax = mutated(node)
            // A swap that could not be made returns the node unchanged. Registering it would run
            // the original code as a "mutant" and report it as survived.
            guard mutatedSyntax.description != node.description else {
                return super.visit(node)
            }
            let position = endLocation(for: node)
            let snapshot = MutationOperator.Snapshot(
                before: node.description.trimmed.inlined,
                after: mutatedSyntax.description.trimmed.inlined,
                description: "swapped ternary operator"
            )

            add(
                mutation: mutatedSyntax,
                with: node,
                at: position,
                snapshot: snapshot
            )

            return super.visit(node)
        }

        private func mutated(_ node: TernaryExprSyntax) -> ExprSyntax {
            ExprSyntax(
                TernaryExprSyntax(
                    leadingTrivia: node.leadingTrivia,
                    condition: node.condition,
                    questionMark: node.questionMark,
                    thenExpression: node.elseExpression,
                    colon: node.colon,
                    elseExpression: node.thenExpression,
                    trailingTrivia: node.trailingTrivia
                )
            )
        }

        private func mutated(_ node: ExprListSyntax) -> ExprListSyntax {
            var children = cast(node)
            guard children.contains(where: { $0.is(UnresolvedTernaryExprSyntax.self) }),
                  let index = ternaryIndex(node),
                  let ternary = children[index].as(UnresolvedTernaryExprSyntax.self)
            else {
                return node
            }

            // In an unresolved sequence the else-expression is every child after the ternary:
            // `… ? a : c < d` flattens `c < d` into three siblings. Swapping only the first of them
            // left `< d` dangling (`x < y < d`, which does not compile, #308), so the whole tail moves.
            // An assignment binds more loosely than `?:`, so a tail containing one is not the
            // else-expression alone; that rare shape is left unmutated.
            let elseTerms = Array(children[(index + 1)...])
            guard !elseTerms.isEmpty, !elseTerms.contains(where: isAssignment) else {
                return node
            }

            let elseExpression = elseTerms.count == 1
                ? elseTerms[0]
                : ExprSyntax(SequenceExprSyntax(elements: ExprListSyntax(elseTerms)))
            let secondChoice = elseExpression
                .withTrailingTrivia(.spaces(1))
                .withLeadingTrivia(.spaces(1))
            let firstChoice = ternary.thenExpression
                .withTrailingTrivia(.spaces(1))
                .withLeadingTrivia(.spaces(1))

            children.replaceSubrange(index..., with: [
                ExprSyntax(
                    UnresolvedTernaryExprSyntax(thenExpression: secondChoice)
                        .withTrailingTrivia(.spaces(1))
                        .withLeadingTrivia(.spaces(1))
                ),
                firstChoice,
            ])

            return ExprListSyntax(children)
        }

        /// `=` and the compound assignments (`+=`, `??=`, …), but not the comparisons that also end in `=`.
        private func isAssignment(_ expression: ExprSyntax) -> Bool {
            if expression.is(AssignmentExprSyntax.self) {
                return true
            }
            guard let binary = expression.as(BinaryOperatorExprSyntax.self) else {
                return false
            }
            let text = binary.operator.text
            return text.hasSuffix("=") && !["==", "!=", "<=", ">=", "===", "!=="].contains(text)
        }

        private func ternaryIndex(_ node: ExprListSyntax) -> Int? {
            for (index, child) in node.allChildren.enumerated() {
                if child.is(UnresolvedTernaryExprSyntax.self) {
                    return index
                }
            }

            return nil
        }

        private func cast(_ node: ExprListSyntax) -> [ExprSyntax] {
            node.allChildren.compactMap {
                $0.as(ExprSyntax.self)
            }
        }

        private func containsComplexExpressions(_ nodes: [ExprSyntax]) -> Bool {
            nodes.contains(where: { $0.is(AsExprSyntax.self) })
                || nodes.contains(where: { $0.is(UnresolvedAsExprSyntax.self) })
        }

        private func containsTernayExpression(_ node: ExprListSyntax) -> Bool {
            node
                .allChildren
                .containsSyntaxKind(UnresolvedTernaryExprSyntax.self)
        }
    }
}

private extension TernaryExprSyntax {
    var containsComplexCauses: Bool {
        thenExpression.allChildren.containsSyntaxKind(AsExprSyntax.self)
            || elseExpression.allChildren.containsSyntaxKind(AsExprSyntax.self)
    }
}
