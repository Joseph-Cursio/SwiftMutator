import SwiftSyntax

/// Moves an ordering comparison's boundary by one value: `<` becomes `<=`, and `>=` becomes `>`. Such a mutant survives
/// unless some test checks the edge value, which RelationalOperatorReplacement's `<` to `>` rarely shows, as almost any
/// test kills that. Equality operators have no boundary, so `==` and `!=` are left to RelationalOperatorReplacement.
enum RelationalBoundaryOperator {
    class Visitor: TokenAwareVisitor {
        convenience init(
            sourceCodeInfo: SourceCodeInfo,
            configuration: MuterConfiguration? = nil,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .relationalBoundary,
                coverage: coverage,
                configuration: configuration
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
