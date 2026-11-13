import SwiftSyntax

extension SyntaxProtocol {
    /// Whether a call in it may throw, as Swift's coverage counts it: one in a `try` without `?`, outside the closures
    /// it holds but for their capture lists. One in a `try!` that threw would stop the tests, but Swift counts the
    /// times it threw all the same.
    var mayThrow: Bool {
        tokens(viewMode: .sourceAccurate).contains { token in
            guard token.tokenKind == .keyword(.try),
                  token.parent?.as(TryExprSyntax.self)?.questionOrExclamationMark?.text != "?"
            else {
                return false
            }
            // A closure's capture list runs where the closure is made.
            var ancestor = token.parent
            var isInACaptureList = false
            while let current = ancestor, current.id != Syntax(self).id {
                if current.is(ClosureCaptureClauseSyntax.self) {
                    isInACaptureList = true
                } else if current.is(ClosureExprSyntax.self) {
                    guard isInACaptureList else {
                        return false
                    }
                    isInACaptureList = false
                }
                ancestor = current.parent
            }
            return true
        }
    }
}

extension [ExprSyntax] {
    var mayThrow: Bool {
        contains(where: \.mayThrow)
    }
}
