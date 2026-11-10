import Foundation
import SwiftSyntax

enum MutationSwitch {
    /// Whether a closure's one expression throws and awaits, and so the closure called on the spot that switches it
    /// does.
    struct ClosureEffects {
        let `throws`: Bool
        let awaits: Bool
    }

    /// Switches each mutant of `mutationSchemata` on in place of `originalSyntax`. `firstLineStart` is the line
    /// break and the indentation that start the line of the list's first token in its file, as
    /// `startOfTheFirstLine(of:)` gives them. It's worked out only for a brace that needs it. `returningItsExpression`
    /// says each branch returns the list's one expression, so the switch is an `if` statement: for a body whose value
    /// is its one macro (`CodeBlockItemListSyntax.isAMacroItsBodyReturns`), as the body's value, an `if` expression
    /// whose branches are `#Predicate { … }` doesn't compile ("value pack expansion can only appear inside a function
    /// argument list"), and in a closure called on the spot (`inAClosureCalledOnTheSpot`).
    static func apply(
        mutationSchemata: MutationSchemata,
        with originalSyntax: CodeBlockItemListSyntax,
        onALineStartingWith firstLineStart: @autoclosure () -> Trivia,
        readingEnvironmentFrom environmentCacheName: String,
        returningItsExpression: Bool = false
    ) -> CodeBlockItemListSyntax {
        guard !mutationSchemata.isEmpty else {
            return originalSyntax
        }
        let originalCode = returningItsExpression ? returning(originalSyntax) : originalSyntax
        var branches = branches(switchingOn: mutationSchemata, of: originalCode)
        if returningItsExpression {
            branches = branches.map(returning)
        }

        var mutants = Array(zip(mutationSchemata, branches))
        let (firstSchema, firstStatements) = mutants.removeFirst()

        var previousElseBody = IfExprSyntax.ElseBody(
            originalBranch(originalCode, onALineStartingWith: firstLineStart())
        )

        for (schema, statements) in mutants {
            previousElseBody = IfExprSyntax.ElseBody(
                branch(
                    switchingOn: schema,
                    to: statements,
                    orElse: previousElseBody,
                    onALineStartingWith: firstLineStart(),
                    readingEnvironmentFrom: environmentCacheName
                )
            )
        }

        let outterIfStatement = IfExprSyntax(
            ifKeyword: .keyword(.if)
                .withTrailingTrivia(.spaces(1))
                .withLeadingTrivia(originalCode.leadingTrivia),
            conditions: buildSchemataCondition(
                withId: firstSchema.id,
                readingFrom: environmentCacheName
            ),
            body: CodeBlockSyntax(
                statements: firstStatements,
                rightBrace: closingBrace(
                    of: firstStatements,
                    indentedLike: originalCode,
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

    /// The last branch, which holds `originalCode`.
    private static func originalBranch(
        _ originalCode: CodeBlockItemListSyntax,
        onALineStartingWith firstLineStart: @autoclosure () -> Trivia
    ) -> CodeBlockSyntax {
        CodeBlockSyntax(
            statements: originalCode,
            rightBrace: closingBrace(
                of: originalCode,
                indentedLike: originalCode,
                onALineStartingWith: firstLineStart()
            )
        )
    }

    /// The `if` that switches `schema`'s mutant on, with `statements` in its branch and `previousElseBody` after its
    /// `else`.
    private static func branch(
        switchingOn schema: MutationSchema,
        to statements: CodeBlockItemListSyntax,
        orElse previousElseBody: IfExprSyntax.ElseBody,
        onALineStartingWith firstLineStart: @autoclosure () -> Trivia,
        readingEnvironmentFrom environmentCacheName: String
    ) -> IfExprSyntax {
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
    }

    /// `apply`'s switch of `list`, a closure's one expression, in a closure called on the spot, which a result builder
    /// takes as one expression (`SchemataMutationMapping.switchInAClosureCalledOnTheSpot(theListOf:)`):
    /// `{ if … { return mutant } else { return original } }()`. The call is a `try` or an `await` where the expression
    /// is. The list's leading trivia goes before the closure's brace, and its trailing trivia after the call.
    static func inAClosureCalledOnTheSpot(
        mutationSchemata: MutationSchemata,
        with list: CodeBlockItemListSyntax,
        onALineStartingWith firstLineStart: @autoclosure () -> Trivia,
        readingEnvironmentFrom environmentCacheName: String,
        effects: ClosureEffects
    ) -> CodeBlockItemListSyntax {
        guard !mutationSchemata.isEmpty, let item = list.first else {
            return list
        }
        let switched = apply(
            mutationSchemata: mutationSchemata,
            with: list.with(\.leadingTrivia, []).with(\.trailingTrivia, []),
            onALineStartingWith: firstLineStart(),
            readingEnvironmentFrom: environmentCacheName,
            returningItsExpression: true
        )
        var call = ExprSyntax(FunctionCallExprSyntax(
            calledExpression: ClosureExprSyntax(
                leftBrace: .leftBraceToken(trailingTrivia: .space),
                statements: switched,
                rightBrace: .rightBraceToken(leadingTrivia: .space)
            ),
            leftParen: .leftParenToken(),
            arguments: [],
            rightParen: .rightParenToken()
        ))
        if effects.awaits {
            call = ExprSyntax(AwaitExprSyntax(awaitKeyword: .keyword(.await, trailingTrivia: .space), expression: call))
        }
        if effects.throws {
            call = ExprSyntax(TryExprSyntax(tryKeyword: .keyword(.try, trailingTrivia: .space), expression: call))
        }
        call = call.with(\.leadingTrivia, list.leadingTrivia).with(\.trailingTrivia, list.trailingTrivia)
        return [item.with(\.item, .expr(call))]
    }

    /// `list`, whose one item is an expression, as a `return` of it, with its trivia.
    private static func returning(_ list: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
        guard list.count == 1, let item = list.first, let value = item.item.as(ExprSyntax.self) else {
            return list
        }
        let statement = ReturnStmtSyntax(
            returnKeyword: .keyword(.return, leadingTrivia: value.leadingTrivia, trailingTrivia: .space),
            expression: value.with(\.leadingTrivia, [])
        )
        return CodeBlockItemListSyntax([item.with(\.item, .stmt(StmtSyntax(statement)))])
    }

    private static func buildSchemataCondition(
        withId id: String,
        readingFrom environmentCacheName: String
    ) -> ConditionElementListSyntax {
        ConditionElementListSyntax([
            mutantIsOn(withId: id, readingFrom: environmentCacheName),
            // After the mutant's own condition, so it is read only once that one holds, which a file's one `ran`
            // needs to say that its one mutant ran. In the condition, not the branch: a branch that is a single
            // expression, an `if` expression's, has no room for a statement.
            ranCondition(readingFrom: environmentCacheName),
        ])
    }

    /// `<environmentCacheName>.environment["<id>"] != nil, `: the mutant's own condition.
    private static func mutantIsOn(
        withId id: String,
        readingFrom environmentCacheName: String
    ) -> ConditionElementSyntax {
        ConditionElementSyntax(
            condition: ConditionElementSyntax.Condition(
                SequenceExprSyntax(
                    elements: ExprListSyntax([
                        ExprSyntax(environmentLookup(of: id, in: environmentCacheName)),
                        ExprSyntax(
                            BinaryOperatorExprSyntax(
                                operator: .binaryOperator("!=")
                                    .withLeadingTrivia(.spaces(1))
                                    .withTrailingTrivia(.spaces(1))
                            )
                        ),
                        ExprSyntax(NilLiteralExprSyntax(nilKeyword: .keyword(.nil))),
                    ])
                )
            ),
            trailingComma: .commaToken(trailingTrivia: .spaces(1))
        )
    }

    /// `<environmentCacheName>.environment["<id>"]`.
    private static func environmentLookup(of id: String, in environmentCacheName: String) -> SubscriptCallExprSyntax {
        SubscriptCallExprSyntax(
            // `<environmentCacheName>.environment`, the copy MuterRewriter appends to the file. Reading
            // `ProcessInfo.processInfo.environment` here rebuilt the dictionary on every execution of the block.
            calledExpression:
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
    }

    /// `<environmentCacheName>.ran `, which creates the activation marker once a mutant's condition holds.
    private static func ranCondition(readingFrom environmentCacheName: String) -> ConditionElementSyntax {
        ConditionElementSyntax(
            condition: ConditionElementSyntax.Condition(
                MemberAccessExprSyntax(
                    base: DeclReferenceExprSyntax(baseName: .identifier(environmentCacheName)),
                    declName: DeclReferenceExprSyntax(
                        baseName: .identifier("ran").withTrailingTrivia(.spaces(1))
                    )
                )
            ),
            trailingComma: nil
        )
    }
}
