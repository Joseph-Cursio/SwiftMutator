import SwiftSyntax

/// Which statements of a list a removal leaves code that compiles, by where the list is. What syntax can't tell, as a
/// call to a project's own `Never` function that isn't last, or one that a later `let` needs, `CompileRecovery` takes
/// out when the build fails.
enum RemovalRule: Equatable {
    /// Any: control reaching the end of this list is fine.
    case free
    /// All but the last, which may be what the list ends with: a `Never` call, or the value it gives.
    case keepLast
    /// All but an only statement, which may be the closure's value. The last of several can't be: it would need
    /// `return`.
    case keepOnly
    /// None: each branch of an `if` or `switch` used as a value must be one expression.
    case keepAll

    func allowsRemoving(_ statement: CodeBlockItemSyntax, of list: CodeBlockItemListSyntax) -> Bool {
        switch self {
        case .free: true
        case .keepLast: list.last?.id != statement.id
        case .keepOnly: list.countWithoutIfConfigs > 1
        case .keepAll: false
        }
    }
}

extension CodeBlockItemListSyntax {
    /// What may be removed from this list; nil for a list no removal is looked for in: a file's top level, or a `#if`
    /// clause, which may be a value's only item, where an emptied clause leaves nothing to return.
    var removalRule: RemovalRule? {
        guard let parent else { return nil }
        if let closure = parent.as(ClosureExprSyntax.self) { return removalRule(in: closure) }
        if let switchCase = parent.as(SwitchCaseSyntax.self) { return Self.ruleInherited(by: switchCase) }
        if let block = parent.as(AccessorBlockSyntax.self) { return Self.ruleOfGetter(in: block) }
        guard let owner = parent.as(CodeBlockSyntax.self)?.parent else { return nil }
        return Self.rule(forBodyOf: owner)
    }

    private static func rule(forBodyOf owner: Syntax) -> RemovalRule? {
        if let function = owner.as(FunctionDeclSyntax.self) {
            guard function.signature.returnClause?.isReturningVoid == false else { return .free }
            // A builder's last statement is no more its value than any other, but it may be its only one.
            return function.attributes.containsResultBuilder ? .keepOnly : .keepLast
        }
        if let accessor = owner.as(AccessorDeclSyntax.self) { return rule(of: accessor) }
        if owner.is(GuardStmtSyntax.self) { return .keepLast }
        if owner.is(IfExprSyntax.self) || owner.is(DoStmtSyntax.self) { return ruleInherited(from: owner) }
        if let clause = owner.as(CatchClauseSyntax.self) {
            return clause.ancestorOrSelf(mapping: { $0.as(DoStmtSyntax.self) }).map { ruleInherited(from: Syntax($0)) }
        }
        // An initializer's only statement may be a `Never` call, standing in for the properties it would have to set.
        if owner.is(InitializerDeclSyntax.self) { return .keepOnly }
        let bodiesThatEndFreely: [SyntaxProtocol.Type] = [
            ForStmtSyntax.self, WhileStmtSyntax.self, RepeatStmtSyntax.self, DeferStmtSyntax.self,
            DeinitializerDeclSyntax.self,
        ]
        return bodiesThatEndFreely.contains { owner.is($0) } ? .free : nil
    }

    private static func rule(of accessor: AccessorDeclSyntax) -> RemovalRule {
        switch accessor.accessorSpecifier.tokenKind {
        case .keyword(.get), .keyword(.unsafeAddress), .keyword(.unsafeMutableAddress):
            ruleOfGetter(in: accessor.parent?.ancestorOrSelf(mapping: { $0.as(AccessorBlockSyntax.self) }))
        case .keyword(._read), .keyword(._modify):
            // An only statement may be a `Never` call, standing in for the `yield` it must reach.
            .keepOnly
        default:
            .free
        }
    }

    private static func ruleOfGetter(in block: AccessorBlockSyntax?) -> RemovalRule {
        let type = block?.parent?.as(SubscriptDeclSyntax.self)?.returnClause.type
            ?? block?.parent?.as(PatternBindingSyntax.self)?.typeAnnotation?.type
        return type?.isVoid == true ? .free : .keepLast
    }

