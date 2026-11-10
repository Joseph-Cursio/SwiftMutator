import SwiftSyntax

extension InitializerClauseSyntax {
    /// Whether this is a `let` or `var`'s value or a parameter's default. Not an `if let`'s or an `if case`'s value,
    /// which belongs to its statement, nor an enum case's raw value, which has to be a literal.
    var isADeclarationsValue: Bool {
        parent?.is(PatternBindingSyntax.self) == true || isADefaultArgument
    }

    /// A default argument can't be an `if` expression, which the compiler allows only as a statement's value.
    var isADefaultArgument: Bool {
        parent?.is(FunctionParameterSyntax.self) == true || parent?.is(EnumCaseParameterSyntax.self) == true
    }

    /// Whether this value, or a type around it, has an attribute. The attribute can be a macro that copies the value
    /// into a call, as `@State`, `@TaskLocal` and `@Model` do, where an `if` expression doesn't compile.
    var isUnderAnAttribute: Bool {
        var ancestor = parent
        while let current = ancestor {
            if let declaration = current.asProtocol(WithAttributesSyntax.self), !declaration.attributes.isEmpty {
                return true
            }
            ancestor = current.parent
        }
        return false
    }

    /// A branch that starts with `#line` is read as the old form of `#sourceLocation`, and the result of a closure
    /// called on the spot can't be converted to a parameter's non-escaping function type.
    var canHoldASwitch: Bool {
        !value.trimmedDescription.hasPrefix("#line") && !isTheDefaultOfANonEscapingFunction
    }

    /// `() -> Int = …`. An `@escaping` one can take a closure's result, and an `@autoclosure` one's default is its
    /// value.
    private var isTheDefaultOfANonEscapingFunction: Bool {
        guard var type = parent?.as(FunctionParameterSyntax.self)?.type else { return false }
        while let attributed = type.as(AttributedTypeSyntax.self) {
            let names = attributed.attributes.compactMap {
                $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription
            }
            if names.contains("escaping") || names.contains("autoclosure") { return false }
            type = attributed.baseType
        }
        return type.is(FunctionTypeSyntax.self)
    }
}
