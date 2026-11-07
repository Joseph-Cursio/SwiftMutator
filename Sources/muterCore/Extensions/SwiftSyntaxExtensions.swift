import SwiftSyntax

/// The code a mutant's switch holds a copy of in each branch.
enum MutationSwitchPlace {
    /// A statement list, the place for all but the code below.
    case statements(CodeBlockItemListSyntax)
    /// One statement of a list at a file's top level that holds a declaration.
    case statement(CodeBlockItemSyntax)
    /// A stored property's or a global's initial value, or a default argument.
    case initialValue(ExprSyntax)

    var code: any SyntaxProtocol {
        switch self {
        case let .statements(list): list
        case let .statement(statement): statement
        case let .initialValue(value): value
        }
    }
}

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
            // A closure holding an `if` no longer has one expression, so its result is no longer worked out together
            // with the code around it. In `let base = parent.map { path(of: $0, depth: depth + 1) } ?? root`, that
            // settles `??` on a `String` before reading the closure, whose `String?` then doesn't fit. Around the
            // whole statement, the closure stays as it was.
            if let enclosing = list.enclosingListOutsideACoalescedClosure {
                list = enclosing
                continue
            }
            return list
        }
    }

    /// Where the switch of a mutant of this code goes, or nil when it has nowhere to go.
    ///
    /// That is the nearest statement list, but for a list at a file's top level that holds a declaration: wrapping it
    /// in an `if` moves its imports and types into a local scope, which doesn't compile. A stored property's initial
    /// value and a default argument have no statement list of their own, so walking up from them reaches such a list,
    /// and so does a statement in a `main.swift` with an `import`. The switch then goes around the value, or the
    /// statement, alone. What is left has no such place: a macro alone at a file's or a type's top level, an
    /// attribute's arguments, a `guard let` or `guard case` at the top level, and the two values
    /// `InitializerClauseSyntax.canHoldASwitch` refuses.
    var mutationSwitchPlace: MutationSwitchPlace? {
        let list = codeBlockItemListSyntax
        guard list.isFileScope, list.containsDeclaration else {
            return .statements(list)
        }
        // A macro expands its arguments from their syntax, so the switch has to go around the outermost one, and
        // around a closure that `codeBlockItemListSyntax` moved it out of.
        var outermost = Syntax(self)
        var ancestor: Syntax? = outermost
        while let current = ancestor {
            if current.is(MacroExpansionExprSyntax.self) || current.is(MacroExpansionDeclSyntax.self)
                || current.as(ClosureExprSyntax.self)?.statements.enclosingListOutsideACoalescedClosure != nil {
                outermost = current
            }
            ancestor = current.parent
        }
        ancestor = outermost
        while let current = ancestor {
            if let clause = current.as(InitializerClauseSyntax.self), clause.isADeclarationsValue {
                return clause.canHoldASwitch ? .initialValue(clause.value) : nil
            }
            if let statement = current.as(CodeBlockItemSyntax.self) {
                return statement.declaresNothingAfterIt ? .statement(statement) : nil
            }
            ancestor = current.parent
        }
        return nil
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
    /// Whether the type is `Void`, however it's written: `()`, `Swift.Void` or `(Void)` too.
    var isReturningVoid: Bool {
        var text = type.trimmedDescription.filter { !$0.isWhitespace }
        while text.count > 2, text.hasPrefix("("), text.hasSuffix(")") {
            text = String(text.dropFirst().dropLast())
        }
        return ["Void", "Swift.Void", "()"].contains(text)
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

    /// The statement list around the code when this list is the one statement of a closure on the left of a `??`, or
    /// of a closure that is itself that statement.
    var enclosingListOutsideACoalescedClosure: CodeBlockItemListSyntax? {
        guard count == 1, let closure = parent?.as(ClosureExprSyntax.self) else { return nil }
        var node = Syntax(closure)
        while let current = node.parent {
            if let outer = current.as(CodeBlockItemListSyntax.self) {
                return outer.enclosingListOutsideACoalescedClosure
            }
            if let elements = current.as(ExprListSyntax.self) {
                return elements.isCoalescing(node) ? current.ancestorOrSelf(mapping: { $0.as(Self.self) }) : nil
            }
            node = current
        }
        return nil
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

private extension ExprListSyntax {
    /// Whether `element` is followed by a `??`.
    func isCoalescing(_ element: Syntax) -> Bool {
        guard let index = firstIndex(where: { Syntax($0).id == element.id }) else { return false }
        let next = self.index(after: index)
        return next < endIndex && self[next].as(BinaryOperatorExprSyntax.self)?.operator.text == "??"
    }
}

extension InitializerClauseSyntax {
    /// Whether this is a `let` or `var`'s value or a parameter's default. Not an `if let`'s or an `if case`'s value,
    /// which belongs to its statement, nor an enum case's raw value, which has to be a literal.
    var isADeclarationsValue: Bool {
        parent?.is(PatternBindingSyntax.self) == true || isADefaultArgument
    }

    /// A default argument can't be an `if` expression, which the compiler allows only as a statement's value.
    var isADefaultArgument: Bool {
        parent?.is(FunctionParameterSyntax.self) == true || parent?.is(EnumCaseParameterSyntax.self) == true
    }

    /// Whether this value, or a type around it, has an attribute. The attribute can be a macro that copies the value
    /// into a call, as `@State`, `@TaskLocal` and `@Model` do, where an `if` expression doesn't compile.
    var isUnderAnAttribute: Bool {
        var ancestor = parent
        while let current = ancestor {
            if let declaration = current.asProtocol(WithAttributesSyntax.self), !declaration.attributes.isEmpty {
                return true
            }
            ancestor = current.parent
        }
        return false
    }

    /// A branch that starts with `#line` is read as the old form of `#sourceLocation`, and the result of a closure
    /// called on the spot can't be converted to a parameter's non-escaping function type.
    var canHoldASwitch: Bool {
        !value.trimmedDescription.hasPrefix("#line") && !isTheDefaultOfANonEscapingFunction
    }

    /// `() -> Int = …`. An `@escaping` one can take a closure's result, and an `@autoclosure` one's default is its
    /// value.
    private var isTheDefaultOfANonEscapingFunction: Bool {
        guard var type = parent?.as(FunctionParameterSyntax.self)?.type else { return false }
        while let attributed = type.as(AttributedTypeSyntax.self) {
            let names = attributed.attributes.compactMap {
                $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription
            }
            if names.contains("escaping") || names.contains("autoclosure") { return false }
            type = attributed.baseType
        }
        return type.is(FunctionTypeSyntax.self)
    }
}

extension CodeBlockItemSyntax {
    /// Whether the `if` of a switch can go around this statement, as it declares nothing the code after it could use.
    /// A `guard let` or `guard case` might, and a macro alone, such as `#Preview`, can declare anything; a macro inside
    /// a statement yields a value.
    var declaresNothingAfterIt: Bool {
        switch item {
        case .decl:
            return false
        case let .expr(expression):
            return !expression.is(MacroExpansionExprSyntax.self)
        case let .stmt(statement):
            guard let guardStatement = statement.as(GuardStmtSyntax.self) else { return true }
            return guardStatement.conditions.allSatisfy { element in
                switch element.condition {
                case .optionalBinding, .matchingPattern: false
                default: true
                }
            }
        }
    }
}
