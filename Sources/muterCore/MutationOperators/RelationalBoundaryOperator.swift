import SwiftSyntax

/// Moves an ordering comparison's boundary by one value: `<` becomes `<=`, and `>=` becomes `>`. Such a mutant survives
/// unless some test checks the edge value, which RelationalOperatorReplacement's `<` to `>` rarely shows, as almost any
/// test kills that. Equality operators have no boundary, so `==` and `!=` are left to RelationalOperatorReplacement.
enum RelationalBoundaryOperator {
    class Visitor: TokenAwareVisitor {
        convenience init(
            configuration: MuterConfiguration? = nil,
            sourceCodeInfo: SourceCodeInfo,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                configuration: configuration,
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .relationalBoundary,
                coverage: coverage
            )

            tokensToDiscover = [
                .binaryOperator("<"),
                .binaryOperator("<="),
                .binaryOperator(">"),
                .binaryOperator(">="),
            ]

            oppositeOperatorMapping = [
                "<": "<=",
                "<=": "<",
                ">": ">=",
                ">=": ">",
            ]
        }
    }
}
