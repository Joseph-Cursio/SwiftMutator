import SwiftOperators
import SwiftSyntax

/// Gives each comparison the mutants of Kaminski, Ammann and Offutt's sufficient set ("Better predicate testing",
/// 2011): any tests that kill these few, with RelationalBoundary's, kill every other mutant of an ordering
/// comparison's operator. An ordering comparison gets its operator swapped, `<` and `>` for `!=`, `<=` and `>=` for
/// `==`, and is replaced whole with the constant it gives when its operands are apart: `false` for `<` and `>`, `true`
/// for `<=` and `>=`. RelationalBoundary gives the third, `<` to `<=`. An equality check, `==` or `!=`, is replaced
/// with `true`, and in a second mutant with `false`: the paper's `<=` and `>=` for `==` don't compile on a type that
/// is only `Equatable`, and the tree has no types.
///
/// A constant replaces the comparison as the standard operator table folds its sequence, so `a + 1 < b` becomes
/// `false`, and `x < y && z` becomes `false && z`. A comparison that gets no constant gets its operator swapped,
/// `==` to `!=` too: one in a sequence the standard table can't fold, as an operator of the project's own precedence
/// is in it; one whose value is thrown away, as a statement of its own, which is an overload with side effects, as
/// Nimble's `expect(x) == 1`, where a literal would be an unused value that tests nothing; and one that holds a
/// closure's only use of its highest `$` argument, as `{ $0 > 1 }`, which as `{ false }` would take no argument. Nor
/// does a comparison that decides a `while` or `repeat`-`while` get the constant that would keep the loop going until
/// the time limit, as `while a <= b` would `true`.
enum ROROperator {
    final class Visitor: TokenAwareVisitor {
        /// Whether the comparison of the operator being visited gets its operator swapped, as `canMutate` answers.
        private var swapsTheOperator = false

        convenience init(
            configuration: MuterConfiguration? = nil,
            sourceCodeInfo: SourceCodeInfo,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                configuration: configuration,
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .ror,
                coverage: coverage
            )

            tokensToDiscover = ROROperator.comparisons.map { .binaryOperator($0) }

            // `==` and `!=` are swapped only where they get no constant.
            oppositeOperatorMapping = [
                "<": "!=",
                ">": "!=",
                "<=": "==",
                ">=": "==",
                "==": "!=",
                "!=": "==",
            ]
        }

        override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            swapsTheOperator = false
            guard ROROperator.comparisons.contains(node.operator.text) else { return super.visit(node) }

            let mutants = mutants(ofTheComparisonWith: node)
            // The mutants are one comparison's: a directive that leaves out where any of them is placed leaves out all.
            guard !mutants.places.contains(where: { isLeftOutByADirective($0, in: node.root) }) else {
                return super.visit(node)
            }

            swapsTheOperator = mutants.swap != nil
            if let comparison = mutants.comparison {
                for (keyword, position) in mutants.constants {
                    let after = keyword == .true ? "true" : "false"
                    add(
                        mutation: comparison.replaced(with: keyword),
                        with: comparison.sequence,
                        at: position,
                        snapshot: MutationOperator.Snapshot(
                            before: comparison.before,
                            after: after,
                            description: "replaced the comparison with \(after)"
                        ),
                        // As the swap is: coverage, the directives and an inactive `#if` go by the operator, and
                        // `--changed-lines` by the whole sequence.
                        changing: node,
                        spanning: comparison.sequence
                    )
                }
            }
            return super.visit(node)
        }

        override func canMutate(_: BinaryOperatorExprSyntax) -> Bool {
            swapsTheOperator
        }
    }

    /// The comparison operators this operator mutates. `===` and `!==` aren't among them, as nothing swaps an
    /// identity check for another.
    static let comparisons: Set<String> = ["==", "!=", "<", "<=", ">", ">="]

    /// The constants that replace a comparison of `comparison`: the one it gives when its operands are apart for an
    /// ordering operator, and both for an equality operator, the one it gives when they're equal first.
    static func constants(for comparison: String) -> [Keyword] {
        switch comparison {
        case "<", ">": [.false]
        case "<=", ">=": [.true]
        case "==": [.true, .false]
        default: [.false, .true]
        }
    }

    /// The operator of the comparison this operator replaces `expression` with a constant for, or nil: the last thing
    /// `expression` works out, inside any parentheses, `try` and `await`, is one of its comparisons, and that
    /// comparison gets a constant, as one whose value is used and that the standard table folds does. In a loop's
    /// condition, where it leaves out the constant that would keep the loop going, the swap or the other constant
    /// stands for it. NegateConditional and ReplaceBooleanValue leave such an expression to it.
    static func comparisonGivenAConstant(in expression: ExprSyntax) -> BinaryOperatorExprSyntax? {
        var expression = expression
        while true {
            if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
               let only = tuple.elements.first, only.label == nil {
                expression = only.expression
            } else if let attempt = expression.as(TryExprSyntax.self), attempt.questionOrExclamationMark?.text != "?" {
                expression = attempt.expression
            } else if let wait = expression.as(AwaitExprSyntax.self) {
                expression = wait.expression
            } else {
                break
            }
        }
        guard let sequence = expression.as(SequenceExprSyntax.self),
              let folded = try? OperatorTable.standardOperators.foldSingle(sequence)
        else { return nil }
        var outermost = folded
        while outermost.isAnEffectMarker, let inner = outermost.children(viewMode: .sourceAccurate).last {
            guard let expression = inner.as(ExprSyntax.self) else { return nil }
            outermost = expression
        }
        guard let comparison = outermost.as(InfixOperatorExprSyntax.self)?.operator.as(BinaryOperatorExprSyntax.self),
              comparisons.contains(comparison.operator.text),
              let node = Comparison.token(
                  at: comparison.operator.positionAfterSkippingLeadingTrivia,
                  from: folded,
                  in: sequence
              )?.parent?.as(BinaryOperatorExprSyntax.self),
              Comparison(withOperator: node) != nil
        else { return nil }
        return node
    }
}

