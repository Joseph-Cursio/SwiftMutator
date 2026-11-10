import SwiftSyntax

/// Replaces a Bool value with `true`, and in a second mutant with `false`, as PIT's TRUE_RETURNS and FALSE_RETURNS do,
/// so the pair survives unless the tests see the value both ways. A value is what a `return` gives, the one expression
/// of a body that returns it, or a `let` or `var`'s initial value. The tree has no types, so a value counts when its
/// type is written as `Bool`, or when the last thing it works out is a comparison, `&&`, `||` or `!` and the type
/// written, if any, is an optional Bool. Under any other type written, the operator is an overload that gives that
/// type.
enum ReplaceBooleanValueOperator {
    final class Visitor: MuterVisitor {
        /// Whether to leave a value whose last operator is a comparison, `==`, `!=`, `<`, `<=`, `>` or `>=`, alone, as
        /// RelationalOperatorReplacement replaces such a comparison with its constants, which with the swap it gives
        /// an ordering comparison stand for this pair (`ROROperator.comparisonGivenAConstant(in:)`). Set when that
        /// operator is on, but not for `--mutant`, which discovers every operator and must still find the mutant a run
        /// with this operator alone reported.
        var leavesComparisonsAlone = false

        convenience init(
            configuration: MuterConfiguration? = nil,
            sourceCodeInfo: SourceCodeInfo,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                configuration: configuration,
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .replaceBooleanValue,
                coverage: coverage
            )
        }

        override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
            // First, as this reads a `muter:disable` comment beside the value, which is meant for it. Told to skip its
            // children, this is a `#if`'s whole condition, which no operator mutates.
            let next = super.visitAny(node)
            guard next == .visitChildren,
                  let value = node.as(ExprSyntax.self),
                  let site = value.valueSite,
                  value.counts(asABooleanWrittenAs: site.writtenType),
                  !isLeftToRelationalOperatorReplacement(value)
            else {
                return next
            }

            let before = value.trimmedDescription.inlined
            // `true` where the value starts, and `false` where it ends, so that each mutant has a place, and so a
            // switch, of its own: two mutants of one operator at one place share a switch, and can't be told apart.
            let mutants: [(keyword: Keyword, position: MutationPosition)] = [
                (.true, startLocation(for: value, afterLeadingTrivia: true)),
                (.false, endLocation(for: value, afterTrailingTrivia: false)),
            ]
            // The pair is one value's: a directive that leaves out where either is placed leaves out both.
            guard !mutants.contains(where: { isLeftOutByADirective($0.position, in: value.root) }) else { return next }
            for (keyword, position) in mutants {
                let after = keyword == .true ? "true" : "false"
                add(
                    mutation: replacement(of: value, with: keyword),
                    with: value,
                    at: position,
                    snapshot: MutationOperator.Snapshot(
                        before: before,
                        after: after,
                        description: "replaced the Bool with \(after)"
                    )
                )
            }
            return next
        }

        /// Whether RelationalOperatorReplacement's mutants of the comparison `value` ends with stand for this pair. Not
        /// when a directive leaves them out, which leaves out all of a comparison's mutants when it leaves out one.
        private func isLeftToRelationalOperatorReplacement(_ value: ExprSyntax) -> Bool {
            guard leavesComparisonsAlone, let comparison = ROROperator.comparisonGivenAConstant(in: value) else {
                return false
            }
            let places = placesOfTheMutants(ofTheComparisonWith: comparison)
            return !places.contains { isLeftOutByADirective($0, in: value.root) }
        }

        /// The literal in place of `value`, kept apart from a name or keyword it would otherwise touch
        /// (`ExprSyntax.replaced(by:)`).
        private func replacement(of value: ExprSyntax, with keyword: Keyword) -> ExprSyntax {
            value.replaced(by: ExprSyntax(BooleanLiteralExprSyntax(literal: .keyword(keyword))))
        }
    }
}

private extension ExprSyntax {
    /// Whether this value is a Bool, as far as the code shows: its type is written as `Bool`, or what it works out last
    /// is a comparison, `&&`, `||` or `!` and no type is written, or an optional Bool is. Any other type written says
    /// the operator is an overload that gives that type, as a query builder's `==` does. A literal is
    /// `FlipBooleanLiteral`'s, and an `if` or `switch` expression is left alone, and so are its branches, which aren't
    /// sites of their own.
    func counts(asABooleanWrittenAs writtenType: TypeSyntax?) -> Bool {
        let core = withoutValueWrapping
        guard !core.is(BooleanLiteralExprSyntax.self), !core.is(IfExprSyntax.self), !core.is(SwitchExprSyntax.self)
        else {
            return false
        }
        guard let writtenType else { return core.isMadeABoolByItsOperator }
        return writtenType.isBool || writtenType.isOptionalBool && core.isMadeABoolByItsOperator
    }

    /// Whether this folded expression is a comparison, `&&`, `||` or a prefix `!`, each of which gives a Bool from the
    /// standard library.
    var isMadeABoolByItsOperator: Bool {
        if let prefix = self.as(PrefixOperatorExprSyntax.self) {
            return prefix.operator.text == "!"
        }
        guard let infix = self.as(InfixOperatorExprSyntax.self),
              let name = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text
        else { return false }
        return ["==", "!=", "<", "<=", ">", ">=", "===", "!==", "&&", "||"].contains(name)
    }
}

private extension TypeSyntax {
    /// Whether this is written as `Bool` or `Swift.Bool`, in parentheses or not. An optional, a `some`, a typealias
    /// and a generic parameter are other types to the syntax tree, even when they hold a Bool.
    var isBool: Bool {
        Self.namesBool(Self.withoutOuterParentheses(trimmedDescription.filter { !$0.isWhitespace }))
    }

    /// Whether this is written as an optional Bool, `Bool?`, `Bool!` or `Optional<Bool>`, in parentheses or not, which
    /// an operator's Bool can be given as. Any other type written says the operator is an overload that gives that
    /// type.
    var isOptionalBool: Bool {
        let text = Self.withoutOuterParentheses(trimmedDescription.filter { !$0.isWhitespace })
        if text.hasSuffix("?") || text.hasSuffix("!") {
            return Self.namesBool(Self.withoutOuterParentheses(String(text.dropLast())))
        }
        for prefix in ["Optional<", "Swift.Optional<"] where text.hasPrefix(prefix) && text.hasSuffix(">") {
            return Self.namesBool(Self.withoutOuterParentheses(String(text.dropFirst(prefix.count).dropLast())))
        }
        return false
    }

    /// Whether `text`, with no whitespace or parentheses around it, names the standard library's Bool.
    private static func namesBool(_ text: String) -> Bool {
        ["Bool", "Swift.Bool"].contains(text)
    }

    /// `text` without the parentheses around all of it, as `(Bool)` is `Bool`.
    private static func withoutOuterParentheses(_ text: String) -> String {
        var text = text
        while text.count > 2, text.hasPrefix("("), text.hasSuffix(")") {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}
