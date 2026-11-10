import SwiftSyntax

enum RemoveSideEffectsOperator {
    final class Visitor: MuterVisitor {
        /// The file's variables and properties that hold a lock, by name.
        private var lockNames = Set<String>()

        /// The calls a statement is never removed for, whatever `excludeCalls` adds. Each is matched by the name it's
        /// called by, as `name(_:matchesAnyOf:)` says. The assertions are here because tests rarely take their
        /// failing path, so removing one nearly always survives. An initializer that delegates must call `super.init`
        /// or `self.init`.
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
            "super.init",
            "self.init",
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
            sourceCodeInfo: SourceCodeInfo,
            configuration: MuterConfiguration? = nil,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .removeSideEffects,
                coverage: coverage,
                configuration: configuration
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
            let containsFunctionCall = statement.item.withoutTryOrAwait.is(FunctionCallExprSyntax.self)
                && !(statements.mayBeABuildersParts && Self.makesAValueOfAType(statement.item))

            let found = CallCollector(viewMode: .sourceAccurate)
            found.walk(statement)
            let callsNothingItMustKeep = !found.names.contains { Self.name($0, matchesAnyOf: untestedFunctionNames) }
                && !found.calls.contains(where: isCallOnALock)
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
            guard var call = item.withoutTryOrAwait.as(FunctionCallExprSyntax.self) else {
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
