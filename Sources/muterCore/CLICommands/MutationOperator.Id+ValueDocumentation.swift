import Rainbow

extension MutationOperator.Id {
    /// The change arithmetic operator's documentation.
    var arithmeticOperatorDocumentation: String {
        """

        \("Change Arithmetic Operator".bold)

        This operator will change arithmetic operators in your code based on this table:

        +-------------------+------------------+
        | Original Operator | Changed Operator |
        +-------------------+------------------+
        |        \(" + ".onCodeEscape)        |        \(" - ".onCodeEscape)       |
        |        \(" - ".onCodeEscape)        |        \(" + ".onCodeEscape)       |
        |        \(" * ".onCodeEscape)        |        \(" / ".onCodeEscape)       |
        |        \(" / ".onCodeEscape)        |        \(" * ".onCodeEscape)       |
        |        \(" % ".onCodeEscape)        |        \(" * ".onCodeEscape)       |
        |       \(" += ".onCodeEscape)        |       \(" -= ".onCodeEscape)       |
        |       \(" -= ".onCodeEscape)        |       \(" += ".onCodeEscape)       |
        |       \(" *= ".onCodeEscape)        |       \(" /= ".onCodeEscape)       |
        |       \(" /= ".onCodeEscape)        |       \(" *= ".onCodeEscape)       |
        |       \(" %= ".onCodeEscape)        |       \(" *= ".onCodeEscape)       |
        +-------------------+------------------+

        \("+".onCodeEscape) and \("+=".onCodeEscape) also join strings and arrays, so they change only with a sign \
        of numbers beside them: a numeric literal, a name such as \(
            "items.count".onCodeEscape), or an arithmetic operator other than those two.
        One that changes nothing, as in \("x * 1".onCodeEscape), is left alone.

        The purpose of this operator is to highlight whether your tests check the value a calculation gives.

        \("Mutating a calculation".bold)

        \(
            """
            \("let".asKeyword) next = index + \("1".asTypeDeclaration)
            """.onCodeBlock
        )

        becomes

        \(
            """
            \("let".asKeyword) next = index - \("1".asTypeDeclaration)
            """.onCodeBlock
        )
        """
    }

    /// The flip boolean literal operator's documentation.
    var flipBooleanLiteralDocumentation: String {
        """

        \("Flip Boolean Literal".bold)

        The \("flip boolean literal".italic) operator will turn \("true".onCodeEscape) into \
        \("false".onCodeEscape) and \(
            "false".onCodeEscape) into \("true".onCodeEscape).
        A literal that is a whole condition, as in \("while true".onCodeEscape), or in a pattern, as in \(
            "case true:".onCodeEscape), is left alone, as a flipped one often doesn't compile.

        The purpose of this operator is to highlight whether your tests check the values your code gives and is \
        given.

        \("Mutating a literal".bold)

        \(
            """
            \("return".asKeyword) \("true".asKeyword)
            """.onCodeBlock
        )

        becomes

        \(
            """
            \("return".asKeyword) \("false".asKeyword)
            """.onCodeBlock
        )
        """
    }

    /// The replace boolean value operator's documentation.
    var replaceBooleanValueDocumentation: String {
        """

        \("Replace Boolean Value".bold)

        The \("replace boolean value".italic) operator will replace a Bool value with \(
            "true".onCodeEscape), and in a second mutant with \("false".onCodeEscape).
        A value is what a \("return".onCodeEscape) gives, the one expression of a body that returns it, or the \
        initial value of a \(
            "let".onCodeEscape) or \("var".onCodeEscape).
        It counts when its type is written as \("Bool".onCodeEscape), or when it is a comparison, \(
            "&&".onCodeEscape), \("||".onCodeEscape) or \("!".onCodeEscape).
        While the relational operator replacement operator is on, a comparison, as \(
            "return a < b".onCodeEscape), is left to that operator's constants.
        A literal, an \("if".onCodeEscape) or \("switch".onCodeEscape) expression, and a closure that doesn't \
        write its return type are left alone.

        The purpose of this operator is to highlight whether your tests see a value both true and false.

        \("Mutating a value".bold)

        \(
            """
            \("return".asKeyword) items.isEmpty
            """.onCodeBlock
        )

        becomes

        \(
            """
            \("return".asKeyword) \("true".asKeyword)
            """.onCodeBlock
        )

        and

        \(
            """
            \("return".asKeyword) \("false".asKeyword)
            """.onCodeBlock
        )
        """
    }

    /// The replace return value operator's documentation.
    var replaceReturnValueDocumentation: String {
        """

        \("Replace Return Value".bold)

        The \("replace return value".italic) operator will replace what a body returns with an empty value of its \
        written return type: \(
            "nil".onCodeEscape) for an optional, \("[]".onCodeEscape) for an array or a set, \(
            "[:]".onCodeEscape) for a dictionary, \("\"\"".onCodeEscape) for a string and \("0".onCodeEscape) for \
        a number.
        A value is what a \("return".onCodeEscape) gives, or the one expression of a body that returns it.
        A type written in any other way, as a \("some".onCodeEscape) type, a typealias or a generic parameter, \
        gets no mutant, nor does \(
            "Bool".onCodeEscape), which the replace boolean value operator replaces.
        A value that already is the empty one, an \("if".onCodeEscape) or \("switch".onCodeEscape) expression, and \
        a closure that doesn't write its return type are left alone.

        The purpose of this operator is to highlight whether your tests check what your code returns.

        \("Mutating a return value".bold)

        \(
            """
            \("return".asKeyword) items.filter { $0.isReady }
            """.onCodeBlock
        )

        becomes

        \(
            """
            \("return".asKeyword) []
            """.onCodeBlock
        )
        """
    }
}
