import Foundation
import SwiftSyntax

enum RemoveSideEffectsOperator {
    final class Visitor: MuterVisitor {
        /// The file's variables and properties that hold a lock, by name.
        private var lockNames = Set<String>()

        /// The calls a statement is never removed for, whatever `excludeCalls` adds. Each is matched by the name it's
        /// called by, as `name(_:matchesAnyOf:)` says. Output and logging are here because a test rarely reads them.
        /// The assertions are here because tests rarely take their failing path, so removing one nearly always
        /// survives. A call that ends the process or the thread never returns, so it can be what ends code control
        /// must not fall out of. `Task.yield()` only lets other tasks run. An initializer that delegates must call
        /// `super.init` or `self.init`.
        static let alwaysExcludedCalls = [
            "print",
            "debugPrint",
            "dump",
            "NSLog",
            "os_log",
            "fatalError",
            "preconditionFailure",
            "precondition",
            "assert",
            "assertionFailure",
            "dispatchPrecondition",
            "exit",
            "_exit",
            "abort",
            "pthread_exit",
            "Task.yield",
            "super.init",
            "self.init",
        ]

        /// The methods a statement is never removed for, on whatever value they're called: an actor's or an
        /// executor's isolation checks, which are assertions, and `reserveCapacity(_:)`, which only saves
        /// reallocations, so removing it changes no result a test can see.
        static let methodsExcludedOnAnyValue: Set = ["assertIsolated", "preconditionIsolated", "reserveCapacity"]

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

        /// The functions that take, release or wait for the lock or condition passed to them.
        static let lockFunctions = [
            "os_unfair_lock_lock",
            "os_unfair_lock_trylock",
            "os_unfair_lock_unlock",
            "pthread_mutex_lock",
            "pthread_mutex_trylock",
            "pthread_mutex_unlock",
            "pthread_rwlock_rdlock",
            "pthread_rwlock_tryrdlock",
            "pthread_rwlock_wrlock",
            "pthread_rwlock_trywrlock",
            "pthread_rwlock_unlock",
            "pthread_cond_wait",
            "pthread_cond_timedwait",
            "pthread_cond_signal",
            "pthread_cond_broadcast",
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

        /// Every body: a function's, an initializer's or a deinitializer's, an accessor's, a closure's, a loop's, a
        /// `guard`, `do`, `catch`, `if`, `else` or `defer` body, and a `switch` case. Not a file's top level, nor a
        /// `#if` clause's.
        ///
        /// A branch of an `if` or `switch` that is a value is left out, as the mutant's switch around its statements
        /// would turn the branch into an `if` statement, which has no value.
        override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
            if node.isABody, !node.isABranchOfAValue, !node.isInABuilderThatTakesNoIf {
                removeSideEffects(from: node)
            }

            return super.visit(node)
        }

