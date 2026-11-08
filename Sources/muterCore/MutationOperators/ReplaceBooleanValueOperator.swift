import SwiftOperators
import SwiftSyntax

/// Replaces a Bool value with `true`, and in a second mutant with `false`, as PIT's TRUE_RETURNS and FALSE_RETURNS do,
/// so the pair survives unless the tests see the value both ways. A value is what a `return` gives, the one expression
/// of a body that returns it, or a `let` or `var`'s initial value. The tree has no types, so a value counts when its
/// type is written as `Bool`, or when the last thing it works out is a comparison, `&&`, `||` or `!` and the type
/// written, if any, is an optional Bool. Under any other type written, the operator is an overload that gives that
/// type.
enum ReplaceBooleanValueOperator {
    final class Visitor: MuterVisitor {
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
                  let site = value.booleanValueSite,
                  value.counts(asABooleanWrittenAs: site.writtenType)
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

        /// The literal in place of `value`, with the trivia on either side of it left outside: a `//` comment after the
        /// value stays a comment. A space keeps the literal apart from a name or keyword it would otherwise touch, as
        /// in `return(a < b)`, which would become `returntrue`.
        private func replacement(of value: ExprSyntax, with keyword: Keyword) -> ExprSyntax {
            let previous = value.previousToken(viewMode: .sourceAccurate)
            let next = value.nextToken(viewMode: .sourceAccurate)
            let touchesThePrevious = value.leadingTrivia.isEmpty && previous?.trailingTrivia.isEmpty == true
                && previous?.text.last.map(\.isPartOfAName) == true
            let touchesTheNext = value.trailingTrivia.isEmpty && next?.leadingTrivia.isEmpty == true
                && next?.text.first.map(\.isPartOfAName) == true
            let literal = BooleanLiteralExprSyntax(literal: .keyword(
                keyword,
                leadingTrivia: touchesThePrevious ? .space : value.leadingTrivia,
                trailingTrivia: touchesTheNext ? .space : value.trailingTrivia
            ))
            return ExprSyntax(literal)
        }
    }
}

/// Where a value could be a Bool that a caller or a later line reads: what a body returns, or a binding's initial
/// value.
private struct BooleanValueSite {
    /// The type written for the value: the return type of what returns it, or the binding's annotation. Nil when the
    /// binding has none.
    let writtenType: TypeSyntax?
}

private extension ExprSyntax {
    /// Where this value is one of the operator's sites, or nil: the value of a `return`, or the one expression of a
    /// body, of a function, a getter or a closure whose signature writes its return type; or the initial value of a
    /// `let` or `var` of one name. A closure that leaves its type to be inferred is mostly a predicate passed to
    /// `filter`, `sorted` or `contains`, and is left out. So are `if let`, `guard let` and `case let`, a tuple's
    /// names, and an assignment.
    var booleanValueSite: BooleanValueSite? {
        guard let parent else { return nil }
        if let statement = parent.as(ReturnStmtSyntax.self) {
            return statement.returnTypeOfItsBody.map(BooleanValueSite.init)
        }
        if let item = parent.as(CodeBlockItemSyntax.self), let list = item.parent?.as(CodeBlockItemListSyntax.self),
           list.count == 1, let body = list.bodyOwner {
            return body.writtenReturnType.map(BooleanValueSite.init)
        }
        if let clause = parent.as(InitializerClauseSyntax.self),
           let binding = clause.parent?.as(PatternBindingSyntax.self),
           binding.pattern.is(IdentifierPatternSyntax.self) {
            return BooleanValueSite(writtenType: binding.typeAnnotation?.type)
        }
        return nil
    }

    /// Whether this value is a Bool, as far as the code shows: its type is written as `Bool`, or what it works out last
    /// is a comparison, `&&`, `||` or `!` and no type is written, or an optional Bool is. Any other type written says
    /// the operator is an overload that gives that type, as a query builder's `==` does. A literal is
    /// `FlipBooleanLiteral`'s, and an `if` or `switch` expression is left alone, and so are its branches, which aren't
    /// sites of their own.
    func counts(asABooleanWrittenAs writtenType: TypeSyntax?) -> Bool {
        let core = withoutWrapping
        guard !core.is(BooleanLiteralExprSyntax.self), !core.is(IfExprSyntax.self), !core.is(SwitchExprSyntax.self)
        else {
            return false
        }
        guard let writtenType else { return core.isMadeABoolByItsOperator }
        return writtenType.isBool || writtenType.isOptionalBool && core.isMadeABoolByItsOperator
    }

