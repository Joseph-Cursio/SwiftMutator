import SwiftSyntax

// The shapes `NilCoalescing` reads to tell whether a mutant would build.

extension Syntax {
    /// Whether the nearest closure or declaration around this is a closure that writes no return type, so what a
    /// `return` in it gives decides its type.
    var isInAClosureThatWritesNoReturnType: Bool {
        var node = parent
        while let current = node {
            if let closure = current.as(ClosureExprSyntax.self) {
                return closure.signature?.returnClause == nil
            }
            if current.isProtocol(DeclSyntaxProtocol.self) {
                return false
            }
            node = current.parent
        }
        return false
    }

    /// Whether a `try`, `await` or `unsafe` above this covers nothing in it: a closure has its own, and a statement or
    /// declaration is past any expression's.
    var endsTheReachOfAMarker: Bool {
        `is`(ClosureExprSyntax.self) || `is`(CodeBlockItemSyntax.self) || isProtocol(StmtSyntaxProtocol.self)
            || isProtocol(DeclSyntaxProtocol.self)
    }
}

extension ExprSyntax {
    /// Whether this needs its type from where it is, as Swift can't tell it from the expression alone, or would
    /// give it a default that needn't be the left side's, inside any parentheses and prefix operators: `nil`, a
    /// number, string or regex literal, an array or dictionary literal, a closure, an implicit member such as `.zero`
    /// or `.init()`, and operators between such terms, as in `0 + 1`. `true` and `false` are always Bools.
    var takesItsTypeFromItsContext: Bool {
        if let tuple = self.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first,
           only.label == nil {
            return only.expression.takesItsTypeFromItsContext
        }
        if let prefix = self.as(PrefixOperatorExprSyntax.self) {
            return prefix.expression.takesItsTypeFromItsContext
        }
        if let infix = self.as(InfixOperatorExprSyntax.self) {
            return infix.operator.is(BinaryOperatorExprSyntax.self) && infix.leftOperand.takesItsTypeFromItsContext
                && infix.rightOperand.takesItsTypeFromItsContext
        }
        if let sequence = self.as(SequenceExprSyntax.self) {
            return sequence.elements.allSatisfy { element in
                element.is(BinaryOperatorExprSyntax.self) || element.takesItsTypeFromItsContext
            }
        }
        return `is`(NilLiteralExprSyntax.self) || `is`(IntegerLiteralExprSyntax.self)
            || `is`(FloatLiteralExprSyntax.self) || `is`(StringLiteralExprSyntax.self)
            || `is`(RegexLiteralExprSyntax.self) || `is`(ArrayExprSyntax.self) || `is`(DictionaryExprSyntax.self)
            || `is`(ClosureExprSyntax.self) || isRootedInAnImplicitMember
    }

    /// What this names, inside any parentheses, when it is one of the two shapes Swift won't assign to themselves: a
    /// variable, as `one`, or `self`'s property, as `self.one`. Nil for anything else, as `b.v`, a call or a subscript.
    var selfAssignedName: String? {
        if let tuple = self.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first,
           only.label == nil {
            return only.expression.selfAssignedName
        }
        if let reference = self.as(DeclReferenceExprSyntax.self), reference.argumentNames == nil,
           reference.baseName.tokenKind != .keyword(.self) {
            return reference.baseName.plainName
        }
        if let member = self.as(MemberAccessExprSyntax.self), member.declName.argumentNames == nil,
           member.base?.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind == .keyword(.self) {
            return "self." + member.declName.baseName.plainName
        }
        return nil
    }

    /// Whether Swift can't give this a type alone, inside any parentheses: `nil`, an empty array or dictionary
    /// literal, an implicit member such as `.zero`, or a closure. A number or string literal, or one with elements,
    /// has a default type of its own.
    var hasNoTypeOfItsOwn: Bool {
        if let tuple = self.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first,
           only.label == nil {
            return only.expression.hasNoTypeOfItsOwn
        }
        if let array = self.as(ArrayExprSyntax.self) {
            return array.elements.isEmpty
        }
        if let dictionary = self.as(DictionaryExprSyntax.self), case .colon = dictionary.content {
            return true
        }
        return `is`(NilLiteralExprSyntax.self) || `is`(ClosureExprSyntax.self) || isRootedInAnImplicitMember
    }

    /// Whether this is an implicit member, as `.zero`, or a call, subscript or member of one, as `.init(1)` or
    /// `.make().value`.
    var isRootedInAnImplicitMember: Bool {
        var expression = self
        while true {
            if let member = expression.as(MemberAccessExprSyntax.self) {
                guard let base = member.base else { return true }
                expression = base
            } else if let call = expression.as(FunctionCallExprSyntax.self) {
                expression = call.calledExpression
            } else if let subscriptCall = expression.as(SubscriptCallExprSyntax.self) {
                expression = subscriptCall.calledExpression
            } else if let unwrap = expression.as(ForceUnwrapExprSyntax.self) {
                expression = unwrap.expression
            } else if let chain = expression.as(OptionalChainingExprSyntax.self) {
                expression = chain.expression
            } else if let postfix = expression.as(PostfixOperatorExprSyntax.self) {
                expression = postfix.expression
            } else {
                return false
            }
        }
    }

    /// Whether this holds a call, a subscript, a macro or a member with a base, which may throw or wait, that isn't
    /// all inside `removed`.
    func holdsACallOrMember(outside removed: Range<AbsolutePosition>) -> Bool {
        var stack: [Syntax] = [Syntax(self)]
        while let node = stack.popLast() {
            let mayThrowOrWait = node.is(FunctionCallExprSyntax.self) || node.is(SubscriptCallExprSyntax.self)
                || node.is(MacroExpansionExprSyntax.self) || node.as(MemberAccessExprSyntax.self)?.base != nil
            let isRemoved = removed.lowerBound <= node.positionAfterSkippingLeadingTrivia
                && node.endPositionBeforeTrailingTrivia <= removed.upperBound
            if mayThrowOrWait, !isRemoved {
                return true
            }
            stack.append(contentsOf: node.children(viewMode: .sourceAccurate))
        }
        return false
    }
}
