import Foundation
import SwiftSyntax

enum RemoveSideEffectsOperator {
    final class Visitor: MuterVisitor {
        /// What a lock can be called, in this file.
        private var concurrencyPropertiesInFile = Set<String>()

        /// The types a removed call to can leave a thread waiting forever. `Mutex` isn't one: it has no call to remove
        /// but `withLock`, which takes its body with it.
        static let concurrencyTypes: Set = [
            "DispatchSemaphore",
            "DispatchGroup",
            "NSLock",
            "NSRecursiveLock",
            "NSCondition",
            "NSConditionLock",
            "OSAllocatedUnfairLock",
        ]

        /// The calls a statement is never removed for, whatever `excludeCalls` adds, by name, called on no value or on
        /// a module in `modulesOfExcludedCalls`: `print` covers `Swift.print(x)`, not `printer.print(x)`.
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
            "pthread_exit",
            "abort",
        ]

        private static let modulesOfExcludedCalls: Set = [
            "Swift", "Foundation", "Darwin", "Glibc", "Musl", "Android", "WinSDK", "ucrt", "os", "Dispatch",
        ]

        /// Calls kept by their whole path. Removing `super.init` or `self.init` can't compile, and giving up a turn
        /// changes nothing a test can see.
        private static let excludedCallPaths: Set = [["super", "init"], ["self", "init"], ["Task", "yield"]]

        /// Calls kept on any value, as they only check a thing, as `assert` does, or ask for room, which leaves the
        /// value the same.
        private static let excludedCallsOnAnyValue: Set = ["assertIsolated", "preconditionIsolated", "reserveCapacity"]

        private static let lockFunctionPrefixes = [
            "os_unfair_lock_", "pthread_mutex_", "pthread_rwlock_", "pthread_cond_",
        ]

        /// Names only a lock has, kept on any value, as a lock declared in another file can't be told by its type.
        private static let lockCalls: Set = ["lock", "unlock", "tryLock"]

        /// Removing one of these takes the body with it, and can't leave a lock held.
        private static let lockCallsThatTakeABody: Set = ["withLock", "withLockIfAvailable"]

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

        /// Collected first, so a lock declared after the code that uses it counts.
        override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
            let result = super.visit(node)
            let collector = LockNameCollector { [unowned self] value in hasTestCoverage(value) }
            collector.walk(node)
            concurrencyPropertiesInFile = collector.names
            return result
        }

        /// Each list once. One visited twice, as a body by its owner and as a list, would repeat every mutant in it.
        override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
            if let rule = node.removalRule, !node.isOpaqueNonBuilderBody, !node.isInAMacrosArguments {
                removeSideEffects(in: node, by: rule)
            }
            return super.visit(node)
        }

        private func removeSideEffects(in statements: CodeBlockItemListSyntax, by rule: RemovalRule) {
            for statement in statements
                where rule.allowsRemoving(statement, of: statements) && canBeRemoved(statement) {
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

        private func canBeRemoved(_ statement: CodeBlockItemSyntax) -> Bool {
            guard statement.unwrappedExpression?.is(FunctionCallExprSyntax.self) == true || discardsAResult(statement),
                  !statement.buildsAValue
            else { return false }
            return !calls(in: statement).contains { path in isExcluded(path) || isLockCall(path) }
        }

        /// `_ = expr` or `let _ = expr`: a statement whose only effect is evaluating `expr`.
        ///
        /// Read from the syntax tree, never the text. Searching the statement's description for `_ = `
        /// also matched string literals, so `let body = "_ = \(x)"` was removed and every later use of
        /// `body` failed to compile, which breaks the single build all mutants share.
        private func discardsAResult(_ statement: CodeBlockItemSyntax) -> Bool {
            if let expression = statement.unwrappedExpression {
                if let sequence = expression.as(SequenceExprSyntax.self) {
                    let elements = Array(sequence.elements)
                    return elements.count >= 3
                        && elements[0].withoutEffects.is(DiscardAssignmentExprSyntax.self)
                        && elements[1].is(AssignmentExprSyntax.self)
                }
                if let infix = expression.as(InfixOperatorExprSyntax.self) {
                    return infix.leftOperand.withoutEffects.is(DiscardAssignmentExprSyntax.self)
                        && infix.operator.is(AssignmentExprSyntax.self)
                }
                return false
            }
            if let declaration = statement.item.as(VariableDeclSyntax.self),
               declaration.bindings.count == 1,
               let binding = declaration.bindings.first {
                return binding.pattern.is(WildcardPatternSyntax.self) && binding.initializer != nil
            }
            return false
        }

        /// The path of each call in `statement`, those in its arguments and closures too: without the call to `exit` or
        /// `signal` in `queue.async { … }`, the statement isn't the same.
        private func calls(in statement: CodeBlockItemSyntax) -> [[String]] {
            let collector = CallPathCollector()
            collector.walk(statement)
            return collector.paths
        }

        private func isExcluded(_ path: [String]) -> Bool {
            guard let name = path.last else { return false }
            if Self.excludedCallPaths.contains(path) || Self.excludedCallsOnAnyValue.contains(name) { return true }
            let isGlobal = path.count == 1 || path.count == 2 && Self.modulesOfExcludedCalls.contains(path[0])
            if isGlobal, Self.alwaysExcludedCalls.contains(name) { return true }
            return (configuration?.excludeCallList ?? []).contains { CalledName.excludeCallsEntry($0, matches: path) }
        }

        private func isLockCall(_ path: [String]) -> Bool {
            guard let name = path.last, !Self.lockCallsThatTakeABody.contains(name) else { return false }
            if Self.lockCalls.contains(name) { return true }
            if path.count == 1 || path.count == 2 && Self.modulesOfExcludedCalls.contains(path[0]),
               Self.lockFunctionPrefixes.contains(where: name.hasPrefix) {
                return true
            }
            guard path.count >= 2 else { return false }
            // Nothing ever resumes the task then, which a run can only see as a timeout. Anywhere in the path, for
            // `continuations.removeFirst().resume()`.
            if name == "resume", path.dropLast().contains(where: { $0.lowercased().contains("continuation") }) {
                return true
            }
            return concurrencyPropertiesInFile.contains(path[path.count - 2])
        }
    }
}

