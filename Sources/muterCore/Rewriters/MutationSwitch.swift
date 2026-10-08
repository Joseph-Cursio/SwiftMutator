import Foundation
import SwiftSyntax

enum MutationSwitch {
    static func apply(
        mutationSchemata: MutationSchemata,
        with originalSyntax: CodeBlockItemListSyntax
    ) -> CodeBlockItemListSyntax {
        guard !mutationSchemata.isEmpty else {
            return originalSyntax
        }

        var schemata = mutationSchemata
        let firstSchema = schemata.removeFirst()

        var previousElseBody = IfExprSyntax.ElseBody(
            CodeBlockSyntax(
                statements: originalSyntax,
                rightBrace: closingBrace(of: originalSyntax, indentedLike: originalSyntax)
            )
        )

        for schema in schemata {
            let elseBody = IfExprSyntax.ElseBody(
                IfExprSyntax(
                    ifKeyword: .keyword(.if)
                        .withTrailingTrivia(.spaces(1))
                        .withLeadingTrivia(previousElseBody.leadingTrivia),
                    conditions: buildSchemataCondition(
                        withId: schema.id
                    ),
                    body: CodeBlockSyntax(
                        statements: schema.syntaxMutation,
                        rightBrace: closingBrace(of: schema.syntaxMutation, indentedLike: schema.syntaxMutation)
                    ),
                    elseKeyword: .keyword(.else)
                        .withTrailingTrivia(.spaces(1))
                        .withLeadingTrivia(.spaces(1)),
                    elseBody: previousElseBody
                )
            )

            previousElseBody = elseBody
        }

        let outterIfStatement = IfExprSyntax(
            ifKeyword: .keyword(.if)
                .withTrailingTrivia(.spaces(1))
                .withLeadingTrivia(originalSyntax.leadingTrivia),
            conditions: buildSchemataCondition(
                withId: firstSchema.id
            ),
            body: CodeBlockSyntax(
                statements: firstSchema.syntaxMutation,
                rightBrace: closingBrace(of: firstSchema.syntaxMutation, indentedLike: originalSyntax)
            ),
            elseKeyword: .keyword(.else)
                .withTrailingTrivia(.spaces(1))
                .withLeadingTrivia(.spaces(1)),
            elseBody: previousElseBody
        )

        return CodeBlockItemListSyntax([
            CodeBlockItemSyntax(item: .init(outterIfStatement))
        ])
    }

    /// The `}` that closes a branch holding `statements`, with the leading trivia of `original`.
    ///
    /// That trivia has no line break when the list's first statement shares its line with whatever opens
    /// the list, such as `{ let limit = value > 1` or `case 0: return name`. Then the brace lands at the
    /// end of the branch's last line. That has to stay so inside a one-line string interpolation, where a
    /// line break doesn't compile. But after a `//` comment the brace became part of the comment, and after
    /// `#endif` or `#sourceLocation(…)` it was an extra token. The file didn't compile, which fails the
    /// build that every mutant shares, so in those cases alone a line break goes first.
    private static func closingBrace(
        of statements: CodeBlockItemListSyntax,
        indentedLike original: CodeBlockItemListSyntax
    ) -> TokenSyntax {
        let trivia = original.leadingTrivia
        guard endsInALineCommentOrDirective(statements), !startsWithLineBreak(trivia) else {
            return .rightBraceToken().withLeadingTrivia(trivia)
        }
        return .rightBraceToken().withLeadingTrivia(.newline + trivia)
    }

    /// Whether the last line of `statements` ends in a `//` comment or a directive, after which nothing
    /// else may follow on that line.
    private static func endsInALineCommentOrDirective(_ statements: CodeBlockItemListSyntax) -> Bool {
        guard let lastToken = statements.lastToken(viewMode: .sourceAccurate) else {
            return false
        }
        let endsInLineComment = lastToken.trailingTrivia.contains { piece in
            switch piece {
            case .lineComment, .docLineComment: true
            default: false
            }
        }
        return endsInLineComment
            || lastToken.tokenKind == .poundEndif
            || lastToken.parent?.is(PoundSourceLocationSyntax.self) == true
    }

    /// Only these end a `//` comment. A form feed or vertical tab counts as a newline to swift-syntax,
    /// but the comment runs on past it.
    private static func startsWithLineBreak(_ trivia: Trivia) -> Bool {
        switch trivia.first {
        case .newlines, .carriageReturns, .carriageReturnLineFeeds: true
        default: false
        }
    }

    private static func buildSchemataCondition(
        withId id: String
    ) -> ConditionElementListSyntax {
        ConditionElementListSyntax([
            ConditionElementSyntax(
                condition: ConditionElementSyntax.Condition(
                    SequenceExprSyntax(
                        elements: ExprListSyntax([
                            ExprSyntax(
                                SubscriptCallExprSyntax(
                                    calledExpression:
                                    // `__SwiftMutator.environment`, the copy MuterRewriter appends to
                                    // the file. Reading `ProcessInfo.processInfo.environment` here
                                    // rebuilt the dictionary on every execution of the block.
                                    MemberAccessExprSyntax(
                                        base: MemberAccessExprSyntax(
                                            period: .periodToken(presence: .missing),
                                            declName: DeclReferenceExprSyntax(
                                                baseName: .identifier(MuterRewriter.environmentCacheName)
                                            )
                                        ),
                                        declName: DeclReferenceExprSyntax(
                                            baseName: .identifier("environment")
                                        )
                                    ),
                                    leftSquare: .leftSquareToken(),
                                    arguments:
                                    LabeledExprListSyntax([
                                        LabeledExprSyntax(
                                            label: nil,
                                            colon: nil,
                                            expression: StringLiteralExprSyntax(
                                                openingQuote: .stringQuoteToken(),
                                                segments: StringLiteralSegmentListSyntax(
                                                    [
                                                        .stringSegment(
                                                            StringSegmentSyntax(
                                                                content:
                                                                .stringSegment(id)
                                                            )
                                                        ),
                                                    ]
                                                ),
                                                closingQuote: .stringQuoteToken()
                                            )
                                        ),
                                    ]),
                                    rightSquare: .rightSquareToken(),
                                    trailingClosure: nil,
                                    additionalTrailingClosures: []
                                )
                            ),
                            ExprSyntax(
                                BinaryOperatorExprSyntax(
                                    operator: .binaryOperator("!=")
                                        .withLeadingTrivia(.spaces(1))
                                        .withTrailingTrivia(.spaces(1))
                                )
                            ),
                            ExprSyntax(
                                NilLiteralExprSyntax(
                                    nilKeyword: .keyword(.nil)
                                        .withTrailingTrivia(.spaces(1))
                                )
                            ),
                        ])
                    )
                ),
                trailingComma: nil
            ),
        ])
    }
}
