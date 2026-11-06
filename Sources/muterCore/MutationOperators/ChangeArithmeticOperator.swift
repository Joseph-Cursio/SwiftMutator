import SwiftSyntax

/// Swaps an arithmetic operator for one at the same precedence: `+` and `-`, `*` and `/`, and `%` becomes `*`. Their
/// assignment forms change in the same way.
///
/// `+` and `+=` also join strings and arrays, which `-` can't take apart, and a syntax tree has no types. On
/// SwiftProjectLint so many of those mutants failed to compile that a run reached its limit of failed builds and
/// stopped. So `+` and `+=` get a mutant only with a sign that their operands are numbers
/// (`ExprListSyntax.showsNumbers(around:)`). The other operators are numbers' almost everywhere, and a mutant of one
/// that doesn't compile is left out at the cost of a rebuild.
enum ChangeArithmeticOperator {
    final class Visitor: TokenAwareVisitor {
        convenience init(
            configuration: MuterConfiguration? = nil,
            sourceCodeInfo: SourceCodeInfo,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                configuration: configuration,
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .arithmeticOperator,
                coverage: coverage
            )

            oppositeOperatorMapping = Self.changes
            tokensToDiscover = Self.changes.keys.map { .binaryOperator($0) }
        }

        private static let changes = [
            "+": "-",
            "-": "+",
            "*": "/",
            "/": "*",
            "%": "*",
            "+=": "-=",
            "-=": "+=",
            "*=": "/=",
            "/=": "*=",
            "%=": "*=",
        ]

        override func canMutate(_ node: BinaryOperatorExprSyntax) -> Bool {
            guard let list = node.parent?.as(ExprListSyntax.self),
                  let index = list.firstIndex(where: { $0.id == node.id })
            else {
                return false
            }

            let name = node.operator.text
            let next = list.index(after: index)
            let right = next < list.endIndex ? list[next] : nil
            // An assignment takes all that follows, so its literal is its whole operand only if nothing else does.
            let isAllOfAnAssignmentsOperand = !name.hasSuffix("=") || list.index(after: next) == list.endIndex
            return !list.holdsAStringOrArrayLiteral(around: index)
                && (!["+", "+="].contains(name) || list.showsNumbers(around: index))
                && !(right.map { isUnchangedOrInvalid(name, rightOperand: $0) } == true && isAllOfAnAssignmentsOperand)
                && !wouldJoinAComment(node.operator)
        }

        /// `x + 0` is `x - 0` and `x * 1` is `x / 1`, as is `x * -1` to `x / -1`, so a mutant of one gives the same
        /// value. And `x / 0` doesn't compile for an integer, though `x / 0.0` does for a float.
        private func isUnchangedOrInvalid(_ name: String, rightOperand: ExprSyntax) -> Bool {
            guard let value = rightOperand.numericLiteralValue else { return false }
            switch name {
            case "+", "-", "+=", "-=":
                return value == 0
            case "*", "*=":
                return abs(value) == 1 || (value == 0 && rightOperand.isAnIntegerLiteral)
            case "/", "/=":
                return abs(value) == 1
            default:
                return false
            }
        }

        /// `a */* why */ b` as `a //* why */ b` is a comment to the end of the line, and takes `b` with it.
        private func wouldJoinAComment(_ token: TokenSyntax) -> Bool {
            guard token.text == "*" else { return false }
            switch token.trailingTrivia.first {
            case .lineComment, .blockComment, .docLineComment, .docBlockComment:
                return true
            default:
                return false
            }
        }
    }
}

private extension ExprListSyntax {
    /// Whether the run of arithmetic around `index` holds a number: a numeric literal, a name that counts something,
    /// or an operator that only numbers take, as `-` in `a - b + c`. Any other operator ends the run, so the `1` of
    /// `a + b == 1` says nothing about `a + b`.
    ///
    /// An assignment takes all that follows, so the `count` of `text += count == 1 ? "" : "s"` isn't its operand. What
    /// follows it is a sign only if the run reaches the end.
    func showsNumbers(around index: Index) -> Bool {
        let before = self[..<index].reversed().prefix(while: \.isInAnArithmeticRun)
        if before.contains(where: \.showsANumber) {
            return true
        }
        let rest = self[self.index(after: index)...]
        let after = rest.prefix(while: \.isInAnArithmeticRun)
        let isAnAssignment = self[index].as(BinaryOperatorExprSyntax.self)?.operator.text == "+="
        return (!isAnAssignment || after.count == rest.count) && after.contains(where: \.showsANumber)
    }

