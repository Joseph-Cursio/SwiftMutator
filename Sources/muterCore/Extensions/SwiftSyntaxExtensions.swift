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
        let syntax = Syntax(self)
        if syntax.is(CodeBlockItemListSyntax.self) {
            return syntax.as(CodeBlockItemListSyntax.self)!
        }

        var parent = parent

        while parent?.is(CodeBlockItemListSyntax.self) == false {
            parent = parent?.parent
        }

        var list = parent!.as(CodeBlockItemListSyntax.self)!
        // `#if` is not a scope: a declaration in a clause is visible after `#endif`. Switching the
        // clause's own statements would put it inside the switch's `if` block, out of reach of the code
        // after `#endif`, so such a clause's mutants are switched in the list around the `#if`.
        while list.parent?.is(IfConfigClauseSyntax.self) == true,
              list.containsDeclaration,
              let enclosing = list.enclosingListOfIfConfig {
            list = enclosing
        }
        return list
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
        var result: [Element] = []

        for el in self {
            result.append(el)
        }

        return result
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
