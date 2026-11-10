import Foundation
import SwiftSyntax

final class ValueReturnFinder: SyntaxAnyVisitor {
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
