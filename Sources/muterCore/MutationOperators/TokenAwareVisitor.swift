import SwiftSyntax

class TokenAwareVisitor: MuterVisitor {
    var tokensToDiscover = [TokenKind]()
    var oppositeOperatorMapping: [String: String] = [:]

    override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        let `operator` = node.operator
        guard canMutateToken(`operator`),
              canMutate(node),
              let oppositeOperator = oppositeOperator(for: `operator`.tokenKind)
        else {
            return .visitChildren
        }

        // The older operators keep the place their recorded results name, before any line break and comment.
        let position = startLocation(for: node, afterLeadingTrivia: mutationOperatorId == .arithmeticOperator)
        // The token's text, as a comment beside the operator would read as part of the change. The older operators keep
        // the node's, comment and all, which is what triage labels and recorded results compare with.
        let before = mutationOperatorId == .arithmeticOperator ? `operator`.text : node.description.trimmed
        let snapshot = MutationOperator.Snapshot(
            before: before,
            after: oppositeOperator,
            description: "changed \(before) to \(oppositeOperator)"
        )

        add(
            mutation: mutated(
                `operator`,
                using: oppositeOperator
            ),
            with: node,
            at: position,
            snapshot: snapshot,
            // The node is the operator alone, as the tree isn't folded: an operand on another line is the expression's,
            // and a change to it is a change to what the operator compares or joins.
            spanning: node.parent?.parent?.as(SequenceExprSyntax.self)
        )

        return super.visit(node)
    }

    /// Whether an operator can change this one, whose token it does change.
    func canMutate(_: BinaryOperatorExprSyntax) -> Bool {
        true
    }

    private func oppositeOperator(for tokenKind: TokenKind) -> String? {
        guard case let .binaryOperator(`operator`) = tokenKind else {
            return nil
        }

        return oppositeOperatorMapping[`operator`]
    }

    private func canMutateToken(_ token: TokenSyntax) -> Bool {
        tokensToDiscover.contains(token.tokenKind) &&
            token.parent?.is(BinaryOperatorExprSyntax.self) == true
    }

    private func mutated(
        _ token: TokenSyntax,
        using operator: String
    ) -> Syntax {
        let tokenSyntax = TokenSyntax(
            .binaryOperator(`operator`),
            leadingTrivia: token.leadingTrivia,
            trailingTrivia: token.trailingTrivia,
            presence: .present
        )

        return Syntax(tokenSyntax)
    }
}
