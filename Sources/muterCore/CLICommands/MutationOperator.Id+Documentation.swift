import Rainbow

extension MutationOperator.Id {
    /// What `swift-mutator operator` prints for the operator.
    var documentation: String {
        switch self {
        case .logicalOperator:
            logicalOperatorDocumentation

        case .removeSideEffects:
            removeSideEffectsDocumentation

        case .ror:
            rorDocumentation

        case .relationalBoundary:
            relationalBoundaryDocumentation

        case .negateConditional:
            negateConditionalDocumentation

        case .arithmeticOperator:
            arithmeticOperatorDocumentation

        case .flipBooleanLiteral:
            flipBooleanLiteralDocumentation

        case .replaceBooleanValue:
            replaceBooleanValueDocumentation

        case .replaceReturnValue:
            replaceReturnValueDocumentation

        case .swapTernary:
            swapTernaryDocumentation
        }
    }

    /// The change logical connector operator's documentation.
    private var logicalOperatorDocumentation: String {
        """

        \("Change Logical Connector".bold)

        The \(
            "change logical connector"
                .italic
        ) operator will change conditional operators in your code based on this table:

        +-------------------+------------------+
        | Original Operator | Changed Operator |
        +-------------------+------------------+
        |        \(" && ".onCodeEscape)       |       \(" || ".onCodeEscape)       |
        \(
            """
            +-------------------+------------------+
            |        \(" || ".onCodeEscape)       |       \(" && ".onCodeEscape)       |
            +-------------------+------------------+
            """.onCodeBlock
        )

        The purpose of this operator is to highlight how your tests respond to changes in logic.
        A well-engineered test suite will be able to fail clearly in response to different logical constraints.

        \("Mutating a Logical".bold) \("AND".bold.italic)

        \(
            """
            \("func".asKeyword) \("isValidPassword".asDeclaration)(\("_".asDeclaration) text: \("String"
                .asTypeDeclaration), \("_".asDeclaration) repeatedText: \("String".asTypeDeclaration) \("->"
                .asKeyword) \("Bool".asTypeDeclaration) {
                \("let".asKeyword) meetsMinimumLength \("=".asKeyword) text.\("count".asTypeDeclaration) \(">="
                .asKeyword) \("8".asTypeDeclaration)
                \("let".asKeyword) passwordsMatch \("=".asKeyword) repeatedText \("==".asKeyword) text
                \("return".asKeyword) meetsMinimumLength \("&&".asKeyword) passwordsMatch
            }
            """
                .onCodeBlock
        )

        becomes

        \(
            """
            \("func".asKeyword) \("isValidPassword".asDeclaration)(\("_".asDeclaration) text: \("String"
                .asTypeDeclaration), \("_".asDeclaration) repeatedText: \("String".asTypeDeclaration) \("->"
                .asKeyword) \("Bool".asTypeDeclaration) {
                \("let".asKeyword) meetsMinimumLength \("=".asKeyword) text.\("count".asTypeDeclaration) \(">="
                .asKeyword) \("8".asTypeDeclaration)
                \("let".asKeyword) passwordsMatch \("=".asKeyword) repeatedText \("==".asKeyword) text
                \("return".asKeyword) meetsMinimumLength \("||".asKeyword) passwordsMatch
            }
            """
                .onCodeBlock
        )

        """
    }

    /// The remove side effects operator's documentation.
    private var removeSideEffectsDocumentation: String {
        """

        \("Remove Side Effects".bold)

        The \("remove side effects".italic) operator will remove code it determines is causing a side effect.
        It will determine your code is causing a side effect based on a few rules:
            • A line contains a function call which is explicitly discarding a return result.
            • A line contains a function call and doesn't save the result of the function call into a named \
        variable or constant (i.e. a line implicitly discards a return result or doesn't produce one), under \
        \("try".onCodeEscape) or \("await".onCodeEscape) or not.
            • A line is in any body: a function's, an initializer's, an accessor's, a closure's, a loop's, an \(
                "if".onCodeEscape) or \("else".onCodeEscape) branch, a \("switch".onCodeEscape) case, a \(
                "defer".onCodeEscape) and so on, but not a file's top level or a \("#if".onCodeEscape) clause.
            • A line does not contain a call to \(
                RemoveSideEffectsOperator.Visitor.alwaysExcludedCalls.map(\.onCodeEscape).joined(separator: ", ")
            ), a call that takes or releases a lock, or a call to any function listed in \(
                "muter.conf.yml".onCodeEscape) under the \("excludeCalls".onCodeEscape) key.
              A call is matched by the name it is called by: \("print".onCodeEscape) matches \(
                "print(…)".onCodeEscape) and \("Swift.print(…)".onCodeEscape), but not \("printer.flush()"
                .onCodeEscape), and a function passed by name counts, as \("log".onCodeEscape) does in \(
                "events.forEach(log)".onCodeEscape).
            • A line is not the last of code whose end control must never reach, where only a call that never \
        returns can be: a \(
                "guard".onCodeEscape) body, a function or getter that returns a value but for a result builder, or \
        a \(
                "do".onCodeEscape), \("catch".onCodeEscape), \("if".onCodeEscape), \("case".onCodeEscape) or \(
                "#if".onCodeEscape) that ends one of those.
            • A line is not one whose removal would leave code that doesn't build: the one line of a closure, \
        getter or function that may be its value, a branch of an \(
                "if".onCodeEscape) or \("switch".onCodeEscape) that is a value, the last line definite \
        initialization may rely on, or in a result builder a part that makes a value of a type, as \(
                "Text(\"a\")".onCodeEscape) does. Nothing is removed from a builder that takes no \(
                "if".onCodeEscape), as \("SceneBuilder".onCodeEscape) and \("RegexComponentBuilder".onCodeEscape) \
        don't.
        The purpose of this operator is to highlight how your tests respond to the absence of expected side effects.

        \("Mutating an explicitly discarded return result".bold)

        \(
            """
            \("func".asKeyword) initialize() {
                \("_".asTypeDeclaration) \("=".asKeyword) \("self".asTypeDeclaration).view
                view.results \("=".asKeyword) \("self".asTypeDeclaration).results
            }
            """.onCodeBlock
        )

        becomes

        \(
            """
            \("func".asKeyword) initialize() {
                view.results \("=".asKeyword) \("self".asTypeDeclaration).results
            }
            """.onCodeBlock
        )

        \("Mutating a void function call".bold)

        \(
            """
            \("func".asKeyword) \("update".asDeclaration)(\("email".asDeclaration): \("String"
                .asTypeDeclaration), \("for".asDeclaration) userId: \("String".asTypeDeclaration) {
                \("var".asKeyword) userRecord = \("record".asTypeDeclaration)(\("for".asTypeDeclaration): userId)
                userRecord.email \("=".asKeyword) email
                database.\("persist".asTypeDeclaration)(userRecord)
            }
            """.onCodeBlock
        )

        becomes

        \(
            """
            \("func".asKeyword) \("update".asDeclaration)(\("email".asDeclaration): \("String"
                .asTypeDeclaration), \("for".asDeclaration) userId: \("String".asTypeDeclaration) {
                \("var".asKeyword) userRecord = \("record".asTypeDeclaration)(\("for".asTypeDeclaration): userId)
                userRecord.email \("=".asKeyword) email
            }
            """.onCodeBlock
        )
        """
    }

    /// The swap ternary operator's documentation.
    private var swapTernaryDocumentation: String {
        """

        \("Swap Ternary".bold)

        The \("swap ternary".italic) operator will swap ternary operators in your code based on this table:

        +---------------------------------------------+---------------------------------------------+
        |              Original Operator              |               Changed Operator              |
        +---------------------------------------------+---------------------------------------------+
        |\(
            " <condition> ? <expression1> : <expression2> "
                .onCodeEscape
        )|\(" <condition> ? <expression2> : <expression1> ".onCodeEscape)|
        +---------------------------------------------+---------------------------------------------+

        The purpose of this operator is to highlight how your tests respond to changes in logic.
        A well-engineered test suite will be able to fail clearly in response to different logical constraints.

        \("Mutating a ternary expression".bold)

        \(
            """
            \("func".asKeyword) \("stringify".asDeclaration)(\("_".asDeclaration) a: \("Bool"
                .asTypeDeclaration) \("->".asKeyword) \("String".asTypeDeclaration) {
                \("return".asKeyword) a \("?".asKeyword) \("\"true\"".asTypeDeclaration) : \("\"false\""
                .asTypeDeclaration)
            }
            """.onCodeBlock
        )

        becomes

        \(
            """
            \("func".asKeyword) \("stringify".asDeclaration)(\("_".asKeyword) a: \("Bool".asTypeDeclaration) \("->"
                .asKeyword) \("String".asTypeDeclaration) {
                \("return".asKeyword) a \("?".asKeyword) \("\"false\"".asTypeDeclaration) : \("\"true\""
                .asTypeDeclaration)
            }
            """.onCodeBlock
        )

        """
    }
}
