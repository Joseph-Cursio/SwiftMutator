import SwiftSyntax

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
