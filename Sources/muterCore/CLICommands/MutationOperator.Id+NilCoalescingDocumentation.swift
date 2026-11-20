import Rainbow

extension MutationOperator.Id {
    /// The replace nil coalescing operator's documentation.
    var replaceNilCoalescingDocumentation: String {
        """

        \("Replace Nil Coalescing".bold)

        The \("replace nil coalescing".italic) operator will replace a nil-coalescing expression, \(
            "a ?? b".onCodeEscape), with its fallback, \("b".onCodeEscape).
        Each \("??".onCodeEscape) of a chain gets its own mutant: \("a ?? b ?? c".onCodeEscape) becomes \(
            "b ?? c".onCodeEscape) and \("a ?? c".onCodeEscape).
        A fallback that takes its type from where it is, as a literal, \("nil".onCodeEscape), an implicit member \
        such as \(
            ".zero".onCodeEscape) or a closure does, is left alone where the expression is the whole value of a \(
            "let".onCodeEscape) or \("var".onCodeEscape) with no type written, an \("if let".onCodeEscape) or \(
            "guard let".onCodeEscape), or what a \("for".onCodeEscape) loop goes over; and, for one with no type of \
        its own, as \("[]".onCodeEscape), a member's base, as in \("(x ?? []).sorted()".onCodeEscape), or what a \
        closure with no return type written gives.
        So is one that would leave a \("try".onCodeEscape) or \("await".onCodeEscape) over no call, and one that is \
        what the expression is assigned to, as in \("one = other.one ?? one".onCodeEscape).

        The purpose of this operator is to highlight whether your tests see the value both nil and not nil.

        \("Mutating a nil-coalescing expression".bold)

        \(
            """
            \("return".asKeyword) user.nickname \("??".asKeyword) user.fullName
            """.onCodeBlock
        )

        becomes

        \(
            """
            \("return".asKeyword) user.fullName
            """.onCodeBlock
        )
        """
    }
}
