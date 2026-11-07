import Foundation
import SwiftSyntax

enum RemoveSideEffectsOperator {
    final class Visitor: MuterVisitor {
        /// The file's variables and properties that hold a lock, by name.
        private var lockNames = Set<String>()

        /// The calls a statement is never removed for, whatever `excludeCalls` adds. Each is matched by the name it's
        /// called by, as `name(_:matchesAnyOf:)` says. The assertions are here because tests rarely take their
        /// failing path, so removing one nearly always survives.
        static let alwaysExcludedCalls = [
            "print",
            "debugPrint",
            "fatalError",
            "preconditionFailure",
            "precondition",
            "assert",
            "assertionFailure",
            "exit",
            "abort",
        ]

        /// The types whose calls take, release or wait for a lock. Removing one can leave a later call waiting for
        /// good, which ends as a timeout, or release a lock that wasn't taken. `Mutex` isn't one: it's used only
        /// through `withLock`, and removing that call removes the work, but leaves no lock taken.
        static let lockTypes = [
            "DispatchSemaphore",
            "DispatchGroup",
            "NSLock",
            "NSRecursiveLock",
            "NSCondition",
            "NSConditionLock",
            "OSAllocatedUnfairLock",
        ]

        /// The functions that take or release the lock passed to them.
        static let lockFunctions = [
            "os_unfair_lock_lock",
            "os_unfair_lock_unlock",
            "pthread_mutex_lock",
            "pthread_mutex_unlock",
        ]

        private lazy var untestedFunctionNames: [String] = Self.alwaysExcludedCalls
            + Self.lockFunctions
            + (configuration?.excludeCallList ?? [])

        convenience init(
            configuration: MuterConfiguration? = nil,
            sourceCodeInfo: SourceCodeInfo,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                configuration: configuration,
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .removeSideEffects,
                coverage: coverage
            )
        }

        /// Finds the file's locks before any call on them, which can come first, as in a type that declares its
        /// properties at its end.
        override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
            let kind = super.visit(node)
            for lock in LockCollector.locks(in: node, ofTypes: Self.lockTypes) {
                // A lock made in code the tests never ran has no uses that ran. A type's property is made by code of
                // its own, with each instance, though the code that declares the type never ran. A property whose
                // value an initializer sets, or a parameter, is known by its type alone.
                if let value = lock.value, !hasTestCoverage(value) {
                    continue
                }
                lockNames.insert(lock.name)
            }

