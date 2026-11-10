import SwiftSyntax

enum SwapTernaryOperator {
    final class Visitor: MuterVisitor {
        convenience init(
            sourceCodeInfo: SourceCodeInfo,
            configuration: MuterConfiguration? = nil,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .swapTernary,
                coverage: coverage,
                configuration: configuration
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

        /// One mutant for each `?:` of a list, so each link of `a ? b : c ? d : e` gets its own. The first link's swap
        /// moves the rest of the chain, and only the link's own swap shows whether `c ? d : e` is tested.
        override func visit(_ node: UnresolvedTernaryExprSyntax) -> SyntaxVisitorContinueKind {
            // First, as this reads a `muter:disable` comment that comes before this link.
            let next = super.visit(node)
            guard let list = node.parent?.as(ExprListSyntax.self) else {
                return next
            }
            let terms = cast(list)
            guard !containsComplexExpressions(terms),
                  let index = terms.firstIndex(where: { $0.id == node.id }),
                  let swappedTerms = swapped(terms, at: index)
            else {
                return next
            }

            let earlierTerms = terms[..<index]
            let isLaterLink = earlierTerms.contains { $0.is(UnresolvedTernaryExprSyntax.self) }
            // A later link starts after the `?:` or the assignment before it. The first link is the whole list.
            let linkStart = earlierTerms.lastIndex(where: endsAnEarlierLink).map { $0 + 1 } ?? 0
            let start = isLaterLink ? linkStart : 0
            let snapshot = MutationOperator.Snapshot(
                before: text(of: terms[start...]),
                after: text(of: swappedTerms[start...]),
                description: "swapped ternary operator"
            )

            add(
                mutation: ExprListSyntax(swappedTerms),
                with: list,
                // The list's end is the first link's, so a list keeps the mutant it always had. A later link is placed
                // at its `?`, which is on the link's own line.
                at: isLaterLink ? startLocation(for: node, afterLeadingTrivia: true) : endLocation(for: list),
                snapshot: snapshot,
                // A later link is in the branch of the links before it, which the tests may never have run.
                changing: isLaterLink ? node : nil,
                spanning: list
            )

            return next
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

        /// `terms` with the branches of the ternary at `index` swapped. `nil` if there's no telling them apart, or no
        /// swapping them.
        private func swapped(_ terms: [ExprSyntax], at index: Int) -> [ExprSyntax]? {
            var children = terms
            guard let ternary = terms[index].as(UnresolvedTernaryExprSyntax.self) else {
                return nil
            }

            // In an unresolved sequence the else-expression is every child after the ternary:
            // `… ? a : c < d` flattens `c < d` into three siblings. Swapping only the first of them
            // left `< d` dangling (`x < y < d`, which does not compile, #308), so the whole tail moves.
            // An assignment binds more loosely than `?:`, so a tail containing one is not the
            // else-expression alone; that rare shape is left unmutated.
            let elseTerms = Array(terms[(index + 1)...])
            guard !elseTerms.isEmpty, !elseTerms.contains(where: isAssignment) else {
                return nil
            }

            // `c ? x : x` is the same code swapped, so no test could tell the mutant apart. Compared by token, as the
            // spacing of the two branches is no difference.
            guard codeTokens(of: [ternary.thenExpression]) != codeTokens(of: elseTerms) else {
                return nil
            }

            let elseExpression = elseTerms.count == 1
                ? elseTerms[0]
                : ExprSyntax(SequenceExprSyntax(elements: ExprListSyntax(elseTerms)))
            let secondChoice = elseExpression
                .withTrailingTrivia(lineBreakAfterEndif(of: elseExpression) ?? .spaces(1))
                .withLeadingTrivia(.spaces(1))
            // The trivia on either side of the swap is kept as it was. A `//` comment that ends the
            // condition needs the line break before the `?`, and a comment after the last term can
            // be all that separates this statement from the next. A last term with no trailing
            // trivia touched the next token, as in `(a < b)else`; the then-expression could join it
            // (`delse`), so it gets a space. After a `#endif` the kept trivia, only spaces and
            // comments, is followed by a line break.
            let lastTermTrivia = elseTerms[elseTerms.count - 1].trailingTrivia
            let firstChoice = parenthesizedIfItCantEndTheList(ternary.thenExpression)
                .withTrailingTrivia(
                    lineBreakAfterEndif(of: ternary.thenExpression).map { lastTermTrivia + $0 }
                        ?? (lastTermTrivia.isEmpty ? .spaces(1) : lastTermTrivia)
                )
                .withLeadingTrivia(.spaces(1))

            children.replaceSubrange(index..., with: [
                ExprSyntax(
                    UnresolvedTernaryExprSyntax(thenExpression: secondChoice)
                        .withTrailingTrivia(.spaces(1))
                        .withLeadingTrivia(ternary.leadingTrivia)
                ),
                firstChoice,
            ])

            return children
        }

        /// By their bytes, as to `String`'s `==` the two spellings of `é` are one, and to the compiler they aren't.
        private func codeTokens(of expressions: [ExprSyntax]) -> [[UInt8]] {
            expressions.flatMap { $0.tokens(viewMode: .sourceAccurate).map { Array($0.text.utf8) } }
        }

        private func text(of terms: ArraySlice<ExprSyntax>) -> String {
            ExprListSyntax(Array(terms)).description.trimmed.inlined
        }

        private func endsAnEarlierLink(_ term: ExprSyntax) -> Bool {
            term.is(UnresolvedTernaryExprSyntax.self) || isAssignment(term)
        }

        /// The then-expression in parentheses if it can't end the list, which the swap makes it do. At the end of a
        /// `guard` condition a `{` followed by `else` opens the guard's body. And an assignment binds more loosely than
        /// `?:`, so it would assign to the whole ternary.
        private func parenthesizedIfItCantEndTheList(_ expression: ExprSyntax) -> ExprSyntax {
            let endsInAClosure = expression.lastToken(viewMode: .sourceAccurate)?.tokenKind == .rightBrace
            let isAnAssignment = expression.as(SequenceExprSyntax.self)?.elements.contains(where: isAssignment) == true
            guard endsInAClosure || isAnAssignment else {
                return expression
            }
            return ExprSyntax(TupleExprSyntax(elements: [LabeledExprSyntax(expression: expression.withoutTrivia())]))
        }

        /// A line break indented like the `#endif` that ends `expression`, if one does. Only a comment may
        /// follow a `#endif` on its line, so whatever the swap puts after the expression has to start a new one.
        private func lineBreakAfterEndif(of expression: ExprSyntax) -> Trivia? {
            guard let endif = expression.lastToken(viewMode: .sourceAccurate), endif.tokenKind == .poundEndif else {
                return nil
            }
            let indentation = endif.leadingTrivia.pieces.reversed().prefix { piece in
                switch piece {
                case .spaces, .tabs: true
                default: false
                }
            }
            return Trivia(pieces: [.newlines(1)] + indentation.reversed())
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
            let comparisons = ["==", "!=", "<=", ">=", "===", "!==", "~=", ".==", ".!=", ".<=", ".>="]
            return text.hasSuffix("=") && !comparisons.contains(text)
        }

        private func cast(_ node: ExprListSyntax) -> [ExprSyntax] {
            node.allChildren.compactMap {
                $0.as(ExprSyntax.self)
            }
        }

        private func containsComplexExpressions(_ nodes: [ExprSyntax]) -> Bool {
            nodes.contains { $0.is(AsExprSyntax.self) }
                || nodes.contains { $0.is(UnresolvedAsExprSyntax.self) }
        }
    }
}

private extension TernaryExprSyntax {
    var containsComplexCauses: Bool {
        thenExpression.allChildren.containsSyntaxKind(AsExprSyntax.self)
            || elseExpression.allChildren.containsSyntaxKind(AsExprSyntax.self)
    }
}
