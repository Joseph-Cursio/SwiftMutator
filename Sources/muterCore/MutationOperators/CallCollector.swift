import SwiftSyntax

/// Every call in a statement, those in its arguments and closures included, and the names it calls: each call's, and
/// each function passed by name, as `log` or `log(_:)` is in `events.forEach(log)`.
final class CallCollector: SyntaxVisitor {
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
