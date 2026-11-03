import SwiftSyntax

extension SyntaxProtocol {
    var escapedDescription: String {
        description.replacingOccurrences(
            of: "\n",
            with: "\\n"
        )
        .replacingOccurrences(
            of: "\"",
            with: "\\\""
        )
    }

    var codeBlockItemListSyntax: CodeBlockItemListSyntax {
        // A source file's statements are a list, so every node in a file is in one.
        guard var list = ancestorOrSelf(mapping: { $0.as(CodeBlockItemListSyntax.self) }) else {
            preconditionFailure("\(self) is in no statement list")
        }
        while true {
            // `#if` is not a scope: a declaration in a clause is visible after `#endif`. Switching the
            // clause's own statements would put it inside the switch's `if` block, out of reach of the code
            // after `#endif`, so such a clause's mutants are switched in the list around the `#if`.
            if list.parent?.is(IfConfigClauseSyntax.self) == true,
               list.containsDeclaration,
               let enclosing = list.enclosingListOfIfConfig {
                list = enclosing
                continue
            }
            // A macro expands its arguments, closures included, from their syntax: `#Predicate { $0.id == id }`
            // turns its closure's statements into an expression tree, and with them a switch's `if` and its
            // `ProcessInfo` lookup, which doesn't compile. So a list inside a macro's arguments is never switched:
            // the list around the outermost macro is, and each of its branches holds the macro, with or without
            // the mutant.
            if let enclosing = list.enclosingListOutsideMacros {
                list = enclosing
                continue
            }
            return list
        }
    }

    /// Whether the statement list a mutation would be switched in cannot hold the `if` switch.
    ///
    /// A stored-property initializer has no statement list of its own, so walking up reaches the
    /// file's top level (or a top-level `#if`). Wrapping that list in an `if` moves its imports and
    /// type declarations into a local scope, which does not compile. A file-scope list of plain
    /// statements (top-level code in `main.swift` or a script) can be switched, so only a list
    /// holding a declaration is refused.
    var cannotHoldMutationSwitch: Bool {
        let list = codeBlockItemListSyntax
        return list.isFileScope
            && list.contains { Syntax($0.item).asProtocol(DeclSyntaxProtocol.self) != nil }
    }

    func appendingLeadingTrivia(
        _ pieces: TriviaPiece...
    ) -> Self {
        var trivia = leadingTrivia
        if !trivia.isEmpty {
            pieces.forEach { trivia = trivia.appending($0) }
            return withLeadingTrivia(trivia)
        } else {
            return withLeadingTrivia(Trivia(pieces: pieces))
        }
    }

    func appendingTrailingTrivia(
        _ pieces: TriviaPiece...
    ) -> Self {
        var trivia = trailingTrivia
        if !trivia.isEmpty {
            pieces.forEach { trivia = trivia.appending($0) }
            return withTrailingTrivia(trivia)
        } else {
            return withTrailingTrivia(Trivia(pieces: pieces))
        }
    }

    func withTrailingTrivia(
        _ trivia: Trivia?
    ) -> Self {
        var copy = self
        if let trivia {
            copy.trailingTrivia = trivia
        }

        return copy
    }

    func withLeadingTrivia(
        _ trivia: Trivia?
    ) -> Self {
        var copy = self
        if let trivia {
            copy.leadingTrivia = trivia
        }

        return copy
    }

    func withoutTrivia() -> Self {
        withLeadingTrivia([]).withTrailingTrivia([])
    }

    var allChildren: SyntaxChildren {
        children(viewMode: .all)
    }

    func containsLineComment(_ comment: String) -> Bool {
        leadingTrivia.containsLineComment(comment)
            || trailingTrivia.containsLineComment(comment)
    }
}

extension SyntaxChildren {
    var asArray: [Element] {
        Array(self)
    }

    func containsSyntaxKind(_ syntax: (some SyntaxProtocol).Type) -> Bool {
        asArray.containsSyntaxKind(syntax)
    }
}

extension [Syntax] {
    func containsSyntaxKind<A: SyntaxProtocol>(_ syntax: A.Type) -> Bool {
        contains { $0.is(A.self) }
    }
}

extension FunctionDeclSyntax {
    var hasImplicitReturn: Bool {
        guard let body else {
            return false
        }

        return body.statements.count == 1 &&
            signature.returnClause != nil &&
            signature.returnClause?.isReturningVoid == false
    }
}

extension ReturnClauseSyntax {
    var isReturningVoid: Bool {
        ["Void", "()"].contains(type.withoutTrivia().description.trimmed)
    }
}

extension SwiftSyntax.Trivia {
    func containsLineComment(_ comment: String) -> Bool {
        contains { piece in
            if case let .lineComment(commentText) = piece {
                return commentText.contains(comment)
            } else {
                return false
            }
        }
    }
}

extension Trivia? {
    func containsLineComment(_ comment: String) -> Bool {
        map { $0.containsLineComment(comment) } ?? false
    }
}

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

private extension CodeBlockItemListSyntax {
    /// The statement list around the outermost freestanding macro this list is in, or `nil` when it is in none.
    var enclosingListOutsideMacros: CodeBlockItemListSyntax? {
        var outermostMacro: Syntax?
        var ancestor = parent
        while let current = ancestor {
            if current.is(MacroExpansionExprSyntax.self) || current.is(MacroExpansionDeclSyntax.self) {
                outermostMacro = current
            }
            ancestor = current.parent
        }
        return outermostMacro?.parent?.ancestorOrSelf(mapping: { $0.as(CodeBlockItemListSyntax.self) })
    }

    var containsDeclaration: Bool {
        contains { Syntax($0.item).asProtocol(DeclSyntaxProtocol.self) != nil }
    }

    /// The statement list holding the `#if` this clause belongs to, or `nil` when the `#if` sits in
    /// a type's member list, where clauses hold members rather than statements.
    var enclosingListOfIfConfig: CodeBlockItemListSyntax? {
        var ancestor = parent?.parent
        while let current = ancestor {
            if current.is(MemberBlockItemListSyntax.self) {
                return nil
            }
            if let enclosing = current.as(CodeBlockItemListSyntax.self) {
                return enclosing
            }
            ancestor = current.parent
        }
        return nil
    }
}
