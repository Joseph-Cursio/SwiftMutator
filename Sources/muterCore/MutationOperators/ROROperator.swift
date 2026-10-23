import SwiftSyntax

enum ROROperator {
    class Visitor: TokenAwareVisitor {
        convenience init(
            configuration: MuterConfiguration? = nil,
            sourceCodeInfo: SourceCodeInfo,
            coverage: FileCoverage = .none
        ) {
            self.init(
                configuration: configuration,
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .ror,
                coverage: coverage
            )

            tokensToDiscover = [
                .binaryOperator("=="),
                .binaryOperator("!="),
                .binaryOperator(">="),
                .binaryOperator("<="),
                .binaryOperator("<"),
                .binaryOperator(">"),
            ]

            oppositeOperatorMapping = [
                "==": "!=",
                "!=": "==",
                ">=": "<=",
                "<=": ">=",
                ">": "<",
                "<": ">",
            ]
        }
    }
}