            return kind
        }

        override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
            removeSideEffectAt(node.body)

            return super.visit(node)
        }

        override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
            removeSideEffectAt(node.body)

            return super.visit(node)
        }

        override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
            removeSideEffectAt(node.body)

            return super.visit(node)
        }

        override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
            removeSideEffectAt(node.body)

            return super.visit(node)
        }

        override func visit(_ node: DoStmtSyntax) -> SyntaxVisitorContinueKind {
            removeSideEffectAt(node.body)

            return super.visit(node)
        }

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            guard let body = node.body,
                  !node.hasImplicitReturn,
                  !containsNodesThatWillBeVisited(body)
            else {
                return super.visit(node)
            }

            removeSideEffectAt(body)

            return super.visit(node)
        }

        private func removeSideEffectAt(_ body: CodeBlockSyntax) {
            let statements = body.statements
            // Only a call that never returns, such as a project's own `usage()`, which the deny-list can't know of,
            // can end code that control must never reach the end of. Removing it leaves code that falls through,
            // which doesn't compile, and fails the build every mutant shares.
            let keptStatement = statements.mustNotFallThrough ? statements.lastStatement : nil
            for statement in body.statements where statementContainsMutableToken(statement) {
                if statement.id == keptStatement?.id {
                    continue
                }
                let newCodeBlockItemList = statements.removing(statement)

                let position = endLocation(for: statement)
                let snapshot = MutationOperator.Snapshot(
                    before: statement.description.trimmed.inlined,
                    after: "removed line",
                    description: "removed line"
                )

                checkNodeForDisableTag(statement)

                add(
                    mutation: newCodeBlockItemList,
                    with: statements,
                    at: position,
                    snapshot: snapshot,
                    changing: statement
                )
            }
        }

        private func statementContainsMutableToken(_ statement: CodeBlockItemListSyntax.Element) -> Bool {
            let doesntContainVariableAssignment = doesntContainVariableAssignment(statement.allChildren)
            let containsDiscardedResult = discardsAResult(statement)
            let containsFunctionCall = statement.item.is(FunctionCallExprSyntax.self)

            let found = CallCollector(viewMode: .sourceAccurate)
            found.walk(statement)
            let callsNothingItMustKeep = !found.names.contains { Self.name($0, matchesAnyOf: untestedFunctionNames) }
                && !found.calls.contains(where: isCallOnALock)
                && !found.references.contains { isOnALock($0, methods: Self.lockMethods) }

            return doesntContainVariableAssignment
                && callsNothingItMustKeep
                && (containsDiscardedResult || containsFunctionCall)
        }

        /// `_ = expr` or `let _ = expr`: a statement whose only effect is evaluating `expr`.
        ///
        /// Read from the syntax tree, never the text. Searching the statement's description for `_ = `
        /// also matched string literals, so `let body = "_ = \(x)"` was removed and every later use of
        /// `body` failed to compile, which breaks the single build all mutants share.
        private func discardsAResult(_ statement: CodeBlockItemListSyntax.Element) -> Bool {
            let item = Syntax(statement.item)
            if let sequence = item.as(SequenceExprSyntax.self) {
                let elements = Array(sequence.elements)
                return elements.count >= 3
                    && elements[0].is(DiscardAssignmentExprSyntax.self)
                    && elements[1].is(AssignmentExprSyntax.self)
            }
            if let infix = item.as(InfixOperatorExprSyntax.self) {
                return infix.leftOperand.is(DiscardAssignmentExprSyntax.self)
                    && infix.operator.is(AssignmentExprSyntax.self)
            }
            if let declaration = item.as(VariableDeclSyntax.self),
               declaration.bindings.count == 1,
               let binding = declaration.bindings.first {
                return binding.pattern.is(WildcardPatternSyntax.self) && binding.initializer != nil
            }
            return false
        }

        private func doesntContainVariableAssignment(_ children: SyntaxChildren) -> Bool {
            let childrenAssignment = children.count(variableAssignmentStatements) == 0
            let doStatementAssignment = filterDoStatement(children).count(variableAssignmentStatements) == 0

            return childrenAssignment || doStatementAssignment
        }

        private func filterDoStatement(_ children: SyntaxChildren) -> [Syntax] {
            children
                .compactMap { $0.as(DoStmtSyntax.self) }
                .map(\.body)
                .compactMap(Syntax.init)
        }

        private func variableAssignmentStatements(_ node: Syntax) -> Bool {
            node.is(VariableDeclSyntax.self)
        }

        /// A call on one of the file's locks, as `semaphore.wait()`, `self.lock.unlock()` or `Self.lock.lock()`, but
        /// for `withLock`: removing it removes the work in it, but takes no lock.
        private func isCallOnALock(_ call: FunctionCallExprSyntax) -> Bool {
            call.calledExpression.as(MemberAccessExprSyntax.self).map(isOnALock) ?? false
        }

        /// A method of one of the file's locks, called or passed by name, as `group.leave` is to `async(execute:)`. A
        /// call is on a lock whatever its method, but `withLock`, which takes no lock that removing it leaves taken. A
        /// reference is only to one that takes, releases or waits for it, so passing `lock.name` isn't.
        private func isOnALock(_ member: MemberAccessExprSyntax) -> Bool {
            isOnALock(member, methods: nil)
        }

        private func isOnALock(_ member: MemberAccessExprSyntax, methods: Set<String>?) -> Bool {
            let method = member.declName.baseName.text
            guard let base = member.base,
                  !Self.withLockMethods.contains(method),
                  methods?.contains(method) ?? true
            else {
                return false
            }
            var parts = Self.name(of: base).split(separator: ".")
            while parts.count > 1, let first = parts.first, Self.isAQualifier(first) {
                parts.removeFirst()
            }
            return parts.count == 1 && lockNames.contains(String(parts[0]))
        }

        private static let withLockMethods: Set<String> = ["withLock", "withLockUnchecked", "withLockIfAvailable"]

        /// The lock types' methods that take, release or wait for a lock.
        private static let lockMethods: Set<String> = [
            "lock", "unlock", "try", "tryLock", "wait", "signal", "broadcast", "enter", "leave",
        ]

        /// Whether `calledName`, a call's callee or a function passed by name, is one of `names`: the name alone, or
        /// after `self.`, `Self.`, `super.` or a capitalised module or type, as `Swift.print` or `Log.debug` are. A
        /// method of a value is matched only by a name that includes the value, as `logger.debug` matches
        /// `logger.debug(…)` and `self.logger.debug(…)`, so `print` matches neither `printer.print(…)` nor
        /// `printer.flush()`. `?` and `!` play no part, nor do comments.
        static func name(_ calledName: String, matchesAnyOf names: [String]) -> Bool {
            names.contains { entry in
                let name = entry.filter { $0 != "?" && $0 != "!" && !$0.isWhitespace }
                guard calledName != name else {
                    return true
                }
                guard !name.isEmpty, calledName.hasSuffix("." + name) else {
                    return false
                }
                let qualifier = calledName.dropLast(name.count + 1)
                return !qualifier.isEmpty && qualifier.split(separator: ".", omittingEmptySubsequences: false)
                    .allSatisfy(isAQualifier)
            }
        }

        /// `self`, `Self`, `super`, or a capitalised name, a module's or a type's.
        private static func isAQualifier(_ part: Substring) -> Bool {
            ["self", "Self", "super"].contains(part)
                || part.first?.isUppercase == true && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }

        /// The expression as written, without trivia, `?` or `!`.
        static func name(of expression: some SyntaxProtocol) -> String {
            expression.tokens(viewMode: .sourceAccurate)
                .map(\.text)
                .filter { $0 != "?" && $0 != "!" }
                .joined()
        }

        // This is to avoid false positives for code block items such as do statement
        // We are going to visit them individually
        private func containsNodesThatWillBeVisited(_ node: CodeBlockSyntax) -> Bool {
            let skippableNodes: [SyntaxProtocol.Type] = [
                ForStmtSyntax.self,
                GuardStmtSyntax.self,
                WhileStmtSyntax.self,
                RepeatStmtSyntax.self,
                DoStmtSyntax.self,
            ]
            return node.statements.contains { statement in
                skippableNodes.contains { statement.item.is($0) }
            }
        }
    }
}

