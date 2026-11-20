import SwiftOperators
import SwiftSyntax

/// A `??` that its fallback can replace: one in a sequence the standard operator table folds, so its term, `a ?? b`,
/// is known, whose mutant should build.
struct NilCoalescing {
    /// The sequence that holds it, which its mutant's code replaces whole, as the tree isn't folded.
    let sequence: SequenceExprSyntax
    /// The sequence folded.
    let folded: ExprSyntax
    /// The `??` term in `folded`, without any `try`, `await` or `unsafe` hoisted over it, which stay.
    let coalescing: InfixOperatorExprSyntax
    /// The term's first token in the file's tree, where its mutant is placed.
    let first: TokenSyntax

    /// The characters an operator is made of, which two operators that touch would join into one.
    private static let operatorCharacters: Set<Character> = Set("/=-+!*%<>&|^~?")

    /// What takes the term's place.
    var fallback: ExprSyntax {
        coalescing.rightOperand
    }

    /// The term whose operator is `node`, or nil when it gets no mutant: `node` isn't a `??`, or the standard table
    /// can't fold its sequence, or its mutant wouldn't build. That is when the left side holds the only use of a
    /// closure's highest `$` argument, when a `try`, `await` or `unsafe` would be left over nothing it is for, and
    /// when the fallback needs a type that its place doesn't give, and when it would be assigned to itself.
    init?(withOperator node: BinaryOperatorExprSyntax) {
        guard node.operator.text == "??",
              let parentSequence = node.parent?.parent?.as(SequenceExprSyntax.self),
              let foldedSequence = try? OperatorTable.standardOperators.foldSingle(parentSequence),
              !foldedSequence.is(SequenceExprSyntax.self),
              let token = Comparison.token(
                  at: node.operator.positionAfterSkippingLeadingTrivia,
                  from: parentSequence,
                  in: foldedSequence
              ),
              let term = token.parent?.as(BinaryOperatorExprSyntax.self)?.parent?.as(InfixOperatorExprSyntax.self),
              let firstFolded = term.firstToken(viewMode: .sourceAccurate),
              let firstToken = Comparison.token(
                  at: firstFolded.positionAfterSkippingLeadingTrivia,
                  from: foldedSequence,
                  in: parentSequence
              )
        else { return nil }
        self.sequence = parentSequence
        self.folded = foldedSequence
        self.coalescing = term
        self.first = firstToken

        let removed = firstToken.positionAfterSkippingLeadingTrivia..<node.operator.endPositionBeforeTrailingTrivia
        guard !parentSequence.dropsAClosuresArgument(removing: removed),
              !leavesAMarkerOverNothing(withOperator: node, at: token),
              !(fallback.takesItsTypeFromItsContext && isTheWholeValueOfAPlaceThatGivesNoType),
              !assignsItsTargetToItself
        else { return nil }
    }

    /// The term that is the whole of `value`, inside any parentheses, `try` and `await`, as ReplaceReturnValue and
    /// ReplaceBooleanValue see a value, or nil when there is none or it gets no mutant.
    init?(wholeOf value: ExprSyntax) {
        var expression = value
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
        guard let parentSequence = expression.as(SequenceExprSyntax.self),
              let foldedSequence = try? OperatorTable.standardOperators.foldSingle(parentSequence)
        else { return nil }
        var root = foldedSequence
        while let marked = root.markedExpression, !root.is(UnsafeExprSyntax.self),
              root.as(TryExprSyntax.self)?.questionOrExclamationMark?.text != "?" {
            root = marked
        }
        guard let operatorToken = root.as(InfixOperatorExprSyntax.self)?.operator
            .as(BinaryOperatorExprSyntax.self)?.operator,
            let token = Comparison.token(
                at: operatorToken.positionAfterSkippingLeadingTrivia,
                from: foldedSequence,
                in: parentSequence
            ),
            let node = token.parent?.as(BinaryOperatorExprSyntax.self)
        else { return nil }
        self.init(withOperator: node)
    }

    /// Whether the file `root` is declares a `??` of its own, as an overload on a binding or a query type, which any
    /// `??` in it may be: the code doesn't say which, and the overload's fallback needn't be what it gives. Walked with
    /// a loop, not recursion, so a deep tree can't run out of a discovery thread's stack.
    static func isDeclared(in root: Syntax) -> Bool {
        var stack: [Syntax] = [root]
        while let node = stack.popLast() {
            if node.as(FunctionDeclSyntax.self)?.name.text == "??" {
                return true
            }
            stack.append(contentsOf: node.children(viewMode: .sourceAccurate))
        }
        return false
    }

    /// What it replaces, on one line: the whole term.
    var before: String {
        coalescing.trimmedDescription.inlined
    }

    /// What takes its place, on one line, in the parentheses the mutant puts it in: `(-1)` for `x=a ?? -1`. The space
    /// that keeps it off a name isn't part of it.
    var after: String {
        replacement.trimmedDescription.inlined
    }

    /// The sequence with the fallback in place of the term (`replacement`).
    func mutated() -> ExprSyntax {
        Replacing(coalescing.id, with: replacement).rewrite(folded).cast(ExprSyntax.self)
    }