/// The name of each lock declared in a file, wherever it is, by its type or what makes it. A flat list of names, as
/// there's no telling a call's receiver from a name: so a lock made in code the tests never ran doesn't count. It has
/// no uses that ran, and another value of that name may. A type's property is made by code of its own, with each
/// instance, though the code that declares the type never ran. One with no value, or a parameter, always counts.
private final class LockNameCollector: SyntaxVisitor {
    private(set) var names = Set<String>()
    private let ran: (ExprSyntax) -> Bool

    init(ran: @escaping (ExprSyntax) -> Bool) {
        self.ran = ran
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        let isLock = isLock(node.typeAnnotation?.type)
            || node.initializer.map { isLockMaker($0.value) } == true
        if isLock, node.initializer.map({ ran($0.value) }) ?? true {
            names.insert(node.pattern.trimmedDescription)
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        if isLock(node.type) {
            names.insert((node.secondName ?? node.firstName).text)
        }
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        if isLock(node.type) {
            names.insert((node.secondName ?? node.firstName).text)
        }
        return .visitChildren
    }

    private func isLock(_ type: TypeSyntax?) -> Bool {
        type.map { RemoveSideEffectsOperator.Visitor.concurrencyTypes.contains($0.lastName) } ?? false
    }

    private func isLockMaker(_ value: ExprSyntax) -> Bool {
        guard let call = value.as(FunctionCallExprSyntax.self) else { return false }
        var path = CalledName.path(of: call.calledExpression)
        if path.last == "init" { path.removeLast() }
        return path.last.map(RemoveSideEffectsOperator.Visitor.concurrencyTypes.contains) ?? false
    }
}

private final class CallPathCollector: SyntaxVisitor {
    private(set) var paths: [[String]] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        paths.append(CalledName.path(of: node.calledExpression))
        return .visitChildren
    }

    /// A function passed by name is called too, as in `queue.async(execute: lock.unlock)` and `items.forEach(log)`.
    /// `.lock`, with no value before it, is an enum case's name.
    override func visit(_ node: LabeledExprSyntax) -> SyntaxVisitorContinueKind {
        let isNamed = node.expression.is(DeclReferenceExprSyntax.self)
            || node.expression.as(MemberAccessExprSyntax.self)?.base != nil
        if isNamed { paths.append(CalledName.path(of: node.expression)) }
        return .visitChildren
    }
}

private extension CodeBlockItemListSyntax {
    /// Its statements would be switched in the list around the macro, which copies the whole macro for each mutant.
    var isInAMacrosArguments: Bool {
        var ancestor = parent
        while let current = ancestor {
            if current.is(MacroExpansionExprSyntax.self) || current.is(MacroExpansionDeclSyntax.self) { return true }
            ancestor = current.parent
        }
        return false
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
