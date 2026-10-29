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

        var mutants = Array(zip(mutationSchemata, branches(switchingOn: mutationSchemata, of: originalSyntax)))
        let (firstSchema, firstStatements) = mutants.removeFirst()

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

        for (schema, statements) in mutants {
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
                        statements: statements,
                        rightBrace: closingBrace(
                            of: statements,
                            indentedLike: statements,
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
                statements: firstStatements,
                rightBrace: closingBrace(
                    of: firstStatements,
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

    /// The statements of each mutant's branch: its copy of `original`, without the copy's `#sourceLocation`
    /// directives.
    ///
    /// Each mutant's branch holds a copy of the list and the original's branch holds the list, so the compiler
    /// read each of the list's directives once per branch. It takes a directive that opens a location again, but
    /// not a `#sourceLocation()` that closes one when none is open: after the first branch closed it, every later
    /// branch failed to compile, the original's among them, which fails the build every mutant shares. Without
    /// the copies' directives the compiler reads the list's directives once, in the original's branch, which
    /// starts in the location the original does. Code after a dropped directive in a mutant's branch takes the
    /// location in effect where the switch starts, so `#fileID` or `#line` there can differ from the original's.
    ///
    /// A mutant that removes a statement removes the directives in it, so `original` tells which there are.
    /// swift-syntax parses a directive in an `#if` clause of a type's members as unexpected text, which a copy
    /// can't drop. Dropping the others could leave it closing a location none opens, so then every copy keeps
    /// its directives, as before.
    private static func branches(
        switchingOn schemata: MutationSchemata,
        of original: CodeBlockItemListSyntax
    ) -> [CodeBlockItemListSyntax] {
        let copies = schemata.map(\.syntaxMutation)
        let directives = original.tokens(viewMode: .sourceAccurate).filter { $0.tokenKind == .poundSourceLocation }
        guard !directives.isEmpty, directives.allSatisfy(startsAStatementOrMember) else {
            return copies
        }
        return copies.map { SourceLocationRemover().rewrite($0).cast(CodeBlockItemListSyntax.self) }
    }

    /// Whether the `#sourceLocation` token `directive` starts a statement or a member, which `SourceLocationRemover`
    /// can drop.
    private static func startsAStatementOrMember(_ directive: TokenSyntax) -> Bool {
        guard let parent = directive.parent?.as(PoundSourceLocationSyntax.self)?.parent else {
            return false
        }
        return parent.is(CodeBlockItemSyntax.self) || parent.is(MemberBlockItemSyntax.self)
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

/// Drops the `#sourceLocation` directives of a mutant's copy of a statement list, at any depth: from its
/// statement lists, a `case` body's among them, and from the member lists of the types it declares.
private final class SourceLocationRemover: SyntaxRewriter {
    override func visit(_ node: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
        super.visit(Self.dropping(from: node) { $0.item.is(PoundSourceLocationSyntax.self) })
    }

    override func visit(_ node: MemberBlockItemListSyntax) -> MemberBlockItemListSyntax {
        super.visit(Self.dropping(from: node) { $0.decl.is(PoundSourceLocationSyntax.self) })
    }

    /// A `case` that held nothing but directives compiles, though one with no statement doesn't. `do {}` does
    /// nothing, as the `case` did, and unlike `break` it compiles in a result builder too. It takes the
    /// directives' place and their trivia, so a `//` comment on the `case` line ends before it.
    override func visit(_ node: SwitchCaseSyntax) -> SwitchCaseSyntax {
        let directives = node.statements
        guard let first = directives.first, directives.allSatisfy({ $0.item.is(PoundSourceLocationSyntax.self) }) else {
            return super.visit(node)
        }
        let after = directives.dropFirst().reduce(first.trailingTrivia) { $0 + $1.leadingTrivia + $1.trailingTrivia }
        let doNothing = DoStmtSyntax(
            doKeyword: .keyword(.do, leadingTrivia: first.leadingTrivia, trailingTrivia: .space),
            body: CodeBlockSyntax(statements: [], rightBrace: .rightBraceToken(trailingTrivia: after))
        )
        return super.visit(node.with(\.statements, [CodeBlockItemSyntax(item: .stmt(StmtSyntax(doNothing)))]))
    }

    /// `list` without the directives `isDirective` picks. Each directive's trivia goes to the element after it, or
    /// to the one before it at the end of the list, so the lines and comments stay as they were: a block comment
    /// after a directive can run onto the next line, and code can follow it there.
    private static func dropping<List: SyntaxCollection>(
        from list: List,
        directives isDirective: (List.Element) -> Bool
    ) -> List {
        guard list.contains(where: isDirective) else {
            return list
        }
        var kept: [List.Element] = []
        var trivia = Trivia()
        for element in list {
            if isDirective(element) {
                trivia += element.leadingTrivia + element.trailingTrivia
            } else {
                kept.append(trivia.isEmpty ? element : element.with(\.leadingTrivia, trivia + element.leadingTrivia))
                trivia = []
            }
        }
        if !trivia.isEmpty, let last = kept.popLast() {
            kept.append(last.with(\.trailingTrivia, last.trailingTrivia + trivia))
        }
        return List(kept)
    }
}
