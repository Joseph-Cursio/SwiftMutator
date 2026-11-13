import SwiftSyntax

extension ClosureExprSyntax {
    /// What the closure is passed to, as a trailing closure or an argument.
    var callee: ExprSyntax? {
        var node = parent
        while let current = node {
            if let call = current.as(FunctionCallExprSyntax.self) {
                // A closure called where it's written isn't passed to anything.
                return call.calledExpression.id == id ? nil : call.calledExpression
            }
            guard current.is(LabeledExprSyntax.self) || current.is(LabeledExprListSyntax.self)
                || current.is(MultipleTrailingClosureElementSyntax.self)
                || current.is(MultipleTrailingClosureElementListSyntax.self)
            else {
                return nil
            }
            node = current.parent
        }
        return nil
    }

    /// Whether the closure is a variable's value, of a function type written to return one, as in
    /// `let make: () -> Int = { … }`.
    var isGivenAValueReturningType: Bool {
        guard var type = parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self)?
            .typeAnnotation?.type
        else {
            return false
        }
        while true {
            if let attributed = type.as(AttributedTypeSyntax.self) {
                type = attributed.baseType
            } else if let optional = type.as(OptionalTypeSyntax.self) {
                type = optional.wrappedType
            } else if let unwrapped = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
                type = unwrapped.wrappedType
            } else if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1,
                      let only = tuple.elements.first {
                type = only.type
            } else {
                break
            }
        }
        return type.as(FunctionTypeSyntax.self).map { !$0.returnClause.isReturningVoid } ?? false
    }

    /// Whether the closure is called where it's written, for a value something uses, as in `let value = { … }()`, but
    /// not `try { … }()` or `_ = { … }()` as a statement.
    var isCalledForItsValue: Bool {
        guard let call = parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == id else {
            return false
        }
        var node = Syntax(call)
        while let parent = node.parent,
              parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) || parent.is(UnsafeExprSyntax.self) {
            node = parent
        }
        if let sequence = node.parent?.parent?.as(SequenceExprSyntax.self),
           sequence.elements.first?.is(DiscardAssignmentExprSyntax.self) == true {
            node = Syntax(sequence)
        }
        return node.parent?.is(CodeBlockItemSyntax.self) != true
    }

    /// Whether a `return` of the closure's own gives a value, not one in a closure, function or type inside it.
    var returnsAValue: Bool {
        let finder = ValueReturnFinder(viewMode: .sourceAccurate)
        finder.walk(statements)
        return finder.found
    }
}
