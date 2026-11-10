import SwiftSyntax

extension CodeBlockItemListSyntax {
    /// Whether this list is the body of a function, a getter or a closure, and its one item a macro that is the body's
    /// value, as in `func byID(_ id: String) -> Predicate<Item> { #Predicate { $0.id == id } }`. Returning it there
    /// returns what the body did. An initializer may return no value, and `return` in a `case` would leave the
    /// function, so neither is such a body.
    var isAMacroItsBodyReturns: Bool {
        guard count == 1, first?.item.is(MacroExpansionExprSyntax.self) == true, let parent else {
            return false
        }
        if parent.is(ClosureExprSyntax.self) || parent.is(AccessorBlockSyntax.self) {
            return true
        }
        guard parent.is(CodeBlockSyntax.self), let owner = parent.parent else {
            return false
        }
        if owner.is(FunctionDeclSyntax.self) {
            return true
        }
        return owner.as(AccessorDeclSyntax.self)?.accessorSpecifier.tokenKind == .keyword(.get)
    }

    /// Whether this list, of `closure` or a copy of its statements, is one expression whose switch can go in a closure
    /// called on the spot (`MutationSwitch.inAClosureCalledOnTheSpot`): one that reads none of `closure`'s anonymous
    /// arguments, `$0`, which in the new closure would be its own.
    func canBeSwitchedInAClosure(of closure: ClosureExprSyntax) -> Bool {
        guard count == 1, case .expr? = first?.item else {
            return false
        }
        return !tokens(viewMode: .sourceAccurate).contains { token in
            token.tokenKind.isDollarIdentifier && token.nearestClosure?.id == closure.id
        }
    }

    /// Whether this closure's one expression throws, outside a `try?` or a `try!`, and so the closure that switches it
    /// does.
    var throwsInItsClosure: Bool {
        tokens(viewMode: .sourceAccurate).contains { token in
            token.tokenKind == .keyword(.try) && token.parent?.as(TryExprSyntax.self)?.questionOrExclamationMark == nil
                && token.nearestClosure?.id == parent?.id
        }
    }

    /// Whether this closure's one expression awaits, and so the closure that switches it does.
    var awaitsInItsClosure: Bool {
        tokens(viewMode: .sourceAccurate).contains { token in
            token.tokenKind == .keyword(.await) && token.nearestClosure?.id == parent?.id
        }
    }

    /// The file's own top level, or a `#if` clause at the file's top level.
    var isFileScope: Bool {
        guard let parent else {
            return true
        }
        if parent.is(SourceFileSyntax.self) {
            return true
        }
        guard parent.is(IfConfigClauseSyntax.self) else {
            return false
        }
        // A `#if` clause is as file-scoped as the list its `#if` sits in.
        var ancestor = parent.parent
        while let current = ancestor {
            if current.is(MemberBlockItemListSyntax.self) {
                return false
            }
            if let enclosing = current.as(CodeBlockItemListSyntax.self) {
                return enclosing.isFileScope
            }
            ancestor = current.parent
        }
        return true
    }
}

extension TokenSyntax {
    /// The closure this token is in, nearest first.
    var nearestClosure: ClosureExprSyntax? {
        var ancestor = parent
        while let current = ancestor {
            if let closure = current.as(ClosureExprSyntax.self) {
                return closure
            }
            ancestor = current.parent
        }
        return nil
    }
}

extension TokenKind {
    var isDollarIdentifier: Bool {
        if case .dollarIdentifier = self { true } else { false }
    }
}
