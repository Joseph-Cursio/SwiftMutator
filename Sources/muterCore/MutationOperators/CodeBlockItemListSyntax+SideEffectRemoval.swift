import SwiftSyntax

extension CodeBlockItemListSyntax {

    /// Whether the last statement must stay: control must never reach the end, or the statement is the code's value
    /// on its own.
    var mustKeepItsLastStatement: Bool {
        mustNotFallThrough || isAValueOnItsOwn
    }

    /// Whether these are the one statement of code that returns a value, and may be that value, as a closure's
    /// `transform($0)` or a result builder's one part is. Removing it leaves no value. A closure whose type isn't
    /// written is taken to return one.
    var isAValueOnItsOwn: Bool {
        onlyStatement?.mayBeAValue == true && returnsItsValue
    }

    /// The one item that isn't a declaration of a function, a type, a macro such as `#warning`, or a `#if`, when there
    /// is one, which may be the code's value though those follow it.
    var onlyStatement: Element? {
        var found: Element?
        // A loop, as `filter` makes new nodes, whose ids aren't the list's.
        for item in self where item.item.as(DeclSyntax.self).map({ $0.is(VariableDeclSyntax.self) }) ?? true {
            guard found == nil else {
                return nil
            }
            found = item
        }
        return found
    }

    /// Whether these statements' code returns a value that a statement of theirs may be: a closure whose return type
    /// isn't written or isn't `Void`, a getter, a function that returns a value, or a branch of a value.
    var returnsItsValue: Bool {
        guard let parent else {
            return false
        }
        if let closure = parent.as(ClosureExprSyntax.self) {
            return closure.signature?.returnClause.map { !$0.isReturningVoid } ?? true
        }
        if parent.is(AccessorBlockSyntax.self) {
            return true
        }
        let blockOwner = parent.as(CodeBlockSyntax.self)?.parent
        if let function = blockOwner?.as(FunctionDeclSyntax.self) {
            return function.signature.returnClause.map { !$0.isReturningVoid } ?? false
        }
        return blockOwner?.as(AccessorDeclSyntax.self)?.accessorSpecifier.tokenKind == .keyword(.get)
            || isABranchOfAValue
    }

    /// Whether these are a branch of an `if` or `switch` that is a value: one that isn't a statement, as in
    /// `let x = if …`, or the one statement of code whose value it is, with no `return` in it.
    var isABranchOfAValue: Bool {
        guard let branching = enclosingIfOrSwitch else {
            return false
        }
        var node = branching
        let wrappers: [SyntaxProtocol.Type] = [IfExprSyntax.self, ExpressionStmtSyntax.self, LabeledStmtSyntax.self]
        while let parent = node.parent, wrappers.contains(where: { parent.is($0) }) {
            node = parent
        }
        guard let item = node.parent?.as(CodeBlockItemSyntax.self),
              var list = item.parent?.as(CodeBlockItemListSyntax.self)
        else {
            return true
        }
        guard list.onlyStatement?.id == item.id, item.mayBeAValue, !ValueReturnFinder.findsAnyReturn(in: node) else {
            return false
        }
        // A `#if` that holds only it, as around a whole body, isn't a statement of its own.
        while list.parent?.is(IfConfigClauseSyntax.self) == true,
              let ifConfig = list.parent?.parent?.parent?.parent?.as(CodeBlockItemSyntax.self),
              let outer = ifConfig.parent?.as(CodeBlockItemListSyntax.self),
              outer.allSatisfy({ $0.id == ifConfig.id || $0.item.is(MacroExpansionDeclSyntax.self) }) {
            list = outer
        }
        return list.returnsItsValue
    }

    /// The `if` whose branch these are, or the `switch` whose case.
    private var enclosingIfOrSwitch: Syntax? {
        if let ifExpr = parent?.as(CodeBlockSyntax.self)?.parent?.as(IfExprSyntax.self) {
            return Syntax(ifExpr)
        }
        var ancestor = parent?.as(SwitchCaseSyntax.self)?.parent
        while let node = ancestor {
            if node.is(SwitchExprSyntax.self) {
                return node
            }
            guard node.is(SwitchCaseListSyntax.self) || node.is(IfConfigClauseSyntax.self)
                || node.is(IfConfigClauseListSyntax.self) || node.is(IfConfigDeclSyntax.self)
            else {
                return nil
            }
            ancestor = node.parent
        }
        return nil
    }