    private static func ruleInherited(by switchCase: SwitchCaseSyntax) -> RemovalRule {
        // Through any `#if` among the cases.
        switchCase.ancestorOrSelf(mapping: { $0.as(SwitchExprSyntax.self) })
            .map { ruleInherited(from: Syntax($0)) } ?? .free
    }

    /// The rule for the lists in `node`, an `if`, a `switch` or a `do`, whose branches end where it does.
    private static func ruleInherited(from node: Syntax) -> RemovalRule {
        var node = node
        while let outer = node.parent?.as(IfExprSyntax.self), outer.elseBody?.id == node.id {
            node = Syntax(outer)
        }
        while let parent = node.parent, parent.is(ExpressionStmtSyntax.self) || parent.is(LabeledStmtSyntax.self) {
            node = parent
        }
        // An `if` or `switch` that isn't a statement is a value, as in `let x = if c { a() } else { b() }`.
        guard let item = node.parent?.as(CodeBlockItemSyntax.self) else { return .keepAll }
        guard let list = item.parent?.as(CodeBlockItemListSyntax.self) else { return .free }
        return list.ruleForLists(in: item)
    }

    /// What this list's rule means for the lists of a statement in it, which end where the statement does.
    fileprivate func ruleForLists(in item: CodeBlockItemSyntax) -> RemovalRule {
        if parent?.is(IfConfigClauseSyntax.self) == true {
            guard last?.id == item.id,
                  let ifConfig = parent?.ancestorOrSelf(mapping: { $0.as(IfConfigDeclSyntax.self) })
            else { return .free }
            return Self.ruleInherited(from: Syntax(ifConfig))
        }
        switch removalRule {
        case .keepAll: return .keepAll
        case .keepLast: return last?.id == item.id ? .keepLast : .free
        case .keepOnly: return countWithoutIfConfigs == 1 ? .keepOnly : .free
        case .free, nil: return .free
        }
    }

    /// Only an explicit type says a closure gives no value. An only statement may be its value, and removing it either
    /// gives a missing `return` or, in a value with no annotation, changes the type code in other files reads, which
    /// `CompileRecovery` can't pin on any mutant. So one is removed only in a call known to ignore that value.
    private func removalRule(in closure: ClosureExprSyntax) -> RemovalRule {
        if let clause = closure.signature?.returnClause {
            return clause.isReturningVoid ? .free : .keepLast
        }
        if closure.isTypedToGiveAValue || ValueReturnFinder.finds(in: self) { return .keepLast }
        return countWithoutIfConfigs == 1 && closure.valueIsIgnored ? .free : .keepOnly
    }

    /// A `#if` beside a statement doesn't make it one of several: the clause may hold nothing in this build.
    var countWithoutIfConfigs: Int {
        count { !$0.item.is(IfConfigDeclSyntax.self) }
    }
}

/// Finds a `return` with a value in a closure's own statements, a sign that the closure must give one, so that its last
/// statement may be a `Never` call.
private final class ValueReturnFinder: SyntaxVisitor {
    private var found = false

    static func finds(in statements: CodeBlockItemListSyntax) -> Bool {
        let finder = ValueReturnFinder(viewMode: .sourceAccurate)
        finder.walk(statements)
        return finder.found
    }

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        if node.expression != nil { found = true }
        return .skipChildren
    }

    override func visit(_: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_: AccessorBlockSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

private extension ClosureExprSyntax {
    /// Calls whose closure gives nothing anyone reads, as long as the call's own value isn't read either.
    static let callsOnAnyReceiverIgnoringAClosuresValue: Set = [
        "forEach", "async", "asyncAfter", "sync", "withLock", "withTaskCancellationHandler", "withExtendedLifetime",
    ]
    static let callsIgnoringAClosuresValue: Set = [["Task"], ["Task", "detached"], ["Button"]]

    var valueIsIgnored: Bool {
        guard let call = enclosingCall, !call.calledExpression.is(GenericSpecializationExprSyntax.self) else {
            return false
        }
        let path = CalledName.path(of: call.calledExpression)
        guard Self.callsIgnoringAClosuresValue.contains(path)
            || path.last.map(Self.callsOnAnyReceiverIgnoringAClosuresValue.contains) == true
        else { return false }
        if path == ["Button"], !isActionOf(button: call) { return false }
        return call.isStatementWhoseValueIsUnused
    }

    /// A `Button`'s other closure is its label, which is a value.
    private func isActionOf(button: FunctionCallExprSyntax) -> Bool {
        if parent?.is(MultipleTrailingClosureElementSyntax.self) == true { return false }
        if let argument = parent?.as(LabeledExprSyntax.self) { return argument.label?.text == "action" }
        return !button.arguments.contains { $0.label?.text == "action" }
    }

    /// `let f: () -> Int = { … }`.
    var isTypedToGiveAValue: Bool {
        guard let binding = parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self),
              let type = binding.typeAnnotation?.type.as(FunctionTypeSyntax.self)
        else { return false }
        return !type.returnClause.type.isVoid
    }

    private var enclosingCall: FunctionCallExprSyntax? {
        if let call = parent?.as(FunctionCallExprSyntax.self) { return call }
        if parent?.is(MultipleTrailingClosureElementSyntax.self) == true {
            return parent?.parent?.parent?.as(FunctionCallExprSyntax.self)
        }
        guard parent?.is(LabeledExprSyntax.self) == true else { return nil }
        return parent?.parent?.parent?.as(FunctionCallExprSyntax.self)
    }
}

