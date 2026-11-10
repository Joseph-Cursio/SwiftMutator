import Foundation
import SwiftSyntax

/// Every variable, property or parameter in a file that holds a lock: made by a call to a lock type's initializer, or
/// declared with that type, optional or not, generic or not.
final class LockCollector: SyntaxVisitor {
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
