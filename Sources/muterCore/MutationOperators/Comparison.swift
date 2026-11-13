import SwiftOperators
import SwiftSyntax

/// Puts a node in place of the one with an ID.
private final class Replacing: SyntaxRewriter {
    private let target: SyntaxIdentifier
    private let replacement: ExprSyntax

    init(_ target: SyntaxIdentifier, with replacement: ExprSyntax) {
        self.target = target
        self.replacement = replacement
        super.init(viewMode: .sourceAccurate)
    }

    override func visitAny(_ node: Syntax) -> Syntax? {
        node.id == target ? Syntax(replacement) : nil
    }
}

/// A comparison that a constant can replace: one in a sequence the standard operator table folds, whose value is used.
struct Comparison {
    /// The sequence that holds it, which its mutants' code replaces whole, as the tree isn't folded.
    let sequence: SequenceExprSyntax
    /// The sequence folded.
    private let folded: ExprSyntax
    /// The comparison in `folded`, with any `try`, `await` and `unsafe` around it alone, which are dropped with it.
    private let replaced: ExprSyntax
    /// Its first and last tokens in the file's tree, where its constants are placed.
    let first: TokenSyntax
    let last: TokenSyntax

    /// The comparison whose operator is `node`, or nil when it gets no constant: the standard table can't fold its
    /// sequence, or its value is thrown away, or it holds the only use of a closure's highest `$` argument.
    init?(withOperator node: BinaryOperatorExprSyntax) {
        guard let parentSequence = node.parent?.parent?.as(SequenceExprSyntax.self),
              let foldedSequence = try? OperatorTable.standardOperators.foldSingle(parentSequence),
              !foldedSequence.is(SequenceExprSyntax.self),
              let token = Self.token(
                  at: node.operator.positionAfterSkippingLeadingTrivia,
                  from: parentSequence,
                  in: foldedSequence
              ),
              let comparison = token.parent?.as(BinaryOperatorExprSyntax.self)?.parent?.as(InfixOperatorExprSyntax.self)
        else { return nil }
        var replacedExpression = ExprSyntax(comparison)
        // A `try` before the sequence is hoisted over what follows it: over `a < b` alone, it goes with it, as `try
        // false` warns that nothing throws. A `try?` stays, as what it gives is an optional.
        while let parent = replacedExpression.parent?.as(ExprSyntax.self), parent.isAnEffectMarker,
              parent.as(TryExprSyntax.self)?.questionOrExclamationMark?.text != "?" {
            replacedExpression = parent
        }
        // Hoisted over more, as in `try load() < 1 && check()` or `try load() > 1 ? a : b`, it would be left over what
        // may not throw, which warns, and fails a build with warnings as errors: so the comparison gets no constant.
        guard !Self.isWrittenAfterAHoistedMarker(replacedExpression, in: foldedSequence) else { return nil }
        guard let firstToken = replacedExpression.firstToken(viewMode: .sourceAccurate),
              let lastToken = replacedExpression.lastToken(viewMode: .sourceAccurate),
              let firstFolded = Self.token(
                  at: firstToken.positionAfterSkippingLeadingTrivia,
                  from: foldedSequence,
                  in: parentSequence
              ),
              let lastFolded = Self.token(
                  at: lastToken.positionAfterSkippingLeadingTrivia,
                  from: foldedSequence,
                  in: parentSequence
              )
        else { return nil }
        self.sequence = parentSequence
        self.folded = foldedSequence
        self.replaced = replacedExpression
        self.first = firstFolded
        self.last = lastFolded
        guard !isThrownAway, !dropsAClosuresArgument else { return nil }
    }

    /// The token of `other` at `position` in `tree`, which holds the same tokens: a sequence folded holds its tokens,
    /// trivia and all, in their order, so a token's offset in one is its offset in the other.
    static func token(
        at position: AbsolutePosition,
        from tree: some SyntaxProtocol,
        in other: some SyntaxProtocol
    ) -> TokenSyntax? {
        other.token(at: other.position.advanced(by: tree.position.distance(to: position)))
    }