    /// The expression inside any parentheses, `try`, `try!` and `await` around it, with its operators folded, so that
    /// the last thing it works out is on top. `try?` makes an optional, and is kept. A sequence whose operators the
    /// standard table doesn't hold is left as it is, as their precedence isn't known.
    var withoutWrapping: ExprSyntax {
        var expression = self
        while true {
            if let sequence = expression.as(SequenceExprSyntax.self),
               let folded = try? OperatorTable.standardOperators.foldSingle(sequence),
               !folded.is(SequenceExprSyntax.self) {
                expression = folded
            } else if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
                      let only = tuple.elements.first, only.label == nil {
                expression = only.expression
            } else if let attempt = expression.as(TryExprSyntax.self), attempt.questionOrExclamationMark?.text != "?" {
                expression = attempt.expression
            } else if let wait = expression.as(AwaitExprSyntax.self) {
                expression = wait.expression
            } else {
                return expression
            }
        }
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

private extension ReturnStmtSyntax {
    /// The return type written for the function, getter or closure this `return` leaves, or nil when it has none: a
    /// `return` in a closure that leaves its type to be inferred is that closure's, whatever is around it.
    var returnTypeOfItsBody: TypeSyntax? {
        var ancestor = parent
        while let current = ancestor {
            if current.leavesOnReturn {
                return current.writtenReturnType
            }
            ancestor = current.parent
        }
        return nil
    }
}

private extension CodeBlockItemListSyntax {
    /// What this list is the body of, when that is a function, an accessor or a closure, which returns its one
    /// expression; nil for any other list, as an `if`'s or a `do`'s.
    var bodyOwner: Syntax? {
        guard let parent else { return nil }
        if parent.is(ClosureExprSyntax.self) || parent.is(AccessorBlockSyntax.self) {
            return parent
        }
        guard parent.is(CodeBlockSyntax.self), let owner = parent.parent, owner.leavesOnReturn else { return nil }
        return owner
    }
}

private extension Syntax {
    /// Whether a `return` inside this, and nowhere deeper, leaves this: a function, an initializer, an accessor, a
    /// getter's statements or a closure.
    var leavesOnReturn: Bool {
        `is`(FunctionDeclSyntax.self) || `is`(ClosureExprSyntax.self) || `is`(AccessorDeclSyntax.self)
            || `is`(AccessorBlockSyntax.self) || `is`(InitializerDeclSyntax.self) || `is`(DeinitializerDeclSyntax.self)
    }

    /// The return type written for this function, getter, subscript or closure. Nil for one that returns nothing, as
    /// an initializer, a setter or a `didSet` does, and for a closure that doesn't write its type.
    var writtenReturnType: TypeSyntax? {
        if let function = self.as(FunctionDeclSyntax.self) {
            return function.signature.returnClause?.type
        }
        if let closure = self.as(ClosureExprSyntax.self) {
            return closure.signature?.returnClause?.type
        }
        if let accessor = self.as(AccessorDeclSyntax.self) {
            guard accessor.accessorSpecifier.tokenKind == .keyword(.get),
                  let block = accessor.parent?.parent?.as(AccessorBlockSyntax.self)
            else { return nil }
            return block.typeOfItsValue
        }
        return self.as(AccessorBlockSyntax.self)?.typeOfItsValue
    }
}

private extension AccessorBlockSyntax {
    /// The type of the property or subscript whose accessors these are.
    var typeOfItsValue: TypeSyntax? {
        if let binding = parent?.as(PatternBindingSyntax.self) {
            return binding.typeAnnotation?.type
        }
        return parent?.as(SubscriptDeclSyntax.self)?.returnClause.type
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

private extension Character {
    /// Whether this can be part of a name or a keyword, which a literal next to it would join.
    var isPartOfAName: Bool {
        isLetter || isNumber || self == "_" || self == "$"
    }
}
