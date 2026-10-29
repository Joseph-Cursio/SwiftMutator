import Foundation
import SwiftSyntax

enum MutationSwitch {
    /// Switches each mutant of `mutationSchemata` on in place of `originalSyntax`. `firstLineStart` is the line
    /// break and the indentation that start the line of the list's first token in its file, as
    /// `startOfTheFirstLine(of:)` gives them. It's worked out only for a brace that needs it.
    static func apply(
        mutationSchemata: MutationSchemata,
        with originalSyntax: CodeBlockItemListSyntax,
        onALineStartingWith firstLineStart: @autoclosure () -> Trivia,
        readingEnvironmentFrom environmentCacheName: String
    ) -> CodeBlockItemListSyntax {
        guard !mutationSchemata.isEmpty else {
            return originalSyntax
        }

        var schemata = mutationSchemata
        let firstSchema = schemata.removeFirst()

        var previousElseBody = IfExprSyntax.ElseBody(
            CodeBlockSyntax(
                statements: originalSyntax,
                rightBrace: closingBrace(
                    of: originalSyntax,
                    indentedLike: originalSyntax,
                    onALineStartingWith: firstLineStart()
                )
            )
        )

        for schema in schemata {
            let elseBody = IfExprSyntax.ElseBody(
                IfExprSyntax(
                    ifKeyword: .keyword(.if)
                        .withTrailingTrivia(.spaces(1))
                        .withLeadingTrivia(previousElseBody.leadingTrivia),
                    conditions: buildSchemataCondition(
                        withId: schema.id,
                        readingFrom: environmentCacheName
                    ),
                    body: CodeBlockSyntax(
                        statements: schema.syntaxMutation,
                        rightBrace: closingBrace(
                            of: schema.syntaxMutation,
                            indentedLike: schema.syntaxMutation,
                            onALineStartingWith: firstLineStart()
                        )
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
                withId: firstSchema.id,
                readingFrom: environmentCacheName
            ),
            body: CodeBlockSyntax(
                statements: firstSchema.syntaxMutation,
                rightBrace: closingBrace(
                    of: firstSchema.syntaxMutation,
                    indentedLike: originalSyntax,
                    onALineStartingWith: firstLineStart()
                )
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

    /// The line break before the line of `node`'s first token in its file, and the spaces and tabs that start
    /// that line. A node on the file's first line gets a line feed.
    static func startOfTheFirstLine(of node: some SyntaxProtocol) -> Trivia {
        guard let first = node.firstToken(viewMode: .sourceAccurate) else {
            return .newline
        }
        // The text before the token on its line, nearest first: its leading trivia, then the tokens before it
        // back to the one the line starts in.
        var piece = first.leadingTrivia.description
        var textBefore = [piece]
        var token = first.previousToken(viewMode: .sourceAccurate)
        while !piece.utf8.contains(where: isLineBreak), let previous = token {
            piece = previous.description
            textBefore.append(piece)
            token = previous.previousToken(viewMode: .sourceAccurate)
        }
        let text = textBefore.reversed().joined()
        return startOfLastLine(in: text) ?? startOfLastLine(in: "\n" + text) ?? .newline
    }

    /// The `}` that closes a branch holding `statements`, with the leading trivia of `original`.
    ///
    /// That trivia has no line break when the list's first statement shares its line with whatever opens
    /// the list, such as `{ let limit = value > 1` or `case 0: return name`. Then the brace lands at the
    /// end of the branch's last line. That has to stay so inside a one-line string interpolation, where a
    /// line break doesn't compile. But after a `//` comment the brace became part of the comment, and after
    /// `#endif` or `#sourceLocation(…)` it was an extra token. The file didn't compile, which fails the
    /// build that every mutant shares, so in those cases alone a line break goes first.
    ///
    /// The brace's line then starts like the branch's last line, or like the list's first line when the branch
    /// has no line break of its own: with the same line break, so the file's line endings stay as they are,
    /// and the same spaces and tabs. Inside a multi-line string every line after a line feed, an
    /// interpolation's code too, must start with the indentation of the closing `"""`, and each such line of
    /// the file already does. The compiler doesn't check a line after a lone carriage return, nor a brace that
    /// copies one. With the list's trivia alone after a line feed, the brace started at column 0 and didn't
    /// compile.
    private static func closingBrace(
        of statements: CodeBlockItemListSyntax,
        indentedLike original: CodeBlockItemListSyntax,
        onALineStartingWith firstLineStart: @autoclosure () -> Trivia
    ) -> TokenSyntax {
        let trivia = original.leadingTrivia
        guard endsInALineCommentOrDirective(statements), !startsWithLineBreak(trivia) else {
            return .rightBraceToken().withLeadingTrivia(trivia)
        }
        return .rightBraceToken().withLeadingTrivia(startOfLastLine(in: statements.description) ?? firstLineStart())
    }

    /// The line break that starts the last line of `text`, and the spaces and tabs after it, or nil if `text`
    /// has no line break.
    private static func startOfLastLine(in text: String) -> Trivia? {
        let utf8 = text.utf8
        guard let lineBreak = utf8.lastIndex(where: isLineBreak) else {
            return nil
        }
        let lineBreakPiece: TriviaPiece
        if utf8[lineBreak] == UInt8(ascii: "\r") {
            lineBreakPiece = .carriageReturns(1)
        } else if lineBreak != utf8.startIndex, utf8[utf8.index(before: lineBreak)] == UInt8(ascii: "\r") {
            lineBreakPiece = .carriageReturnLineFeeds(1)
        } else {
            lineBreakPiece = .newlines(1)
        }
        let indentation = utf8[utf8.index(after: lineBreak)...].prefix { byte in
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
        }
        return Trivia(pieces: [lineBreakPiece] + indentation.map { $0 == UInt8(ascii: "\t") ? .tabs(1) : .spaces(1) })
    }

    /// Only a line feed or a carriage return ends a line of Swift code or of a multi-line string.
    private static func isLineBreak(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
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
        withId id: String,
        readingFrom environmentCacheName: String
    ) -> ConditionElementListSyntax {
        ConditionElementListSyntax([
            ConditionElementSyntax(
                condition: ConditionElementSyntax.Condition(
                    SequenceExprSyntax(
                        elements: ExprListSyntax([
                            ExprSyntax(
                                SubscriptCallExprSyntax(
                                    calledExpression:
                                    // `<environmentCacheName>.environment`, the copy MuterRewriter
                                    // appends to the file. Reading `ProcessInfo.processInfo.environment`
                                    // here rebuilt the dictionary on every execution of the block.
                                    MemberAccessExprSyntax(
                                        base: MemberAccessExprSyntax(
                                            period: .periodToken(presence: .missing),
                                            declName: DeclReferenceExprSyntax(
                                                baseName: .identifier(environmentCacheName)
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