    /// Whether a `try`, `await` or `unsafe` written right in front of `replaced` covers more than it once `folded`: one
    /// whose expression starts where `replaced` does. A `try?` counts too, as its optional stays.
    private static func isWrittenAfterAHoistedMarker(_ replaced: ExprSyntax, in folded: ExprSyntax) -> Bool {
        let start = replaced.positionAfterSkippingLeadingTrivia
        var node = Syntax(replaced)
        while node.id != folded.id, let parent = node.parent {
            if let marked = parent.as(ExprSyntax.self)?.markedExpression,
               marked.positionAfterSkippingLeadingTrivia == start {
                return true
            }
            node = parent
        }
        return false
    }

    /// What it replaces, on one line.
    var before: String {
        replaced.trimmedDescription.inlined
    }

    /// The sequence with `keyword` in place of the comparison, with the trivia on either side of it left outside: a
    /// `//` comment after it stays a comment. A space keeps the literal apart from a name or keyword it would otherwise
    /// touch.
    func replaced(with keyword: Keyword) -> ExprSyntax {
        let previous = replaced.previousToken(viewMode: .sourceAccurate)
            ?? sequence.previousToken(viewMode: .sourceAccurate)
        let next = replaced.nextToken(viewMode: .sourceAccurate) ?? sequence.nextToken(viewMode: .sourceAccurate)
        let touchesThePrevious = replaced.leadingTrivia.isEmpty && previous?.trailingTrivia.isEmpty == true
            && previous?.text.last.map(\.isPartOfAName) == true
        let touchesTheNext = replaced.trailingTrivia.isEmpty && next?.leadingTrivia.isEmpty == true
            && next?.text.first.map(\.isPartOfAName) == true
        let literal = ExprSyntax(BooleanLiteralExprSyntax(literal: .keyword(
            keyword,
            leadingTrivia: touchesThePrevious ? .space : replaced.leadingTrivia,
            trailingTrivia: touchesTheNext ? .space : replaced.trailingTrivia
        )))
        return Replacing(replaced.id, with: literal).rewrite(folded).cast(ExprSyntax.self)
    }

    /// Whether a closure that names no parameters uses its highest `$` argument here alone. Such a closure takes as
    /// many arguments as the highest it uses says, so `items.filter { $0 > 1 }` as `items.filter { false }` takes
    /// none, which doesn't compile where one is passed. A nested closure's arguments are its own.
    private var dropsAClosuresArgument: Bool {
        guard let closure = sequence.parent?.ancestorOrSelf(mapping: { $0.as(ClosureExprSyntax.self) }),
              closure.signature?.parameterClause == nil
        else { return false }
        let here = first.positionAfterSkippingLeadingTrivia..<last.endPositionBeforeTrailingTrivia
        var highestHere = -1
        var highestElsewhere = -1
        for token in closure.statements.tokens(viewMode: .sourceAccurate) {
            guard case let .dollarIdentifier(name) = token.tokenKind, let index = Int(name.dropFirst()),
                  token.parent?.ancestorOrSelf(mapping: { $0.as(ClosureExprSyntax.self) })?.id == closure.id
            else { continue }
            if here.contains(token.positionAfterSkippingLeadingTrivia) {
                highestHere = max(highestHere, index)
            } else {
                highestElsewhere = max(highestElsewhere, index)
            }
        }
        return highestHere > highestElsewhere
    }