/// RelationalOperatorReplacement's mutants of one comparison, by where each is placed.
private struct ComparisonMutants {
    /// The comparison, when it gets a constant.
    let comparison: Comparison?
    /// Its constants, in the order of their places.
    let constants: [(keyword: Keyword, position: MutationPosition)]
    /// Where its operator's swap is, when it gets one.
    let swap: MutationPosition?

    var places: [MutationPosition] {
        constants.map(\.position) + (swap.map { [$0] } ?? [])
    }
}

extension MuterVisitor {
    /// Where RelationalOperatorReplacement places its mutants of the comparison whose operator is `node`, which a
    /// directive leaves out together.
    func placesOfTheMutants(ofTheComparisonWith node: BinaryOperatorExprSyntax) -> [MutationPosition] {
        mutants(ofTheComparisonWith: node).places
    }

    fileprivate func mutants(ofTheComparisonWith node: BinaryOperatorExprSyntax) -> ComparisonMutants {
        let name = node.operator.text
        let comparison = Comparison(withOperator: node)
        // `true` where the comparison starts, and `false` where it ends, so that each mutant has a place, and so a
        // switch, of its own: two mutants of one operator at one place share a switch, and can't be told apart.
        let constants: [(keyword: Keyword, position: MutationPosition)] = comparison.map { comparison in
            ROROperator.constants(for: name)
                .filter { $0 != comparison.endlessLoopConstant }
                .map { keyword in
                    keyword == .true
                        ? (keyword, startLocation(for: comparison.first, afterLeadingTrivia: true))
                        : (keyword, endLocation(for: comparison.last, afterTrailingTrivia: false))
                }
                .sorted { $0.position.utf8Offset < $1.position.utf8Offset }
        } ?? []
        let swaps = !["==", "!="].contains(name) || constants.isEmpty
        return ComparisonMutants(
            comparison: comparison,
            constants: constants,
            swap: swaps ? startLocation(for: node) : nil
        )
    }
}

/// A comparison that a constant can replace: one in a sequence the standard operator table folds, whose value is used.
private struct Comparison {
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
        guard let sequence = node.parent?.parent?.as(SequenceExprSyntax.self),
              let folded = try? OperatorTable.standardOperators.foldSingle(sequence),
              !folded.is(SequenceExprSyntax.self),
              let token = Self.token(at: node.operator.positionAfterSkippingLeadingTrivia, from: sequence, in: folded),
              let comparison = token.parent?.as(BinaryOperatorExprSyntax.self)?.parent?.as(InfixOperatorExprSyntax.self)
        else { return nil }
        var replaced = ExprSyntax(comparison)
        // A `try` before the sequence is hoisted over what follows it: over `a < b` alone, it goes with it, as `try
        // false` warns that nothing throws; over `a < b && c`, it stays, as `c` may throw. A `try?` stays, as what it
        // gives is an optional.
        while let parent = replaced.parent?.as(ExprSyntax.self), parent.isAnEffectMarker,
              parent.as(TryExprSyntax.self)?.questionOrExclamationMark?.text != "?" {
            replaced = parent
        }
        guard let firstToken = replaced.firstToken(viewMode: .sourceAccurate),
              let lastToken = replaced.lastToken(viewMode: .sourceAccurate),
              let first = Self.token(at: firstToken.positionAfterSkippingLeadingTrivia, from: folded, in: sequence),
              let last = Self.token(at: lastToken.positionAfterSkippingLeadingTrivia, from: folded, in: sequence)
        else { return nil }
        self.sequence = sequence
        self.folded = folded
        self.replaced = replaced
        self.first = first
        self.last = last
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

private extension ExprSyntax {
    /// Whether this is a `try`, `await` or `unsafe`, which folding hoists over the operators after it.
    var isAnEffectMarker: Bool {
        `is`(TryExprSyntax.self) || `is`(AwaitExprSyntax.self) || `is`(UnsafeExprSyntax.self)
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

private extension Character {
    /// Whether this can be part of a name or a keyword, which a literal next to it would join.
    var isPartOfAName: Bool {
        isLetter || isNumber || self == "_" || self == "$"
    }
}