        private func removeSideEffects(from statements: CodeBlockItemListSyntax) {
            // Only a call that never returns, such as a project's own `usage()`, which the deny-list can't know of,
            // can end code that control must never reach the end of. Removing it leaves code that falls through,
            // which doesn't compile, and fails the build every mutant shares. And the one statement of a closure
            // or a getter can be its value, as `transform($0)` is `items.map { transform($0) }`'s.
            let keepsTheLast = statements.mustKeepItsLastStatement
                || statements.mayEndInACallThatInitializationReliesOn
            let keptStatement = keepsTheLast ? statements.lastStatement : nil
            for statement in statements where statementContainsMutableToken(statement, in: statements) {
                if statement.id == keptStatement?.id {
                    continue
                }
                var newCodeBlockItemList = statements.removing(statement)
                // A `switch` case must hold a statement.
                if newCodeBlockItemList.isEmpty, statements.parent?.is(SwitchCaseSyntax.self) == true {
                    newCodeBlockItemList = [statement.replacedByDoingNothing]
                }

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

        private func statementContainsMutableToken(
            _ statement: CodeBlockItemListSyntax.Element,
            in statements: CodeBlockItemListSyntax
        ) -> Bool {
            let doesntContainVariableAssignment = doesntContainVariableAssignment(statement.allChildren)
            let containsDiscardedResult = discardsAResult(statement)
            let containsFunctionCall = statement.item.withoutTryAwaitOrUnsafe.is(FunctionCallExprSyntax.self)
                && !(statements.mayBeABuildersParts && Self.makesAValueOfAType(statement.item))

            let found = CallCollector(viewMode: .sourceAccurate)
            found.walk(statement)
            let callsNothingItMustKeep = !found.names.contains { Self.name($0, matchesAnyOf: untestedFunctionNames) }
                && !found.names.contains(where: Self.isAMethodExcludedOnAnyValue)
                && !found.calls.contains(where: isCallOnALock)
                && !found.calls.contains(where: Self.resumesAContinuation)
                && !found.references.contains { isOnALock($0, methods: Self.lockMethods) }

            return doesntContainVariableAssignment
                && callsNothingItMustKeep
                && (containsDiscardedResult || containsFunctionCall)
        }

        /// Whether the statement makes a value of a type, as `Text("a")`, `Text("a").bold()`, `WindowGroup { … }` or
        /// `CharacterClass.anyOf("ab")` do: a call of a type, or of a type's member. In code that may be a
        /// result builder's, that is one of its parts, which isn't a side effect, and whose builder may take no `if`,
        /// so the mutant's switch wouldn't build. `Task { … }`, which starts work, is the exception.
        static func makesAValueOfAType(_ item: some SyntaxProtocol) -> Bool {
            guard var call = item.withoutTryAwaitOrUnsafe.as(FunctionCallExprSyntax.self) else {
                return false
            }
            // The call a chain of modifiers starts from.
            while let base = call.calledExpression.as(MemberAccessExprSyntax.self)?.base,
                  let baseCall = base.as(FunctionCallExprSyntax.self) {
                call = baseCall
            }
            var parts = name(of: call.calledExpression).split(separator: ".").map { $0.prefix { $0 != "<" } }
            guard !parts.contains("Task") else {
                return false
            }
            if parts.count > 1, parts.last == "init" {
                parts.removeLast()
            }
            // `Text`, `SwiftUI.Text` or `CharacterClass.anyOf`, but not `NotificationCenter.default.post`, a method of
            // a value.
            let isAType = { (part: Substring?) in part?.first?.isUppercase == true }
            return isAType(parts.last) || parts.count == 2 && isAType(parts.first)
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

        /// Whether `calledName` is one of `methodsExcludedOnAnyValue`, alone or on any value, as in
        /// `executor.assertIsolated()` or `items.reserveCapacity(10)`.
        static func isAMethodExcludedOnAnyValue(_ calledName: String) -> Bool {
            calledName.split(separator: ".").last.map { methodsExcludedOnAnyValue.contains(String($0)) } ?? false
        }

        /// Whether the call resumes a continuation, as `continuation.resume(returning: value)` or
        /// `self.pendingContinuation?.resume()` do: `resume` on a value with `continuation` in its name, in any case.
        /// Removing one leaves the task that awaits it suspended for good, which ends as a timeout. A continuation is
        /// known only by its name, so `task.resume()` is removed.
        static func resumesAContinuation(_ call: FunctionCallExprSyntax) -> Bool {
            guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "resume",
                  let base = member.base,
                  let value = name(of: base).split(separator: ".").last
            else {
                return false
            }
            return value.lowercased().contains("continuation")
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
    /// Whether these are a body's statements, of anything but a file's top level or a `#if` clause.
    var isABody: Bool {
        guard let parent else {
            return false
        }
        return parent.is(CodeBlockSyntax.self) || parent.is(ClosureExprSyntax.self)
            || parent.is(AccessorBlockSyntax.self) || parent.is(SwitchCaseSyntax.self)
    }

    /// The closure, getter, function or other declaration whose code these statements are, through the `if`, `switch`,
    /// loop and `do` statements between.
    var owner: Syntax? {
        var node = parent
        while let current = node {
            if current.is(ClosureExprSyntax.self) || current.is(AccessorBlockSyntax.self) || current.is(DeclSyntax.self)
                && !current.is(IfConfigDeclSyntax.self) && !current.is(VariableDeclSyntax.self) {
                return current
            }
            node = current.parent
        }
        return nil
    }

    /// Whether these may be a result builder's parts: in a closure whose type isn't written and that returns no value,
    /// or a getter or function marked `@…Builder` or of a `some` type.
    var mayBeABuildersParts: Bool {
        guard let owner else {
            return false
        }
        if let closure = owner.as(ClosureExprSyntax.self) {
            return closure.signature?.returnClause == nil && !closure.returnsAValue
        }
        // A `return` of a value turns the builder off.
        if let function = owner.as(FunctionDeclSyntax.self) {
            return (function.attributes.containsResultBuilder || function.signature.returnClause?.type.isOpaque == true)
                && !(function.body.map { ValueReturnFinder.findsAValueReturn(in: Syntax($0.statements)) } ?? false)
        }
        if let accessorBlock = owner.as(AccessorBlockSyntax.self),
           case let .getter(statements) = accessorBlock.accessors {
            return Self.mayBeAResultBuilder(owner) && !ValueReturnFinder.findsAValueReturn(in: Syntax(statements))
        }
        guard let accessor = owner.as(AccessorDeclSyntax.self), accessor.accessorSpecifier.tokenKind == .keyword(.get)
        else {
            return false
        }
        return Self.mayBeAResultBuilder(owner)
            && !(accessor.body.map { ValueReturnFinder.findsAValueReturn(in: Syntax($0.statements)) } ?? false)
    }

    /// Whether these are the parts of a result builder known to take no `if`, where no mutant's switch builds: an
    /// App's or a Scene's `SceneBuilder`, a `WidgetBundleBuilder`, an `AppShortcutsBuilder`, and the
    /// `RegexComponentBuilder` of `Regex { … }`, `wholeMatch { … }` and the like. It's a closure passed to one, a
    /// `Group` among another's parts, or a getter or function marked with one or of a `some` type it builds.
    var isInABuilderThatTakesNoIf: Bool {
        guard let owner else {
            return false
        }
        if let closure = owner.as(ClosureExprSyntax.self) {
            guard let callee = closure.callee else {
                return false
            }
            let parts = RemoveSideEffectsOperator.Visitor.name(of: callee).split(separator: ".")
                .map { String($0.prefix { $0 != "<" }) }
            if parts.contains(where: Self.regexBuilderTypes.contains)
                || parts.last.map(Self.regexAlgorithms.contains) == true {
                return true
            }
            // The statement the `Group` is, with any modifiers on it, as `Group { … }.defaultSize(…)`.
            var node = closure.parent
            while let base = node, let member = base.parent?.as(MemberAccessExprSyntax.self),
                  member.base?.id == base.id, let call = member.parent?.as(FunctionCallExprSyntax.self) {
                node = Syntax(call)
            }
            let statement = node?.parent?.as(CodeBlockItemSyntax.self)
            return parts.last == "Group"
                && statement?.parent?.as(CodeBlockItemListSyntax.self)?.isInABuilderThatTakesNoIf == true
        }
        // A `some` type makes a builder only of code with no `return` of a value.
        let isABuilder = !ValueReturnFinder.findsAValueReturn(in: Syntax(self))
        if let function = owner.as(FunctionDeclSyntax.self) {
            return function.attributes.namesAnIflessBuilder
                || isABuilder && function.signature.returnClause.map { Self.isAnIflessBuildersType($0.type) } ?? false
        }
        var ancestor = owner.parent
        while let node = ancestor {
            if let binding = node.as(PatternBindingSyntax.self) {
                let declaration = binding.parent?.parent?.as(VariableDeclSyntax.self)
                return declaration?.attributes.namesAnIflessBuilder == true
                    || isABuilder && binding.typeAnnotation.map { Self.isAnIflessBuildersType($0.type) } ?? false
                    || binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "appShortcuts"
            }
            if let subscriptDecl = node.as(SubscriptDeclSyntax.self) {
                return subscriptDecl.attributes.namesAnIflessBuilder
                    || isABuilder && Self.isAnIflessBuildersType(subscriptDecl.returnClause.type)
            }
            ancestor = node.parent
        }
        return false
    }

    private static let regexBuilderTypes: Set<String> = [
        "Regex", "Capture", "TryCapture", "Local", "One", "OneOrMore", "ZeroOrMore", "Optionally", "Repeat", "ChoiceOf",
        "Lookahead", "NegativeLookahead", "Anchor",
    ]

    /// The string methods that take a `RegexComponentBuilder` closure, but for the names that are common elsewhere,
    /// as `contains` and `split`.
    private static let regexAlgorithms: Set<String> = [
        "wholeMatch", "firstMatch", "prefixMatch", "matches", "replacing", "replace", "firstRange", "ranges",
        "trimmingPrefix", "trimPrefix",
    ]

    /// `some Scene`, `some Widget` or `some RegexComponent`.
    private static func isAnIflessBuildersType(_ type: TypeSyntax) -> Bool {
        guard let opaque = type.as(SomeOrAnyTypeSyntax.self), type.isOpaque else {
            return false
        }
        let name = opaque.constraint.trimmedDescription.split(separator: ".").last
        return ["Scene", "Widget", "RegexComponent"].contains(name)
    }

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
        let owner = parent.as(CodeBlockSyntax.self)?.parent
        if let function = owner?.as(FunctionDeclSyntax.self) {
            return function.signature.returnClause.map { !$0.isReturningVoid } ?? false
        }
        return owner?.as(AccessorDeclSyntax.self)?.accessorSpecifier.tokenKind == .keyword(.get) || isABranchOfAValue
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
        let owner = parent.as(CodeBlockSyntax.self)?.parent
        if owner?.is(InitializerDeclSyntax.self) == true {
            return true
        }
        guard parent.is(SwitchCaseSyntax.self) || owner?.is(IfExprSyntax.self) == true
            || owner?.is(CatchClauseSyntax.self) == true || owner?.is(DoStmtSyntax.self) == true
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
            let mayBeABuilder = function.attributes.containsResultBuilder || returnClause.type.isOpaque
            return !returnClause.isReturningVoid
                && (!mayBeABuilder || ValueReturnFinder.findsAValueReturn(in: Syntax(self)))
        }
        if let accessor = owner.as(AccessorDeclSyntax.self) {
            return accessor.accessorSpecifier.tokenKind == .keyword(.get)
                && (!Self.mayBeAResultBuilder(owner) || ValueReturnFinder.findsAValueReturn(in: Syntax(self)))
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

private extension CodeBlockItemSyntax {
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

private extension SyntaxProtocol {
    /// The expression under any `try`, `await` and `unsafe`, as `save()` is in `try await save()`.
    var withoutTryAwaitOrUnsafe: Syntax {
        var node = Syntax(self)
        while true {
            if let tryExpr = node.as(TryExprSyntax.self) {
                node = Syntax(tryExpr.expression)
            } else if let awaitExpr = node.as(AwaitExprSyntax.self) {
                node = Syntax(awaitExpr.expression)
            } else if let unsafeExpr = node.as(UnsafeExprSyntax.self) {
                node = Syntax(unsafeExpr.expression)
            } else {
                return node
            }
        }
    }
}

private extension ClosureExprSyntax {
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

private final class ValueReturnFinder: SyntaxAnyVisitor {
    private(set) var found = false
    /// Whether a `return` of nothing counts too.
    private var findsAnyReturn = false

    /// Whether the code holds a `return` of a value of its own.
    static func findsAValueReturn(in node: Syntax) -> Bool {
        let finder = ValueReturnFinder(viewMode: .sourceAccurate)
        finder.walk(node)
        return finder.found
    }

    /// Whether the code holds a `return` of its own, of a value or not.
    static func findsAnyReturn(in node: Syntax) -> Bool {
        let finder = ValueReturnFinder(viewMode: .sourceAccurate)
        finder.findsAnyReturn = true
        finder.walk(node)
        return finder.found
    }

    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        if let returnStmt = node.as(ReturnStmtSyntax.self) {
            found = found || findsAnyReturn || returnStmt.expression != nil
            return .skipChildren
        }
        let isOtherCode = node.is(ClosureExprSyntax.self) || node.is(AccessorBlockSyntax.self)
            || node.is(DeclSyntax.self) && !node.is(VariableDeclSyntax.self) && !node.is(IfConfigDeclSyntax.self)
        return found || isOtherCode ? .skipChildren : .visitChildren
    }
}

private extension AttributeListSyntax {
    /// Whether one of the attributes is a builder known to take no `if`.
    var namesAnIflessBuilder: Bool {
        contains { element in
            let name = element.as(AttributeSyntax.self)?.attributeName.trimmedDescription.split(separator: ".").last
            return ["SceneBuilder", "WidgetBundleBuilder", "AppShortcutsBuilder", "RegexComponentBuilder"]
                .contains(name.map(String.init))
        }
    }
}