private extension FunctionCallExprSyntax {
    var isStatementWhoseValueIsUnused: Bool {
        var node = Syntax(self)
        while let parent = node.parent,
              parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) || parent.is(UnsafeExprSyntax.self) {
            node = parent
        }
        guard let item = node.parent?.as(CodeBlockItemSyntax.self),
              let list = item.parent?.as(CodeBlockItemListSyntax.self)
        else { return false }
        // A `#if` clause has no rule of its own, and may be the value of what's around it.
        if list.parent?.is(IfConfigClauseSyntax.self) == true { return list.ruleForLists(in: item) == .free }
        return list.removalRule?.allowsRemoving(item, of: list) ?? true
    }
}

extension CodeBlockItemSyntax {
    /// Its expression under any `try`, `await` and `unsafe`, if it is one.
    var unwrappedExpression: ExprSyntax? {
        item.as(ExprSyntax.self)?.withoutEffects
    }

    /// `Text("a").font(.x)` or `Spacer()` in a closure, a getter or a builder function, which makes a value to give a
    /// result builder, as far as syntax can tell, rather than having a side effect. A `for` or `do` in between isn't a
    /// builder's own list.
    var buildsAValue: Bool {
        guard let name = unwrappedExpression?.innermostCalledName,
              name.first?.isUppercase == true, name != "Task",
              parent?.as(CodeBlockItemListSyntax.self)?.isDirectlyWhereABuilderMayBe == true
        else { return false }
        return true
    }
}

private extension CodeBlockItemListSyntax {
    var isDirectlyWhereABuilderMayBe: Bool {
        guard let parent else { return false }
        if parent.is(ClosureExprSyntax.self) || parent.is(AccessorBlockSyntax.self) { return true }
        if parent.is(SwitchCaseSyntax.self) {
            return parent.ancestorOrSelf(mapping: { $0.as(CodeBlockItemListSyntax.self) })?
                .isDirectlyWhereABuilderMayBe == true
        }
        guard let owner = parent.as(CodeBlockSyntax.self)?.parent else { return false }
        if let function = owner.as(FunctionDeclSyntax.self) { return function.attributes.containsResultBuilder }
        if let accessor = owner.as(AccessorDeclSyntax.self) {
            return accessor.accessorSpecifier.tokenKind == .keyword(.get)
        }
        guard owner.is(IfExprSyntax.self) else { return false }
        return owner.parent?.ancestorOrSelf(mapping: { $0.as(CodeBlockItemListSyntax.self) })?
            .isDirectlyWhereABuilderMayBe == true
    }
}

extension ExprSyntax {
    var withoutEffects: ExprSyntax {
        if let inner = self.as(TryExprSyntax.self)?.expression { return inner.withoutEffects }
        if let inner = self.as(AwaitExprSyntax.self)?.expression { return inner.withoutEffects }
        if let inner = self.as(UnsafeExprSyntax.self)?.expression { return inner.withoutEffects }
        return self
    }

