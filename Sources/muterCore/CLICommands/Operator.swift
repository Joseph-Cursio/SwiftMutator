import ArgumentParser
import Foundation
import Rainbow

public struct Operator: AsyncParsableCommand {

    public static let configuration = CommandConfiguration(
        commandName: "operator",
        abstract: "Describes a given mutation operator."
    )

    @Argument(
        help: """
            Available operators are: \(MutationOperator.Id.description)
            For all operators use: \("all".italic)
        """
    )
    var `operator`: String

    public init() {}

    public mutating func run() async throws {
        @Dependency(\.printer) var print: Printer
        if `operator`.trimmed == "all" {
            print(MutationOperator.Id.allCases.map(\.documentation).joined(separator: "\n\n"))
            return
        }

        guard let mutationOperator = MutationOperator.Id(rawValue: `operator`) else {
            throw MuterError.literal(reason: MutationOperator.Id.description)
        }

        print(mutationOperator.documentation)
    }
}

extension MutationOperator.Id {
    /// What `swift-mutator operator` prints for the operator.
    var documentation: String {
        switch self {
        case .logicalOperator:
            return """

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

        case .removeSideEffects:
            return """

            \("Remove Side Effects".bold)

            The \("remove side effects".italic) operator will remove code it determines is causing a side effect.
            It will determine your code is causing a side effect based on a few rules:
                • A line contains a function call which is explicitly discarding a return result.
                • A line contains a function call and doesn't save the result of the function call into a named variable or constant (i.e. a line implicitly discards a return result or doesn't produce one), under \("try".onCodeEscape) or \("await".onCodeEscape) or not.
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
                • A line is not the last of code whose end control must never reach, where only a call that never returns can be: a \(
                    "guard".onCodeEscape) body, a function or getter that returns a value but for a result builder, or a \(
                    "do".onCodeEscape), \("catch".onCodeEscape), \("if".onCodeEscape), \("case".onCodeEscape) or \(
                    "#if".onCodeEscape) that ends one of those.
                • A line is not one whose removal would leave code that doesn't build: the one line of a closure, getter or function that may be its value, a branch of an \(
                    "if".onCodeEscape) or \("switch".onCodeEscape) that is a value, the last line definite initialization may rely on, or in a result builder a part that makes a value of a type, as \(
                    "Text(\"a\")".onCodeEscape) does. Nothing is removed from a builder that takes no \(
                    "if".onCodeEscape), as \("SceneBuilder".onCodeEscape) and \("RegexComponentBuilder".onCodeEscape) don't.
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

        case .ror:
            return """

            \("Relational Operator Replacement".bold)

            The \(
                "relational operator replacement"
                    .italic
            ) operator gives each comparison the mutants of Kaminski, Ammann and Offutt's sufficient set, based on this table:

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
            For an ordering comparison, with the relational boundary operator's \("<".onCodeEscape) to \("<=".onCodeEscape), tests that kill these mutants kill every other mutant of the comparison's operator.
            An equality check gets both constants in place of the paper's \("<=".onCodeEscape) and \(">=".onCodeEscape), which need \("Comparable".onCodeEscape).
            A comparison that is a statement of its own, holds an operator of the project's own precedence, or holds a closure's only \(
                "$0".onCodeEscape), gets no constant, and its operator is swapped, \("==".onCodeEscape) to \("!=".onCodeEscape) too.
            A comparison that decides a \("while".onCodeEscape) or \("repeat".onCodeEscape)-\("while".onCodeEscape) condition gets no constant that would keep the loop going until the time limit, which counts as a survivor.

            The purpose of this operator is to highlight whether your tests see each comparison both true and false, and check the values on either side of it.

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

        case .relationalBoundary:
            return """

            \("Relational Boundary".bold)

            The \("relational boundary".italic) operator will move the boundary of an ordering comparison based on this table:

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

        case .negateConditional:
            return """

            \("Negate Conditional".bold)

            The \("negate conditional".italic) operator will wrap each expression condition of an \("if".onCodeEscape), \(
                "guard".onCodeEscape) or \("while".onCodeEscape) in \("!( )".onCodeEscape).
            Conditions that aren't expressions, such as \("if let".onCodeEscape), \("case".onCodeEscape) and \(
                "#available".onCodeEscape), are left alone, and so are the literals \("true".onCodeEscape) and \(
                "false".onCodeEscape).
            While the relational operator replacement operator is on, so is a condition that is one comparison, as \(
                "a < b".onCodeEscape), whose constant that operator gives.

            The purpose of this operator is to highlight whether your tests tell the two branches apart.
            A negated \("while".onCodeEscape) condition can loop until the mutant's time limit, which counts as a survivor.

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

        case .arithmeticOperator:
            return """

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

            \("+".onCodeEscape) and \("+=".onCodeEscape) also join strings and arrays, so they change only with a sign of numbers beside them: a numeric literal, a name such as \(
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

        case .flipBooleanLiteral:
            return """

            \("Flip Boolean Literal".bold)

            The \("flip boolean literal".italic) operator will turn \("true".onCodeEscape) into \("false".onCodeEscape) and \(
                "false".onCodeEscape) into \("true".onCodeEscape).
            A literal that is a whole condition, as in \("while true".onCodeEscape), or in a pattern, as in \(
                "case true:".onCodeEscape), is left alone, as a flipped one often doesn't compile.

            The purpose of this operator is to highlight whether your tests check the values your code gives and is given.

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

        case .replaceBooleanValue:
            return """

            \("Replace Boolean Value".bold)

            The \("replace boolean value".italic) operator will replace a Bool value with \(
                "true".onCodeEscape), and in a second mutant with \("false".onCodeEscape).
            A value is what a \("return".onCodeEscape) gives, the one expression of a body that returns it, or the initial value of a \(
                "let".onCodeEscape) or \("var".onCodeEscape).
            It counts when its type is written as \("Bool".onCodeEscape), or when it is a comparison, \(
                "&&".onCodeEscape), \("||".onCodeEscape) or \("!".onCodeEscape).
            While the relational operator replacement operator is on, a comparison, as \(
                "return a < b".onCodeEscape), is left to that operator's constants.
            A literal, an \("if".onCodeEscape) or \("switch".onCodeEscape) expression, and a closure that doesn't write its return type are left alone.

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

        case .replaceReturnValue:
            return """

            \("Replace Return Value".bold)

            The \("replace return value".italic) operator will replace what a body returns with an empty value of its written return type: \(
                "nil".onCodeEscape) for an optional, \("[]".onCodeEscape) for an array or a set, \(
                "[:]".onCodeEscape) for a dictionary, \("\"\"".onCodeEscape) for a string and \("0".onCodeEscape) for a number.
            A value is what a \("return".onCodeEscape) gives, or the one expression of a body that returns it.
            A type written in any other way, as a \("some".onCodeEscape) type, a typealias or a generic parameter, gets no mutant, nor does \(
                "Bool".onCodeEscape), which the replace boolean value operator replaces.
            A value that already is the empty one, an \("if".onCodeEscape) or \("switch".onCodeEscape) expression, and a closure that doesn't write its return type are left alone.

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

        case .swapTernary:
            return """

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
}

private extension String {
    var asKeyword: String {
        hex("#FF7B72")
    }

    var asDeclaration: String {
        hex("#D2A8FE")
    }

    var asTypeDeclaration: String {
        hex("#79C0FF")
    }

    var onCodeEscape: String {
        onHex("#343940")
    }

    var onCodeBlock: String {
        onHex("#161B22")
    }

    var asComment: String {
        hex("#50575F")
    }
}
