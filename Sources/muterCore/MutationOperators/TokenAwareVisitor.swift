import SwiftSyntax

class TokenAwareVisitor: MuterVisitor {
    var tokensToDiscover = [TokenKind]()
    var oppositeOperatorMapping: [String: String] = [:]

    override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        let `operator` = node.operator
        guard canMutateToken(`operator`),
              let oppositeOperator = oppositeOperator(for: `operator`.tokenKind)
        else {
            return .visitChildren
        }

        let position = startLocation(for: node)
        let snapshot = MutationOperator.Snapshot(
            before: node.description.trimmed,
            after: oppositeOperator,
            description: "changed \(node.description.trimmed) to \(oppositeOperator)"
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

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        node.isInsideCompilerDirective
            ? .skipChildren
            : .visitChildren
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

private extension SequenceExprSyntax {
    var isInsideCompilerDirective: Bool {
        parent?.is(IfConfigClauseSyntax.self) == true
    }
}