    /// The constant that would keep a loop going until the time limit, which the score counts as a survivor, or nil:
    /// the one that makes the whole condition of a `while` or `repeat`-`while` true, when the comparison decides it
    /// alone or through `||`, `!` and parentheses, as `true` does in `while a <= b`, and `false` in `while !(a < b)`.
    /// Through `&&`, or beside another condition after a comma, the rest of the condition can still end the loop.
    var endlessLoopConstant: Keyword? {
        var node = Syntax(replaced)
        while node.id != folded.id {
            guard let parent = node.parent else { return nil }
            if let infix = parent.as(InfixOperatorExprSyntax.self) {
                guard infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "||" else { return nil }
            } else if parent.as(ExprSyntax.self)?.isAnEffectMarker != true {
                return nil
            }
            node = parent
        }
        var keepsGoing = Keyword.true
        var condition = Syntax(sequence)
        while let parent = condition.parent {
            if let element = parent.as(LabeledExprSyntax.self), element.label == nil,
               let tuple = element.parent?.parent?.as(TupleExprSyntax.self), tuple.elements.count == 1 {
                condition = Syntax(tuple)
            } else if let negation = parent.as(PrefixOperatorExprSyntax.self), negation.operator.text == "!" {
                keepsGoing = keepsGoing == .true ? .false : .true
                condition = parent
            } else if parent.as(ExprSyntax.self)?.isAnEffectMarker == true {
                condition = parent
            } else {
                break
            }
        }
        if let element = condition.parent?.as(ConditionElementSyntax.self),
           let list = element.parent?.as(ConditionElementListSyntax.self), list.count == 1,
           list.parent?.is(WhileStmtSyntax.self) == true {
            return keepsGoing
        }
        if let loop = condition.parent?.as(RepeatStmtSyntax.self), loop.condition.id == condition.id {
            return keepsGoing
        }
        return nil
    }

    /// Whether its value is thrown away: it is the whole of a statement that isn't the value of its body.
    private var isThrownAway: Bool {
        guard replaced.id == folded.id, let statement = sequence.parent?.as(CodeBlockItemSyntax.self) else {
            return false
        }
        return !statement.givesItsValue
    }
}

extension ExprSyntax {
    /// Whether this is a `try`, `await` or `unsafe`, which folding hoists over the operators after it.
    var isAnEffectMarker: Bool {
        `is`(TryExprSyntax.self) || `is`(AwaitExprSyntax.self) || `is`(UnsafeExprSyntax.self)
    }

    /// The expression this `try`, `await` or `unsafe` covers, or nil when it is none of them.
    var markedExpression: ExprSyntax? {
        `as`(TryExprSyntax.self)?.expression ?? `as`(AwaitExprSyntax.self)?.expression
            ?? `as`(UnsafeExprSyntax.self)?.expression
    }
}

private extension CodeBlockItemSyntax {
    /// Whether this statement's value is used: it is the one statement of a closure, a getter, a function that writes
    /// its return type, or a branch of an `if` or `switch` that is a value. A closure that doesn't write its type may
    /// return nothing, but is mostly a predicate passed to `filter`, `sorted` or `contains`, so it counts.
    var givesItsValue: Bool {
        guard let list = parent?.as(CodeBlockItemListSyntax.self), list.count == 1, let owner = list.parent else {
            return false
        }
        if owner.is(ClosureExprSyntax.self) || owner.is(AccessorBlockSyntax.self) {
            return true
        }
        if let switchCase = owner.as(SwitchCaseSyntax.self) {
            return switchCase.parent?.parent?.as(SwitchExprSyntax.self).map { Syntax($0).isAValue } ?? false
        }
        guard owner.is(CodeBlockSyntax.self), let body = owner.parent else { return false }
        if let function = body.as(FunctionDeclSyntax.self) {
            return function.signature.returnClause.map { !$0.isReturningVoid } ?? false
        }
        if let accessor = body.as(AccessorDeclSyntax.self) {
            return accessor.accessorSpecifier.tokenKind == .keyword(.get)
        }
        return body.is(IfExprSyntax.self) && body.isAValue
    }
}

private extension Syntax {
    /// Whether this `if` or `switch` is an expression whose value is used, not a statement: an `else if` is its first
    /// `if`'s.
    var isAValue: Bool {
        var outermost = self
        while let parent = outermost.parent, parent.is(IfExprSyntax.self) {
            outermost = parent
        }
        guard let statement = outermost.parent?.as(ExpressionStmtSyntax.self) else { return true }
        return statement.parent?.as(CodeBlockItemSyntax.self)?.givesItsValue == true
    }
}