    /// Whether the run around `index` can't be numbers', as in `"Total: " + count` or a path's `dir / name + ".swift"`.
    func holdsAStringOrArrayLiteral(around index: Index) -> Bool {
        self[..<index].reversed().prefix(while: \.isInAnArithmeticRun).contains(where: \.isAStringOrArrayLiteral)
            || self[self.index(after: index)...].prefix(while: \.isInAnArithmeticRun)
            .contains(where: \.isAStringOrArrayLiteral)
    }
}

private extension ExprSyntax {
    private static let arithmeticOperators: Set = ["+", "-", "*", "/", "%", "+=", "-=", "*=", "/=", "%="]

    /// An operand, or an operator that works out an operand. In an unfolded expression, operands and operators take
    /// turns, and an `as`, `is`, `=` or ternary is an element of its own.
    var isInAnArithmeticRun: Bool {
        if let binaryOperator = self.as(BinaryOperatorExprSyntax.self) {
            return Self.arithmeticOperators.contains(binaryOperator.operator.text)
        }
        return !self.is(AssignmentExprSyntax.self) && !self.is(UnresolvedTernaryExprSyntax.self)
            && !self.is(UnresolvedAsExprSyntax.self) && !self.is(UnresolvedIsExprSyntax.self)
    }

    /// Whether this element of a run shows that the run is numbers'.
    var showsANumber: Bool {
        if let binaryOperator = self.as(BinaryOperatorExprSyntax.self) {
            let name = binaryOperator.operator.text
            return Self.arithmeticOperators.contains(name) && !["+", "+="].contains(name)
        }
        if self.is(IntegerLiteralExprSyntax.self) || self.is(FloatLiteralExprSyntax.self) {
            return true
        }
        if let prefix = self.as(PrefixOperatorExprSyntax.self) {
            return prefix.operator.text == "-"
        }
        if let only = onlyElementInParentheses {
            return only.showsANumber
        }
        if let sequence = self.as(SequenceExprSyntax.self) {
            // All of it arithmetic: the `1` of `"item" + (n == 1 ? "" : "s")` says nothing about the `+`.
            return sequence.elements.allSatisfy(\.isInAnArithmeticRun)
                && sequence.elements.contains(where: \.showsANumber)
        }
        if let attempt = self.as(TryExprSyntax.self) {
            return attempt.expression.showsANumber
        }
        if let wait = self.as(AwaitExprSyntax.self) {
            return wait.expression.showsANumber
        }
        if let unsafe = self.as(UnsafeExprSyntax.self) {
            return unsafe.expression.showsANumber
        }
        if let unwrap = self.as(ForceUnwrapExprSyntax.self) {
            return unwrap.expression.showsANumber
        }
        return isACount
    }

    var isAStringOrArrayLiteral: Bool {
        onlyElementInParentheses?.isAStringOrArrayLiteral
            ?? (self.is(StringLiteralExprSyntax.self) || self.is(ArrayExprSyntax.self))
    }

    /// `items.count`, `count` or `lineCount`.
    private var isACount: Bool {
        let name = self.as(MemberAccessExprSyntax.self)?.declName.baseName.text
            ?? self.as(DeclReferenceExprSyntax.self)?.baseName.text
        return name == "count" || name?.hasSuffix("Count") == true
    }

    private var onlyElementInParentheses: ExprSyntax? {
        guard let tuple = self.as(TupleExprSyntax.self), tuple.elements.count == 1 else { return nil }
        return tuple.elements.first?.expression
    }

    var isAnIntegerLiteral: Bool {
        if let prefix = self.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-" {
            return prefix.expression.isAnIntegerLiteral
        }
        return onlyElementInParentheses?.isAnIntegerLiteral ?? self.is(IntegerLiteralExprSyntax.self)
    }

    /// What a literal gives, whatever its radix and however it's parenthesized, as in `1_000`, `0b0`, `(1)` or `-1`;
    /// nil for anything else.
    var numericLiteralValue: Double? {
        if let only = onlyElementInParentheses {
            return only.numericLiteralValue
        }
        if let prefix = self.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-" {
            return prefix.expression.numericLiteralValue.map { -$0 }
        }
        return self.as(IntegerLiteralExprSyntax.self)?.representedLiteralValue.map(Double.init)
            ?? self.as(FloatLiteralExprSyntax.self)?.representedLiteralValue
    }
}
