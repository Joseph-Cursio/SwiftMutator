import SwiftSyntax

// Where a term is, which decides whether its fallback alone would build there.
extension NilCoalescing {
    /// Whether the term is the whole value assigned to what its fallback names, as in `one = other.one ?? one`, a
    /// merge's way to keep what it had. As `one = one` that doesn't compile: Swift won't assign a variable to itself,
    /// nor `self.one` to `self.one`. Only those two shapes, written alike on both sides, count: `self.one = one` may
    /// assign a parameter that hides the property, and `b.v = b.v`, `a.b.c = a.b.c` and a subscript may compile.
    var assignsItsTargetToItself: Bool {
        guard let kept = fallback.selfAssignedName else { return false }
        var value = ExprSyntax(coalescing)
        while let parent = value.parent?.as(ExprSyntax.self), parent.isAnEffectMarker {
            value = parent
        }
        if let assignment = value.parent?.as(InfixOperatorExprSyntax.self) {
            return assignment.operator.is(AssignmentExprSyntax.self) && assignment.rightOperand.id == value.id
                && assignment.leftOperand.selfAssignedName == kept
        }
        guard value.id == folded.id else { return false }
        // In parentheses, as in `one = (other.one ?? one)`, the assignment is in the sequence around them, which only
        // the file's tree holds.
        var written = Syntax(sequence)
        while let parent = written.parent {
            if let element = parent.as(LabeledExprSyntax.self), element.label == nil,
               let tuple = element.parent?.parent?.as(TupleExprSyntax.self), tuple.elements.count == 1 {
                written = Syntax(tuple)
            } else if parent.as(ExprSyntax.self)?.isAnEffectMarker == true {
                written = parent
            } else {
                break
            }
        }
        guard written.id != sequence.id, let terms = written.parent?.as(ExprListSyntax.self), terms.count == 3,
              terms.last?.id == written.id, terms.dropFirst().first?.is(AssignmentExprSyntax.self) == true
        else { return false }
        return terms.first?.selfAssignedName == kept
    }

    /// Whether the term is the whole value, inside any parentheses, `try`, `await` and `unsafe`, of a place that
    /// gives it no type: a `let` or `var` of one name with no type written, an `if let`, `guard let` or `while let`
    /// with none, a capture list's `[y = x ?? 0]`, what a `for` loop goes over, a member's or a subscript's base, as
    /// `(x ?? []).sorted()`, or what a closure that writes no return type gives, as its one expression or a `return`;
    /// in those two, only for a fallback with no type of its own (`hasNoTypeOfItsOwn`).
    var isTheWholeValueOfAPlaceThatGivesNoType: Bool {
        var term = ExprSyntax(coalescing)
        while term.id != folded.id {
            guard let parent = term.parent?.as(ExprSyntax.self), parent.isAnEffectMarker else { return false }
            term = parent
        }
        var value = Syntax(sequence)
        while let parent = value.parent {
            if let element = parent.as(LabeledExprSyntax.self), element.label == nil,
               let tuple = element.parent?.parent?.as(TupleExprSyntax.self), tuple.elements.count == 1 {
                value = Syntax(tuple)
            } else if parent.as(ExprSyntax.self)?.isAnEffectMarker == true {
                value = parent
            } else {
                break
            }
        }
        guard let place = value.parent else { return false }
        if let loop = place.as(ForStmtSyntax.self) {
            return loop.sequence.id == value.id
        }
        // A member's or a subscript's base, as in `(x ?? []).sorted()`, where `[].sorted()` has no element type, and
        // what a closure that writes no return type gives, as in `{ item in item.names ?? [] }`, whose type comes from
        // it. A number or string literal has a type of its own there, `Int` or `String`, so only a fallback with none
        // counts: `(name ?? "").isEmpty` and `{ item in item ?? 0 }` compile.
        if let member = place.as(MemberAccessExprSyntax.self) {
            return member.base?.id == value.id && fallback.hasNoTypeOfItsOwn
        }
        if let subscriptCall = place.as(SubscriptCallExprSyntax.self) {
            return subscriptCall.calledExpression.id == value.id && fallback.hasNoTypeOfItsOwn
        }
        if let item = place.as(CodeBlockItemSyntax.self), let items = item.parent?.as(CodeBlockItemListSyntax.self),
           items.count == 1, let closure = items.parent?.as(ClosureExprSyntax.self) {
            return closure.signature?.returnClause == nil && fallback.hasNoTypeOfItsOwn
        }
        if place.is(ReturnStmtSyntax.self) {
            return place.isInAClosureThatWritesNoReturnType && fallback.hasNoTypeOfItsOwn
        }
        guard let clause = place.as(InitializerClauseSyntax.self), let owner = clause.parent else { return false }
        if let binding = owner.as(PatternBindingSyntax.self) {
            return binding.typeAnnotation == nil && binding.pattern.is(IdentifierPatternSyntax.self)
        }
        if let condition = owner.as(OptionalBindingConditionSyntax.self) {
            return condition.typeAnnotation == nil
        }
        return owner.is(ClosureCaptureSyntax.self)
    }
}
