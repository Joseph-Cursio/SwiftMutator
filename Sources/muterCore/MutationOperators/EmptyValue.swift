import SwiftSyntax

/// The empty value of a written return type, which the operator puts in place of what the body returns.
enum EmptyValue: Equatable {
    case nilLiteral
    case emptyArray
    case emptyDictionary
    case emptyString
    case zero

    /// The standard library's numeric types, whose empty value is `0`, and CoreGraphics' `CGFloat`.
    private static let numbers: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "CGFloat",
    ]

    /// The empty value of `type` as it's written, in parentheses or not; nil for a type that has none, or isn't
    /// written in one of these forms: `T?`, `T!` or `Optional<T>`; `[T]`, `Array<T>` or `Set<T>`; `[K: V]` or
    /// `Dictionary<K, V>`; `String` or `Substring`; or a number. `Swift.` may name the module. A name the file
    /// declares as a type of its own, a typealias or a generic parameter, in `declaredNames`, is that type, unless the
    /// module is named: an `Int` the file declares may not take `0`. One declared in another file isn't seen. A type
    /// with a `some` anywhere in it, as `[some Shape]` or `(some Shape)?`, has none: Swift infers the opaque type from
    /// each value returned, and can't from an empty one.
    init?(writtenAs type: TypeSyntax, unless declaredNames: Set<String>) {
        guard !type.tokens(viewMode: .sourceAccurate).contains(where: { $0.tokenKind == .keyword(.some) }) else {
            return nil
        }
        var type = type
        while let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first,
              only.firstName == nil, only.inoutKeyword == nil, only.ellipsis == nil {
            type = only.type
        }
        if let sugared = Self.sugared(type) {
            self = sugared
            return
        }
        guard let named = Self.standardName(of: type, unless: declaredNames),
              let value = Self.standardType(named.name, argumentCount: named.arguments?.arguments.count ?? 0)
        else { return nil }
        self = value
    }

    /// The empty value of a type written with the sugar of an optional, an array or a dictionary.
    private static func sugared(_ type: TypeSyntax) -> Self? {
        if type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return .nilLiteral
        }
        if type.is(ArrayTypeSyntax.self) {
            return .emptyArray
        }
        if type.is(DictionaryTypeSyntax.self) {
            return .emptyDictionary
        }
        return nil
    }

    /// The name and generic arguments of `type` when it's written as a name, or as one in `Swift.`, and the name isn't
    /// one of `declaredNames` unless the module is named.
    private static func standardName(
        of type: TypeSyntax,
        unless declaredNames: Set<String>
    ) -> (name: String, arguments: GenericArgumentClauseSyntax?)? {
        if let identifier = type.as(IdentifierTypeSyntax.self), !declaredNames.contains(identifier.name.plainName) {
            return (identifier.name.plainName, identifier.genericArgumentClause)
        }
        if let member = type.as(MemberTypeSyntax.self),
           let module = member.baseType.as(IdentifierTypeSyntax.self),
           module.name.plainName == "Swift", module.genericArgumentClause == nil {
            return (member.name.plainName, member.genericArgumentClause)
        }
        return nil
    }

    /// The empty value of the standard library's type `name` with `argumentCount` generic arguments.
    private static func standardType(_ name: String, argumentCount: Int) -> Self? {
        switch (name, argumentCount) {
        case ("Optional", 1): .nilLiteral
        case ("Array", 1), ("Set", 1): .emptyArray
        case ("Dictionary", 2): .emptyDictionary
        case ("String", 0), ("Substring", 0): .emptyString
        case (let name, 0) where numbers.contains(name): .zero
        default: nil
        }
    }

    /// The value as it's written.
    var text: String {
        switch self {
        case .nilLiteral: "nil"
        case .emptyArray: "[]"
        case .emptyDictionary: "[:]"
        case .emptyString: "\"\""
        case .zero: "0"
        }
    }

    /// The value as a literal with no trivia.
    var literal: ExprSyntax {
        switch self {
        case .nilLiteral:
            ExprSyntax(NilLiteralExprSyntax())

        case .emptyArray:
            ExprSyntax(ArrayExprSyntax(elements: ArrayElementListSyntax([])))

        case .emptyDictionary:
            ExprSyntax(DictionaryExprSyntax(content: .colon(.colonToken())))

        case .emptyString:
            ExprSyntax(StringLiteralExprSyntax(
                openingQuote: .stringQuoteToken(),
                segments: StringLiteralSegmentListSyntax([]),
                closingQuote: .stringQuoteToken()
            ))

        case .zero:
            ExprSyntax(IntegerLiteralExprSyntax(literal: .integerLiteral("0")))
        }
    }

    /// Whether `value`, inside any parentheses, is already this, so that its mutant would change nothing: `nil`, `[]`,
    /// `[:]`, an empty string literal of any kind, or a number literal whose value is zero, as `0.0`, `0x0` or `-0`.
    func isWritten(as value: ExprSyntax) -> Bool {
        let core = value.withoutParentheses
        switch self {
        case .nilLiteral:
            return core.is(NilLiteralExprSyntax.self)

        case .emptyArray:
            return core.as(ArrayExprSyntax.self)?.elements.isEmpty == true

        case .emptyDictionary:
            guard case .colon = core.as(DictionaryExprSyntax.self)?.content else { return false }
            return true

        case .emptyString:
            return core.as(StringLiteralExprSyntax.self)?.segments.allSatisfy {
                $0.as(StringSegmentSyntax.self)?.content.text.isEmpty == true
            } == true

        case .zero:
            return core.isZero
        }
    }
}

private extension ExprSyntax {
    /// The expression inside any parentheses around it.
    var withoutParentheses: ExprSyntax {
        var expression = self
        while let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
              let only = tuple.elements.first, only.label == nil {
            expression = only.expression
        }
        return expression
    }

    /// Whether this is a number literal whose value is zero, with a `-` or `+` in front or not: `0`, `0_0`, `0.0`,
    /// `0e5`, `0x0`, `0b0`, `0o0` or `0x0p1`.
    var isZero: Bool {
        if let prefix = self.as(PrefixOperatorExprSyntax.self), ["-", "+"].contains(prefix.operator.text) {
            return prefix.expression.withoutParentheses.isZero
        }
        let literal = self.as(IntegerLiteralExprSyntax.self)?.literal ?? self.as(FloatLiteralExprSyntax.self)?.literal
        guard var text = literal?.text.lowercased().filter({ $0 != "_" }) else { return false }
        let isHexadecimal = text.hasPrefix("0x")
        if ["0x", "0b", "0o"].contains(where: text.hasPrefix) {
            text.removeFirst(2)
        }
        let digits = text.prefix { isHexadecimal ? $0 != "p" : $0 != "e" }
        return digits.contains("0") && digits.allSatisfy { $0 == "0" || $0 == "." }
    }
}
