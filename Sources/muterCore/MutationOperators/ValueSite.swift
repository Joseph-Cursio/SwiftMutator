import SwiftOperators
import SwiftSyntax

/// Where a value is one that a caller or a later line reads: what a body returns, or a binding's initial value.
/// ReplaceBooleanValue and ReplaceReturnValue find their values here, so they agree on what a body returns.
struct ValueSite {
    enum Kind {
        /// The value of a `return`.
        case returned
        /// The one expression of a body, which the body returns.
        case onlyExpression
        /// The initial value of a `let` or `var` of one name.
        case initialValue
    }

    let kind: Kind
    /// The type written for the value: the return type of what returns it, or the binding's annotation. Nil when the
    /// binding has none.
    let writtenType: TypeSyntax?
    /// What returns the value: a function, a closure, an accessor or a getter's statements. Nil for a binding's.
    let owner: Syntax?
}

extension ExprSyntax {
    /// Where this value is one of the sites, or nil: the value of a `return`, or the one expression of a body, of a
    /// function, a getter or a closure whose signature writes its return type; or the initial value of a `let` or
    /// `var` of one name. A closure that leaves its type to be inferred is mostly a predicate passed to `filter`,
    /// `sorted` or `contains`, and is left out. So are `if let`, `guard let` and `case let`, a tuple's names, and an
    /// assignment.
    var valueSite: ValueSite? {
        guard let parent else { return nil }
        if let statement = parent.as(ReturnStmtSyntax.self) {
            guard let owner = statement.bodyItLeaves, let type = owner.writtenReturnType else { return nil }
            return ValueSite(kind: .returned, writtenType: type, owner: owner)
        }
        if let item = parent.as(CodeBlockItemSyntax.self), let list = item.parent?.as(CodeBlockItemListSyntax.self),
           list.count == 1, let owner = list.bodyOwner {
            return owner.writtenReturnType.map { ValueSite(kind: .onlyExpression, writtenType: $0, owner: owner) }
        }
        if let clause = parent.as(InitializerClauseSyntax.self),
           let binding = clause.parent?.as(PatternBindingSyntax.self),
           binding.pattern.is(IdentifierPatternSyntax.self) {
            return ValueSite(kind: .initialValue, writtenType: binding.typeAnnotation?.type, owner: nil)
        }
        return nil
    }

    /// The expression inside any parentheses, `try`, `try!` and `await` around it, with its operators folded, so that
    /// the last thing it works out is on top. `try?` makes an optional, and is kept. A sequence whose operators the
    /// standard table doesn't hold is left as it is, as their precedence isn't known.
    var withoutValueWrapping: ExprSyntax {
        var expression = self
        while true {
            if let sequence = expression.as(SequenceExprSyntax.self),
               let folded = try? OperatorTable.standardOperators.foldSingle(sequence),
               !folded.is(SequenceExprSyntax.self) {
                expression = folded
            } else if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
                      let only = tuple.elements.first, only.label == nil {
                expression = only.expression
            } else if let attempt = expression.as(TryExprSyntax.self), attempt.questionOrExclamationMark?.text != "?" {
                expression = attempt.expression
            } else if let wait = expression.as(AwaitExprSyntax.self) {
                expression = wait.expression
            } else {
                return expression
            }
        }
    }

    /// `literal` in place of this value, with the trivia on either side of it left outside: a `//` comment after the
    /// value stays a comment. A space keeps the literal apart from a name or keyword it would otherwise touch, as in
    /// `return(a < b)`, which would become `returntrue`.
    func replaced(by literal: ExprSyntax) -> ExprSyntax {
        let previous = previousToken(viewMode: .sourceAccurate)
        let next = nextToken(viewMode: .sourceAccurate)
        let touchesThePrevious = leadingTrivia.isEmpty && previous?.trailingTrivia.isEmpty == true
            && previous?.text.last.map(\.isPartOfAName) == true
        let touchesTheNext = trailingTrivia.isEmpty && next?.leadingTrivia.isEmpty == true
            && next?.text.first.map(\.isPartOfAName) == true
        return literal
            .with(\.leadingTrivia, touchesThePrevious ? .space : leadingTrivia)
            .with(\.trailingTrivia, touchesTheNext ? .space : trailingTrivia)
    }
}

extension ReturnStmtSyntax {
    /// The function, getter or closure this `return` leaves, whatever is around it: a `return` in a closure is that
    /// closure's, even one that leaves its type to be inferred.
    var bodyItLeaves: Syntax? {
        var ancestor = parent
        while let current = ancestor {
            if current.leavesOnReturn {
                return current
            }
            ancestor = current.parent
        }
        return nil
    }
}

extension CodeBlockItemListSyntax {
    /// What this list is the body of, when that is a function, an accessor or a closure, which returns its one
    /// expression; nil for any other list, as an `if`'s or a `do`'s.
    var bodyOwner: Syntax? {
        guard let parent else { return nil }
        if parent.is(ClosureExprSyntax.self) || parent.is(AccessorBlockSyntax.self) {
            return parent
        }
        guard parent.is(CodeBlockSyntax.self), let owner = parent.parent, owner.leavesOnReturn else { return nil }
        return owner
    }
}

extension Syntax {
    /// Whether a `return` inside this, and nowhere deeper, leaves this: a function, an initializer, an accessor, a
    /// getter's statements or a closure.
    var leavesOnReturn: Bool {
        `is`(FunctionDeclSyntax.self) || `is`(ClosureExprSyntax.self) || `is`(AccessorDeclSyntax.self)
            || `is`(AccessorBlockSyntax.self) || `is`(InitializerDeclSyntax.self) || `is`(DeinitializerDeclSyntax.self)
    }

    /// The return type written for this function, getter, subscript or closure. Nil for one that returns nothing, as
    /// an initializer, a setter or a `didSet` does, and for a closure that doesn't write its type.
    var writtenReturnType: TypeSyntax? {
        if let function = self.as(FunctionDeclSyntax.self) {
            return function.signature.returnClause?.type
        }
        if let closure = self.as(ClosureExprSyntax.self) {
            return closure.signature?.returnClause?.type
        }
        if let accessor = self.as(AccessorDeclSyntax.self) {
            guard accessor.accessorSpecifier.tokenKind == .keyword(.get),
                  let block = accessor.parent?.parent?.as(AccessorBlockSyntax.self)
            else { return nil }
            return block.typeOfItsValue
        }
        return self.as(AccessorBlockSyntax.self)?.typeOfItsValue
    }
}

extension AccessorBlockSyntax {
    /// The type of the property or subscript whose accessors these are.
    var typeOfItsValue: TypeSyntax? {
        if let binding = parent?.as(PatternBindingSyntax.self) {
            return binding.typeAnnotation?.type
        }
        return parent?.as(SubscriptDeclSyntax.self)?.returnClause.type
    }
}

extension Character {
    /// Whether this can be part of a name or a keyword, which a literal next to it would join.
    var isPartOfAName: Bool {
        isLetter || isNumber || self == "_" || self == "$"
    }
}