    /// Whether these are a branch, an `if` or `else` body, a case, a `do` or a `catch` body, whose last statement may
    /// be a call that never returns which definite initialization relies on: in an initializer, or after a variable
    /// declared without a value, as `let data: Data` before `do { data = try load() } catch { die() }`. Removing it
    /// leaves a constant or a stored property unset, which doesn't compile. So may an initializer's own last
    /// statement, as a stub's `unimplemented()`, or `usage()` after an `if` that sets a property and returns.
    var mayEndInACallThatInitializationReliesOn: Bool {
        guard let parent else {
            return false
        }
        let blockOwner = parent.as(CodeBlockSyntax.self)?.parent
        if blockOwner?.is(InitializerDeclSyntax.self) == true {
            return true
        }
        guard parent.is(SwitchCaseSyntax.self) || blockOwner?.is(IfExprSyntax.self) == true
            || blockOwner?.is(CatchClauseSyntax.self) == true || blockOwner?.is(DoStmtSyntax.self) == true
        else {
            return false
        }
        var node = Syntax(self)
        while let current = node.parent {
            if current.is(InitializerDeclSyntax.self) {
                return true
            }
            if current.is(FunctionDeclSyntax.self) || current.is(ClosureExprSyntax.self)
                || current.is(AccessorDeclSyntax.self) || current.is(AccessorBlockSyntax.self)
                || current.is(DeinitializerDeclSyntax.self) {
                return false
            }
            if let item = current.as(CodeBlockItemSyntax.self),
               let list = item.parent?.as(CodeBlockItemListSyntax.self),
               list.prefix(while: { $0.id != item.id }).contains(where: \.declaresAVariableWithoutAValue) {
                return true
            }
            node = current
        }
        return false
    }

    /// The last item but a declaration of a function or a type, which can follow the code that ends a block, or a
    /// `#if`. A `#if` may end the code in one build and not in another, as `#if os(Linux) flush() #endif` after a
    /// call that never returns does, so the statement before it is kept too.
    var lastStatement: Element? {
        last(countingIfConfigs: false)
    }

    /// The last item but a declaration of a function or a type, and of a `#if` unless `countingIfConfigs`.
    func last(countingIfConfigs: Bool) -> Element? {
        last { item in
            guard let declaration = item.item.as(DeclSyntax.self) else {
                return true
            }
            return declaration.is(VariableDeclSyntax.self)
                || countingIfConfigs && declaration.is(IfConfigDeclSyntax.self)
        }
    }

    /// Whether control must never reach the end of these statements: those of a `guard` body; of a function or a
    /// getter that returns a value, `Never` included, but for a result builder's, each of whose statements is a part of
    /// its value, which is taken to be one marked `@…Builder` or of a `some` type, with no `return` of a value; of a
    /// closure declared to return a
    /// value, or whose type isn't written but which returns one; and of a `do` or `catch` body, an `if` or `else`
    /// branch, a `switch` case or a `#if` clause that ends one of those, or of an `if` or `switch` that is a value. A
    /// closure whose type isn't written and that returns nothing, and a `repeat` body, which can end in its condition,
    /// are taken to fall through.
    var mustNotFallThrough: Bool {
        guard let parent else {
            return false
        }
        if let closure = parent.as(ClosureExprSyntax.self) {
            return closure.signature?.returnClause.map { !$0.isReturningVoid }
                ?? (closure.returnsAValue || closure.isGivenAValueReturningType || closure.isCalledForItsValue)
        }
        // A `return` of a value turns a builder off.
        if parent.is(AccessorBlockSyntax.self) {
            return !Self.mayBeAResultBuilder(parent) || ValueReturnFinder.findsAValueReturn(in: Syntax(self))
        }
        if let switchCase = parent.as(SwitchCaseSyntax.self) {
            var ancestor = switchCase.parent
            while let node = ancestor, !node.is(SwitchExprSyntax.self) {
                guard node.is(SwitchCaseListSyntax.self) || node.is(IfConfigClauseSyntax.self)
                    || node.is(IfConfigClauseListSyntax.self) || node.is(IfConfigDeclSyntax.self)
                else {
                    return false
                }
                ancestor = node.parent
            }
            return ancestor.map(Self.endsCodeThatMustNotFallThrough) ?? false
        }
        if parent.is(IfConfigClauseSyntax.self) {
            return parent.parent?.parent.map(Self.endsCodeThatMustNotFallThrough) ?? false
        }
        guard let blockOwner = parent.as(CodeBlockSyntax.self)?.parent else {
            return false
        }
        if blockOwner.is(GuardStmtSyntax.self) {
            return true
        }
        if let function = blockOwner.as(FunctionDeclSyntax.self) {
            guard let returnClause = function.signature.returnClause else {
                return false
            }
            let mayBeABuilder = function.attributes.containsResultBuilder || returnClause.type.isOpaque
            return !returnClause.isReturningVoid
                && (!mayBeABuilder || ValueReturnFinder.findsAValueReturn(in: Syntax(self)))
        }
        if let accessor = blockOwner.as(AccessorDeclSyntax.self) {
            return accessor.accessorSpecifier.tokenKind == .keyword(.get)
                && (!Self.mayBeAResultBuilder(blockOwner) || ValueReturnFinder.findsAValueReturn(in: Syntax(self)))
        }
        if blockOwner.is(DoStmtSyntax.self) || blockOwner.is(IfExprSyntax.self) {
            return Self.endsCodeThatMustNotFallThrough(blockOwner)
        }
        if blockOwner.is(CatchClauseSyntax.self) {
            return blockOwner.parent?.parent.map(Self.endsCodeThatMustNotFallThrough) ?? false
        }
        return false
    }