    /// The last name of the first call in a chain of them, `Text` in `Text("a").font(.x)`.
    fileprivate var innermostCalledName: String? {
        var innermost: String?
        var node = self
        while true {
            if let call = node.as(FunctionCallExprSyntax.self) {
                innermost = CalledName.path(of: call.calledExpression).last
                node = call.calledExpression
            } else if let member = node.as(MemberAccessExprSyntax.self), let base = member.base {
                node = base
            } else if let inner = node.as(GenericSpecializationExprSyntax.self)?.expression {
                node = inner
            } else if let inner = node.as(OptionalChainingExprSyntax.self)?.expression {
                node = inner
            } else if let inner = node.as(ForceUnwrapExprSyntax.self)?.expression {
                node = inner
            } else {
                return innermost
            }
        }
    }
}

/// A call's name, in the parts it was written with, by which every list of calls here matches it: reading the text of
/// a statement also found `print` in `printer.flush()`, and in a comment above it.
enum CalledName {
    /// Stands for a receiver with no name, as in `.exit(0)` and `"a".print()`, so that a call on one isn't taken for
    /// one on no value.
    private static let unnamedReceiver = ""

    /// `["a", "b", "c"]` for `a.b.c()`, `a?.b!.c()` and `a.b<Int>.c()`, and `["foo", "bar", "baz"]` for
    /// `foo().bar().baz()`.
    static func path(of expression: some SyntaxProtocol) -> [String] {
        let node = Syntax(expression)
        if let reference = node.as(DeclReferenceExprSyntax.self) {
            return [reference.baseName.text.trimmingBackticks]
        }
        if node.is(SuperExprSyntax.self) { return ["super"] }
        if let member = node.as(MemberAccessExprSyntax.self) {
            let receiver = member.base.map { path(of: $0) } ?? []
            return (receiver.isEmpty ? [unnamedReceiver] : receiver) + [member.declName.baseName.text.trimmingBackticks]
        }
        if let inner = node.as(OptionalChainingExprSyntax.self)?.expression { return path(of: inner) }
        if let inner = node.as(ForceUnwrapExprSyntax.self)?.expression { return path(of: inner) }
        if let inner = node.as(GenericSpecializationExprSyntax.self)?.expression { return path(of: inner) }
        if let inner = node.as(FunctionCallExprSyntax.self)?.calledExpression { return path(of: inner) }
        if let inner = node.as(SubscriptCallExprSyntax.self)?.calledExpression { return path(of: inner) }
        if let tuple = node.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return path(of: only.expression)
        }
        return []
    }

    /// Whether `entry`, a name from `excludeCalls`, is in `path`, as whole names in a row. Anywhere in it, so `exit`
    /// keeps `editor.exit()`, and `log` keeps `log.debug()`, but not `logger.debug()`.
    static func excludeCallsEntry(_ entry: String, matches path: [String]) -> Bool {
        let names = normalised(entry)
        let path = path.first == "self" ? Array(path.dropFirst()) : path
        guard !names.isEmpty, names.count <= path.count else { return false }
        return (0 ... path.count - names.count).contains { Array(path[$0 ..< $0 + names.count]) == names }
    }

    private static func normalised(_ entry: String) -> [String] {
        let call = entry.prefix { $0 != "(" }
        let names = call.split(separator: ".").map { name in
            String(name).trimmingCharacters(in: ["?", "!", " "]).trimmingBackticks
        }
        return names.first == "self" ? Array(names.dropFirst()) : names
    }
}

private extension String {
    var trimmingBackticks: String { trimmingCharacters(in: ["`"]) }

    func trimmingCharacters(in characters: Set<Character>) -> String {
        var trimmed = Substring(self)
        while let first = trimmed.first, characters.contains(first) { trimmed.removeFirst() }
        while let last = trimmed.last, characters.contains(last) { trimmed.removeLast() }
        return String(trimmed)
    }
}

extension TypeSyntax {
    var isVoid: Bool {
        ["Void", "()", "Swift.Void"].contains(trimmedDescription)
    }

    /// The type's own name: `NSLock` for `Foundation.NSLock?`, `inout NSLock` and `OSAllocatedUnfairLock<Int>`.
    var lastName: String {
        if let attributed = self.as(AttributedTypeSyntax.self) { return attributed.baseType.lastName }
        let name = trimmedDescription.prefix { $0 != "<" && $0 != "?" && $0 != "!" }
        return name.split(separator: ".").last.map(String.init) ?? String(name)
    }
}