/// Every call in a statement, those in its arguments and closures included, and the names it calls: each call's, and
/// each function passed by name, as `log` or `log(_:)` is in `events.forEach(log)`.
private final class CallCollector: SyntaxVisitor {
    private(set) var calls: [FunctionCallExprSyntax] = []
    private(set) var names: [String] = []
    /// Every member of a value that isn't called, as `group.leave` passed by name.
    private(set) var references: [MemberAccessExprSyntax] = []

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        calls.append(node)
        var callee = node.calledExpression
        if let specialized = callee.as(GenericSpecializationExprSyntax.self) {
            callee = specialized.expression
        }
        names.append(RemoveSideEffectsOperator.Visitor.name(of: callee))
        return .visitChildren
    }

    /// Without the argument labels a function can be named with, as `(_:)` in `log(_:)`.
    override func visit(_ node: LabeledExprSyntax) -> SyntaxVisitorContinueKind {
        if let reference = node.expression.as(DeclReferenceExprSyntax.self) {
            names.append(reference.baseName.text)
        } else if let member = node.expression.as(MemberAccessExprSyntax.self), let base = member.base {
            names.append(RemoveSideEffectsOperator.Visitor.name(of: base) + "." + member.declName.baseName.text)
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.base != nil, node.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id != node.id {
            references.append(node)
        }
        return .visitChildren
    }
}

/// Every variable, property or parameter in a file that holds a lock: made by a call to a lock type's initializer, or
/// declared with that type, optional or not, generic or not.
private final class LockCollector: SyntaxVisitor {
    struct Lock {
        let name: String
        /// What makes it, for a variable or property made where it's declared.
        let value: ExprSyntax?
    }

    private var locks: [Lock] = []
    private var lockTypes: Set<String> = []