    /// The fallback as it takes the term's place, with the term's trivia: a `//` comment after it stays a comment. A
    /// space keeps it apart from a name or keyword it would otherwise touch, as in `return(a) ?? b`, and parentheses
    /// from an operator it would join, as in `x=a ?? -1`, where `=-` is one, or that an implicit member would follow,
    /// as in `x=a ?? .low`, where `=.` is.
    private var replacement: ExprSyntax {
        let previous = coalescing.previousToken(viewMode: .sourceAccurate)
            ?? sequence.previousToken(viewMode: .sourceAccurate)
        let touchesThePrevious = coalescing.leadingTrivia.isEmpty && previous?.trailingTrivia.isEmpty == true
        let inPlace = fallback.with(\.leadingTrivia, coalescing.leadingTrivia)
        guard touchesThePrevious,
              let previousCharacter = previous?.text.last,
              let fallbackCharacter = fallback.firstToken(viewMode: .sourceAccurate)?.text.first
        else { return inPlace }
        if previousCharacter.isPartOfAName, fallbackCharacter.isPartOfAName {
            return inPlace.with(\.leadingTrivia, .space)
        }
        if Self.operatorCharacters.contains(previousCharacter),
           Self.operatorCharacters.contains(fallbackCharacter) || fallbackCharacter == "." {
            return ExprSyntax(TupleExprSyntax(
                leftParen: .leftParenToken(),
                elements: LabeledExprListSyntax([LabeledExprSyntax(expression: fallback.trimmed)]),
                rightParen: .rightParenToken(trailingTrivia: fallback.trailingTrivia)
            ))
        }
        return inPlace
    }

    /// Whether a `try`, `try?`, `try!`, `await` or `unsafe` over the term would cover no call, subscript, macro or
    /// member once the left side is gone, which the compiler warns of, and a build with warnings as errors fails on:
    /// `try load() ?? 0` as `try 0`. An `await` can't count the fallback's either, as it was in the `??`'s
    /// autoclosure, which can't wait: `await load() ?? backup()` as `await backup()` warns too. One the fold hoisted
    /// over the term, as from `try a() ?? b`, is checked in the folded tree, where `operatorToken` is the `??`; one
    /// around the whole sequence, as in `try (a() ?? b)`, in the file's, where `coalescingOperator` is.
    private func leavesAMarkerOverNothing(
        withOperator coalescingOperator: BinaryOperatorExprSyntax,
        at operatorToken: TokenSyntax
    ) -> Bool {
        let start = coalescing.positionAfterSkippingLeadingTrivia
        let left = start..<operatorToken.endPositionBeforeTrailingTrivia
        let term = start..<coalescing.endPositionBeforeTrailingTrivia
        var walked = Syntax(coalescing)
        while walked.id != folded.id, let parent = walked.parent {
            if let marked = parent.as(ExprSyntax.self)?.markedExpression,
               !marked.holdsACallOrMember(outside: parent.is(AwaitExprSyntax.self) ? term : left) {
                return true
            }
            walked = parent
        }
        let startInFile = first.positionAfterSkippingLeadingTrivia
        let leftInFile = startInFile..<coalescingOperator.operator.endPositionBeforeTrailingTrivia
        guard let last = coalescing.lastToken(viewMode: .sourceAccurate),
              let lastInFile = Comparison.token(at: last.positionAfterSkippingLeadingTrivia, from: folded, in: sequence)
        else { return true }
        let termInFile = startInFile..<lastInFile.endPositionBeforeTrailingTrivia
        walked = Syntax(sequence)
        // The element of an enclosing sequence that holds the term, as `(a() ?? 0)` in `try 1 + (a() ?? 0)`.
        var element = walked
        while let parent = walked.parent, !parent.endsTheReachOfAMarker {
            if let marked = parent.as(ExprSyntax.self)?.markedExpression,
               !marked.holdsACallOrMember(outside: parent.is(AwaitExprSyntax.self) ? termInFile : leftInFile) {
                return true
            }
            if parent.is(ExprListSyntax.self) {
                element = walked
            } else if let outer = parent.as(SequenceExprSyntax.self),
                      Self.hoistsAMarkerOverNothing(in: outer, over: element, left: leftInFile, term: termInFile) {
                return true
            }
            walked = parent
        }
        return false
    }

    /// Whether folding `outer`, a sequence that holds the term in its `element`, hoists a `try`, `await` or `unsafe`
    /// over `element` that would cover no call, subscript, macro or member once the left side is gone: in
    /// `try 1 + (a() ?? 0)` the `try` is written over `1`, and the fold puts it over the whole sum. `left` and `term`
    /// are the left side's and the term's places in the file.
    private static func hoistsAMarkerOverNothing(
        in outer: SequenceExprSyntax,
        over element: Syntax,
        left: Range<AbsolutePosition>,
        term: Range<AbsolutePosition>
    ) -> Bool {
        guard let foldedOuter = try? OperatorTable.standardOperators.foldSingle(outer),
              let elementsFirst = element.firstToken(viewMode: .sourceAccurate),
              let token = Comparison.token(
                  at: elementsFirst.positionAfterSkippingLeadingTrivia,
                  from: outer,
                  in: foldedOuter
              )
        else { return false }
        // The folded tree holds the same tokens at the same offsets from its start.
        let inFolded = { (position: AbsolutePosition) in
            foldedOuter.position.advanced(by: outer.position.distance(to: position))
        }
        let start = inFolded(element.positionAfterSkippingLeadingTrivia)
        let end = inFolded(element.endPositionBeforeTrailingTrivia)
        var node = Syntax(token)
        while node.positionAfterSkippingLeadingTrivia != start || node.endPositionBeforeTrailingTrivia != end {
            guard let parent = node.parent else { return false }
            node = parent
        }
        let leftInFolded = inFolded(left.lowerBound)..<inFolded(left.upperBound)
        let termInFolded = inFolded(term.lowerBound)..<inFolded(term.upperBound)
        while node.id != foldedOuter.id, let parent = node.parent {
            if let marked = parent.as(ExprSyntax.self)?.markedExpression,
               !marked.holdsACallOrMember(outside: parent.is(AwaitExprSyntax.self) ? termInFolded : leftInFolded) {
                return true
            }
            node = parent
        }
        return false
    }
}
