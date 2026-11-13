import SwiftSyntax

enum ChangeLogicalConnectorOperator {
    class Visitor: TokenAwareVisitor {
        convenience init(
            sourceCodeInfo: SourceCodeInfo,
            configuration: MuterConfiguration? = nil,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .logicalOperator,
                coverage: coverage,
                configuration: configuration
            )

            tokensToDiscover = [
                .binaryOperator("||"),
                .binaryOperator("&&"),
            ]

            oppositeOperatorMapping = [
                "||": "&&",
                "&&": "||",
            ]
        }
    }
}
