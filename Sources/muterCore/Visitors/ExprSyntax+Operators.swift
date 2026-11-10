import SwiftSyntax

extension ExprSyntax {
    /// `=`, or a standard operator such as `+=` that binds as loosely.
    var isAssignment: Bool {
        if self.is(AssignmentExprSyntax.self) {
            return true
        }
        guard let text = self.as(BinaryOperatorExprSyntax.self)?.operator.text else {
            return false
        }
        return Self.compoundAssignments.contains(text)
    }

    /// An operator that a project declared, which may bind more loosely than a ternary, or take a closure.
    var isDeclaredOperator: Bool {
        guard let text = self.as(BinaryOperatorExprSyntax.self)?.operator.text else {
            return false
        }
        return !Self.standardOperators.contains(text)
    }

    private static let compoundAssignments: Set<String> = [
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "&+=", "&-=", "&*=", "&<<=", "&>>=", ".&=", ".|=",
        ".^=",
    ]

    private static let standardOperators: Set<String> = [
        "==", "!=", "<=", ">=", "===", "!==", ".==", ".!=", ".<=", ".>=", "<", ">", ".<", ".>", "~=", "+", "-", "*",
        "/", "%", "&", "|", "^", "<<", ">>", "&+", "&-", "&*", "&<<", "&>>", ".&", ".|", ".^", "..<", "...", "??",
        "&&", "||",
    ]
}