    /// Whether `statement`, a `do`, `if`, `switch` or `#if`, is the last statement of code that must not fall
    /// through, by itself, labeled, or as the `else if` of one that is. A `#if` after it may hold nothing in this
    /// build, so `statement` is last either way.
    static func endsCodeThatMustNotFallThrough(_ statement: Syntax) -> Bool {
        var node = statement
        let wrappers: [SyntaxProtocol.Type] = [IfExprSyntax.self, ExpressionStmtSyntax.self, LabeledStmtSyntax.self]
        while let parent = node.parent, wrappers.contains(where: { parent.is($0) }) {
            node = parent
        }
        // An `if` or `switch` that isn't a statement is a value, as in `let x = if …`, each of whose branches is.
        guard let item = node.parent?.as(CodeBlockItemSyntax.self) else {
            return node.is(IfExprSyntax.self) || node.is(SwitchExprSyntax.self)
        }
        guard let list = item.parent?.as(CodeBlockItemListSyntax.self),
              [list.last(countingIfConfigs: true)?.id, list.lastStatement?.id].contains(item.id)
        else {
            return false
        }
        return list.mustKeepItsLastStatement
    }

    /// The list without `statement`, which is matched by identity rather than text, because an identical
    /// statement elsewhere in the block is a mutant of its own.
    ///
    /// The removed statement takes its leading trivia with it, and that trivia holds the line break before it.
    /// A statement after it on the same line, following a `;`, has no line break of its own. So it is given the
    /// removed statement's leading trivia: the line break, plus any comments above the line, which applied to
    /// the whole line. Without that, removing `reload();` from `prepare()` followed by `reload(); notify()`
    /// joined `notify()` to the line above. `prepare()notify()` doesn't compile, and fails the build that every
    /// mutant shares. After a `//` comment, `notify()` became part of the comment.
    func removing(_ statement: Element) -> CodeBlockItemListSyntax {
        var remaining = [Element]()
        var removedTrivia: Trivia?
        for item in self {
            if item.id == statement.id {
                removedTrivia = item.leadingTrivia
                continue
            }
            var kept = item
            if let trivia = removedTrivia, !item.leadingTrivia.contains(where: \.isNewline) {
                kept.leadingTrivia = trivia + item.leadingTrivia
            }
            removedTrivia = nil
            remaining.append(kept)
        }
        return CodeBlockItemListSyntax(remaining)
    }
}

extension CodeBlockItemSyntax {
    /// Whether the statement declares a variable or constant with no value, which code after it must give one.
    var declaresAVariableWithoutAValue: Bool {
        let bindings = item.as(VariableDeclSyntax.self)?.bindings
        return bindings?.contains { $0.initializer == nil && $0.accessorBlock == nil } ?? false
    }

    /// Whether the statement may be its code's value: an expression, or a `switch` or an `if` with an `else` all the
    /// way down whose every branch is one statement or ends in `throw`, which can be one.
    var mayBeAValue: Bool {
        guard let expression = item.as(ExpressionStmtSyntax.self)?.expression ?? item.as(ExprSyntax.self) else {
            return false
        }
        var branches: [CodeBlockItemListSyntax] = []
        if let switchExpr = expression.as(SwitchExprSyntax.self) {
            branches = switchExpr.cases.compactMap { $0.as(SwitchCaseSyntax.self)?.statements }
        } else if var ifExpr = expression.as(IfExprSyntax.self) {
            while true {
                branches.append(ifExpr.body.statements)
                switch ifExpr.elseBody {
                case let .codeBlock(block):
                    branches.append(block.statements)

                case let .ifExpr(next):
                    ifExpr = next
                    continue

                case nil:
                    return false
                }
                break
            }
        } else {
            return true
        }
        // A branch of a value is one expression, or ends in `throw`.
        return branches.allSatisfy { $0.count == 1 || $0.last?.item.is(ThrowStmtSyntax.self) == true }
    }

    /// `do {}` in the statement's place, with its line and comments, for a `switch` case it was the only statement of.
    /// It does nothing, and unlike `break` it builds in a result builder, as `SourceLocationRemover`'s does.
    var replacedByDoingNothing: CodeBlockItemSyntax {
        let doNothing = DoStmtSyntax(
            doKeyword: .keyword(.do, trailingTrivia: .space),
            body: CodeBlockSyntax(statements: [])
        )
        var replacement = CodeBlockItemSyntax(item: .stmt(StmtSyntax(doNothing)))
        replacement.leadingTrivia = leadingTrivia
        replacement.trailingTrivia = trailingTrivia
        return replacement
    }
}

extension SyntaxProtocol {
    /// The expression under any `try` and `await`, as `save()` is in `try await save()`.
    var withoutTryOrAwait: Syntax {
        var node = Syntax(self)
        while true {
            if let tryExpr = node.as(TryExprSyntax.self) {
                node = Syntax(tryExpr.expression)
            } else if let awaitExpr = node.as(AwaitExprSyntax.self) {
                node = Syntax(awaitExpr.expression)
            } else {
                return node
            }
        }
    }
}