    static func locks(in source: SourceFileSyntax, ofTypes lockTypes: [String]) -> [Lock] {
        let collector = LockCollector(viewMode: .sourceAccurate)
        collector.lockTypes = Set(lockTypes)
        collector.walk(source)
        return collector.locks
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        let annotated = node.typeAnnotation.map { isALockType($0.type) } ?? false
        let made = node.initializer?.value.as(FunctionCallExprSyntax.self).map { isALockType($0.calledExpression) }
        if annotated || made == true {
            let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text ?? node.pattern.trimmedDescription
            locks.append(Lock(name: name, value: node.initializer?.value))
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        if isALockType(node.type) {
            add(parameter: node.secondName ?? node.firstName)
        }
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        if let type = node.type, isALockType(type) {
            add(parameter: node.secondName ?? node.firstName)
        }
        return .visitChildren
    }

    private func add(parameter name: TokenSyntax) {
        if name.tokenKind != .wildcard {
            locks.append(Lock(name: name.text, value: nil))
        }
    }

    /// Whether `node`, a type or a call's callee, names a lock type: `NSLock`, `Foundation.NSLock`, `NSLock?`,
    /// `Optional<NSLock>`, `OSAllocatedUnfairLock<Void>` or `DispatchSemaphore.init`.
    private func isALockType(_ node: some SyntaxProtocol) -> Bool {
        var text = node.trimmedDescription.filter { !$0.isWhitespace }
        while text.hasSuffix("?") || text.hasSuffix("!") {
            text.removeLast()
        }
        if text.hasPrefix("Optional<"), text.hasSuffix(">") {
            text = String(text.dropFirst("Optional<".count).dropLast())
        }
        if let generic = text.firstIndex(of: "<") {
            text = String(text[..<generic])
        }
        var parts = text.split(separator: ".")
        if parts.last == "init" {
            parts.removeLast()
        }
        return parts.last.map { lockTypes.contains(String($0)) } ?? false
    }
}

private extension CodeBlockItemListSyntax {
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
    /// its value, which is taken to be one marked `@…Builder` or of a `some` type; of a closure declared to return a
    /// value; and of a `do` or `catch` body, an `if` or `else` branch, a `switch` case or a `#if` clause that ends one
    /// of those. A closure whose type isn't written, and a `repeat` body, which can end in its condition, are taken to
    /// fall through.
    var mustNotFallThrough: Bool {
        guard let parent else {
            return false
        }
        if let closure = parent.as(ClosureExprSyntax.self) {
            return closure.signature?.returnClause.map { !$0.isReturningVoid } ?? false
        }
        if parent.is(AccessorBlockSyntax.self) {
            return !Self.mayBeAResultBuilder(parent)
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
        guard let owner = parent.as(CodeBlockSyntax.self)?.parent else {
            return false
        }
        if owner.is(GuardStmtSyntax.self) {
            return true
        }
        if let function = owner.as(FunctionDeclSyntax.self) {
            guard let returnClause = function.signature.returnClause else {
                return false
            }
            return !returnClause.isReturningVoid && !function.attributes.containsResultBuilder
                && !returnClause.type.isOpaque
        }
        if let accessor = owner.as(AccessorDeclSyntax.self) {
            return accessor.accessorSpecifier.tokenKind == .keyword(.get) && !Self.mayBeAResultBuilder(owner)
        }
        if owner.is(DoStmtSyntax.self) || owner.is(IfExprSyntax.self) {
            return Self.endsCodeThatMustNotFallThrough(owner)
        }
        if owner.is(CatchClauseSyntax.self) {
            return owner.parent?.parent.map(Self.endsCodeThatMustNotFallThrough) ?? false
        }
        return false
    }

    /// Whether the getter at `node` may be a result builder's: its property or subscript is marked `@…Builder`, or is
    /// of a `some` type, as a protocol can make it one without a mark, as `View` does `body`.
    static func mayBeAResultBuilder(_ node: Syntax) -> Bool {
        var ancestor = node.parent
        while let current = ancestor {
            if let binding = current.as(PatternBindingSyntax.self) {
                let declaration = binding.parent?.parent?.as(VariableDeclSyntax.self)
                return binding.typeAnnotation?.type.isOpaque == true
                    || declaration?.attributes.containsResultBuilder == true
            }
            if let subscriptDecl = current.as(SubscriptDeclSyntax.self) {
                return subscriptDecl.returnClause.type.isOpaque || subscriptDecl.attributes.containsResultBuilder
            }
            ancestor = current.parent
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
        guard let item = node.parent?.as(CodeBlockItemSyntax.self),
              let list = item.parent?.as(CodeBlockItemListSyntax.self),
              [list.last(countingIfConfigs: true)?.id, list.lastStatement?.id].contains(item.id)
        else {
            return false
        }
        return list.mustNotFallThrough
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
