import Rainbow

extension MutationOperator.Id {
    /// The relational operator replacement operator's documentation.
    var rorDocumentation: String {
        """

        \("Relational Operator Replacement".bold)

        The \(
            "relational operator replacement"
                .italic
        ) operator gives each comparison the mutants of Kaminski, Ammann and Offutt's sufficient set, based on \
        this table:

        +-------------------+------------+----------------+
        | Original Operator | Swapped to |    Constant    |
        +-------------------+------------+----------------+
        |        \(" < ".onCodeEscape)        |    \(" != ".onCodeEscape)    |    \(" false ".onCodeEscape)     |
        |       \(" <= ".onCodeEscape)        |    \(" == ".onCodeEscape)    |     \(" true ".onCodeEscape)     |
        |        \(" > ".onCodeEscape)        |    \(" != ".onCodeEscape)    |    \(" false ".onCodeEscape)     |
        |       \(" >= ".onCodeEscape)        |    \(" == ".onCodeEscape)    |     \(" true ".onCodeEscape)     |
        |       \(" == ".onCodeEscape)        |            | \(" true, false ".onCodeEscape)  |
        |       \(" != ".onCodeEscape)        |            | \(" false, true ".onCodeEscape)  |
        +-------------------+------------+----------------+

        A constant replaces the whole comparison, so \("a + 1 < b".onCodeEscape) becomes \("false".onCodeEscape).
        For an ordering comparison, with the relational boundary operator's \("<".onCodeEscape) to \
        \("<=".onCodeEscape), tests that kill these mutants kill every other mutant of the comparison's operator.
        An equality check gets both constants in place of the paper's \("<=".onCodeEscape) and \
        \(">=".onCodeEscape), which need \("Comparable".onCodeEscape).
        A comparison that is a statement of its own, holds an operator of the project's own precedence, or holds a \
        closure's only \(
            "$0".onCodeEscape), gets no constant, and its operator is swapped, \("==".onCodeEscape) to \
        \("!=".onCodeEscape) too.
        A comparison that decides a \("while".onCodeEscape) or \("repeat".onCodeEscape)-\("while".onCodeEscape) \
        condition gets no constant that would keep the loop going until the time limit, which counts as a survivor.

        The purpose of this operator is to highlight whether your tests see each comparison both true and false, \
        and check the values on either side of it.

        \("Mutating an equality check".bold)

        \(
            """
            \("if".asKeyword) myValue == \("50".asTypeDeclaration) {
                \("// something happens here".asComment)
            }
            """.onCodeBlock
        )

        becomes

        \(
            """
            \("if".asKeyword) \("true".asKeyword) {
                \("// something happens here".asComment)
            }
            """.onCodeBlock
        )

        and

        \(
            """
            \("if".asKeyword) \("false".asKeyword) {
                \("// something happens here".asComment)
            }
            """.onCodeBlock
        )

        \("Mutating an ordering comparison".bold)

        \(
            """
            \("return".asKeyword) count < limit
            """.onCodeBlock
        )

        becomes

        \(
            """
            \("return".asKeyword) count != limit
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

    /// The relational boundary operator's documentation.
    var relationalBoundaryDocumentation: String {
        """

        \("Relational Boundary".bold)

        The \("relational boundary".italic) operator will move the boundary of an ordering comparison based on \
        this table:

        +-------------------+------------------+
        | Original Operator | Changed Operator |
        +-------------------+------------------+
        |        \(" < ".onCodeEscape)        |       \(" <= ".onCodeEscape)       |
        |       \(" <= ".onCodeEscape)        |        \(" < ".onCodeEscape)       |
        |        \(" > ".onCodeEscape)        |       \(" >= ".onCodeEscape)       |
        |       \(" >= ".onCodeEscape)        |        \(" > ".onCodeEscape)       |
        +-------------------+------------------+

        The purpose of this operator is to highlight whether your tests check the edge of each comparison.
        Such a mutant survives unless some test uses the value at the boundary, where the two operators differ.

        \("Mutating a boundary".bold)

        \(
            """
            \("if".asKeyword) count < \("10".asTypeDeclaration) {
                \("// something happens here".asComment)
            }
            """.onCodeBlock
        )

        becomes

        \(
            """
            \("if".asKeyword) count <= \("10".asTypeDeclaration) {
                \("// something happens here".asComment)
            }
            """.onCodeBlock
        )
        """
    }

    /// The negate conditional operator's documentation.
    var negateConditionalDocumentation: String {
        """

        \("Negate Conditional".bold)

        The \("negate conditional".italic) operator will wrap each expression condition of an \
        \("if".onCodeEscape), \(
            "guard".onCodeEscape) or \("while".onCodeEscape) in \("!( )".onCodeEscape).
        Conditions that aren't expressions, such as \("if let".onCodeEscape), \("case".onCodeEscape) and \(
            "#available".onCodeEscape), are left alone, and so are the literals \("true".onCodeEscape) and \(
            "false".onCodeEscape).
        While the relational operator replacement operator is on, so is a condition that is one comparison, as \(
            "a < b".onCodeEscape), whose constant that operator gives.

        The purpose of this operator is to highlight whether your tests tell the two branches apart.
        A negated \("while".onCodeEscape) condition can loop until the mutant's time limit, which counts as a \
        survivor.

        \("Mutating a condition".bold)

        \(
            """
            \("if".asKeyword) isValid && !isEmpty {
                \("// something happens here".asComment)
            }
            """.onCodeBlock
        )

        becomes

        \(
            """
            \("if".asKeyword) !(isValid && !isEmpty) {
                \("// something happens here".asComment)
            }
            """.onCodeBlock
        )
        """
    }
}
