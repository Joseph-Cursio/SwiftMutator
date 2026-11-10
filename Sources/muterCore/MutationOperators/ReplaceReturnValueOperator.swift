import SwiftSyntax

/// Replaces what a body returns with an empty value of its written return type, as PIT's EMPTY_RETURNS, NULL_RETURNS
/// and PRIMITIVE_RETURNS do: `nil` for an optional, `[]` for an array or a set, `[:]` for a dictionary, `""` for a
/// string and `0` for a number. A test that calls a function but never checks what comes back lets the mutant
/// survive. The tree has no types, so the replacement comes from the return type as it's written, and a type written
/// in any other way, a `some`, a typealias or a generic parameter, gets no mutant. A Bool is ReplaceBooleanValue's.
enum ReplaceReturnValueOperator {
    final class Visitor: MuterVisitor {
        /// The names the file declares that a written return type could mean instead of the standard library's, and
        /// those of its protocols' requirements a builder may be inferred for. Worked out once, from the whole file.
        private var declarations: FileDeclarations?

        convenience init(
            configuration: MuterConfiguration? = nil,
            sourceCodeInfo: SourceCodeInfo,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                configuration: configuration,
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .replaceReturnValue,
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
                  site.kind != .initialValue,
                  let owner = site.owner,
                  let writtenType = site.writtenType,
                  let empty = EmptyValue(writtenAs: writtenType, unless: declarations(in: value.root).typeNames),
                  value.canBeReplaced(by: empty),
                  !isLeftOut(value, of: site.kind, in: owner)
            else {
                return next
            }

            add(
                mutation: value.replaced(by: empty.literal),
                with: value,
                at: startLocation(for: value, afterLeadingTrivia: true),
                snapshot: MutationOperator.Snapshot(
                    before: value.trimmedDescription.inlined,
                    after: empty.text,
                    description: "replaced the return value with \(empty.text)"
                )
            )
            return next
        }

        /// Whether `value`, which `owner` returns, is left out though its type has an empty value, as its mutant may
        /// not compile:
        /// - The one expression of a body a result builder may build, which would take the empty value as a component
        ///   (`mayBeBuiltByAResultBuilder`). A `return` turns a builder off, so a returned value is kept.
        /// - A closure's value with a `try` or `await` in it, outside any closure nested in it. Without it, the
        ///   closure may no longer throw or wait, and a call it is passed to, which rethrows, as `map` does, leaves its
        ///   own `try` over nothing that throws, which the compiler warns of. A stored property's, a `static`'s and a
        ///   global's value is switched whole, so its copy with the mutant holds that call. A function's own `try`
        ///   is fine: one that is written to throw but doesn't gets no warning.
        private func isLeftOut(_ value: ExprSyntax, of kind: ValueSite.Kind, in owner: Syntax) -> Bool {
            if kind == .onlyExpression, mayBeBuiltByAResultBuilder(owner, in: value.root) {
                return true
            }
            return owner.is(ClosureExprSyntax.self) && Syntax(value).holdsATryOrAwaitOutsideClosures
        }

        /// Whether `owner`'s body may be a result builder's. The tree can't tell which attribute is a builder, so any
        /// attribute but those known not to be one says it may be: on the function, the property, the subscript or
        /// the accessor, or in a closure's signature. So does a closure passed to a call, whose parameter may be
        /// declared with a builder in another file, and a member named as a requirement this file's protocols declare
        /// with such an attribute, as Swift gives a witness its requirement's builder. A protocol declared in another
        /// file isn't seen.
        private func mayBeBuiltByAResultBuilder(_ owner: Syntax, in root: Syntax) -> Bool {
            if let closure = owner.as(ClosureExprSyntax.self) {
                return closure.isPassedToACall || closure.signature?.attributes.mayHoldAResultBuilder == true
            }
            let declaration = owner.declarationOfItsValue
            let attributes = [owner.as(AccessorDeclSyntax.self)?.attributes, declaration?.attributes]
            if attributes.contains(where: { $0?.mayHoldAResultBuilder == true }) {
                return true
            }
            return declaration.map { declarations(in: root).requirementsWithAttributes.contains($0.name) } == true
        }

        private func declarations(in root: Syntax) -> FileDeclarations {
            if let declarations {
                return declarations
            }
            let made = FileDeclarations(in: root)
            declarations = made
            return made
        }
    }
}

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
        if type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            self = .nilLiteral
            return
        }
        if type.is(ArrayTypeSyntax.self) {
            self = .emptyArray
            return
        }
        if type.is(DictionaryTypeSyntax.self) {
            self = .emptyDictionary
            return
        }
        let name: String
        let arguments: GenericArgumentClauseSyntax?
        if let identifier = type.as(IdentifierTypeSyntax.self), !declaredNames.contains(identifier.name.plainName) {
            (name, arguments) = (identifier.name.plainName, identifier.genericArgumentClause)
        } else if let member = type.as(MemberTypeSyntax.self),
                  let module = member.baseType.as(IdentifierTypeSyntax.self),
                  module.name.plainName == "Swift", module.genericArgumentClause == nil {
            (name, arguments) = (member.name.plainName, member.genericArgumentClause)
        } else {
            return nil
        }
        switch (name, arguments?.arguments.count ?? 0) {
        case ("Optional", 1): self = .nilLiteral
        case ("Array", 1), ("Set", 1): self = .emptyArray
        case ("Dictionary", 2): self = .emptyDictionary
        case ("String", 0), ("Substring", 0): self = .emptyString
        case (let name, 0) where Self.numbers.contains(name): self = .zero
        default: return nil
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

/// What a file declares that the operator looks at: the names of its types, typealiases, associated types and generic
/// parameters, at any depth, and the names of its protocols' requirements that carry an attribute that may be a
/// result builder.
private struct FileDeclarations {
    private(set) var typeNames: Set<String> = []
    private(set) var requirementsWithAttributes: Set<String> = []

    /// Walks the whole file with a loop, not recursion, so a deep tree can't run out of a discovery thread's stack.
    init(in root: Syntax) {
        var stack: [Syntax] = [root]
        while let node = stack.popLast() {
            stack.append(contentsOf: node.children(viewMode: .sourceAccurate))
            if let name = node.declaredTypeName {
                typeNames.insert(name)
            }
            guard let protocolDecl = node.as(ProtocolDeclSyntax.self) else { continue }
            for requirement in protocolDecl.requirements where requirement.attributes.mayHoldAResultBuilder {
                requirementsWithAttributes.insert(requirement.name)
            }
        }
    }
}

private extension ProtocolDeclSyntax {
    /// The functions, properties and subscripts this protocol requires, in any `#if` clause, at any depth, as well as
    /// outside one.
    var requirements: [NamedDeclaration] {
        var lists = [memberBlock.members]
        var found: [NamedDeclaration] = []
        while let members = lists.popLast() {
            for member in members {
                if let requirement = Syntax(member.decl).declarationWithAttributes {
                    found.append(requirement)
                }
                for clause in member.decl.as(IfConfigDeclSyntax.self)?.clauses ?? [] {
                    if case .decls(let decls) = clause.elements {
                        lists.append(decls)
                    }
                }
            }
        }
        return found
    }
}

/// A function, property or subscript, by the name a protocol's requirement would give it, and its attributes.
private struct NamedDeclaration {
    let name: String
    let attributes: AttributeListSyntax
}

private extension Syntax {
    /// The name of the type, protocol, typealias, associated type or generic parameter this declares, if it is one.
    var declaredTypeName: String? {
        let names: [TokenSyntax?] = [
            self.as(StructDeclSyntax.self)?.name,
            self.as(ClassDeclSyntax.self)?.name,
            self.as(EnumDeclSyntax.self)?.name,
            self.as(ActorDeclSyntax.self)?.name,
            self.as(ProtocolDeclSyntax.self)?.name,
            self.as(TypeAliasDeclSyntax.self)?.name,
            self.as(AssociatedTypeDeclSyntax.self)?.name,
            self.as(GenericParameterSyntax.self)?.name,
        ]
        return names.lazy.compactMap(\.self).first?.plainName
    }

    /// The function, property or subscript whose value this body gives: a function itself, or the property or
    /// subscript of a getter.
    var declarationOfItsValue: NamedDeclaration? {
        if let function = self.as(FunctionDeclSyntax.self) {
            return Syntax(function).declarationWithAttributes
        }
        let block = self.as(AccessorBlockSyntax.self) ?? self.as(AccessorDeclSyntax.self)?.parent?.parent?
            .as(AccessorBlockSyntax.self)
        if let binding = block?.parent?.as(PatternBindingSyntax.self),
           let variable = binding.parent?.parent?.as(VariableDeclSyntax.self) {
            let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.plainName ?? ""
            return NamedDeclaration(name: name, attributes: variable.attributes)
        }
        return block?.parent?.as(SubscriptDeclSyntax.self).map {
            NamedDeclaration(name: "subscript", attributes: $0.attributes)
        }
    }

    /// This function, property or subscript declaration, by its name and its attributes; nil for any other
    /// declaration. A property of several names is named by its first.
    var declarationWithAttributes: NamedDeclaration? {
        if let function = self.as(FunctionDeclSyntax.self) {
            return NamedDeclaration(name: function.name.plainName, attributes: function.attributes)
        }
        if let variable = self.as(VariableDeclSyntax.self) {
            let name = variable.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.plainName ?? ""
            return NamedDeclaration(name: name, attributes: variable.attributes)
        }
        return self.as(SubscriptDeclSyntax.self).map { NamedDeclaration(name: "subscript", attributes: $0.attributes) }
    }

    /// Whether this holds a `try` or an `await`, outside any closure in it: a nested closure's are its own.
    var holdsATryOrAwaitOutsideClosures: Bool {
        var stack: [Syntax] = [self]
        while let node = stack.popLast() {
            if node.is(TryExprSyntax.self) || node.is(AwaitExprSyntax.self) {
                return true
            }
            if !node.is(ClosureExprSyntax.self) || node.id == id {
                stack.append(contentsOf: node.children(viewMode: .sourceAccurate))
            }
        }
        return false
    }
}

private extension AttributeListSyntax {
    /// The attributes known not to be result builders. Any other may be one: a builder is declared as a type, and
    /// its name says nothing. A global actor other than `MainActor` is one too, but it can't be told from a builder.
    /// `_dynamicReplacement` isn't here, as Swift gives a replacement the builder of what it replaces, which may be
    /// declared anywhere. `_implements` is: a witness of that name is matched by its own name, which no builder is
    /// given for.
    static let notResultBuilders: Set<String> = [
        "inlinable", "inline", "discardableResult", "available", "objc", "nonobjc", "usableFromInline", "MainActor",
        "Sendable", "preconcurrency", "IBAction", "IBInspectable", "IBSegueAction", "_spi", "backDeployed",
        "warn_unqualified_access", "_disfavoredOverload", "_transparent", "_alwaysEmitIntoClient", "_effects",
        "_optimize", "_semantics", "_specialize", "_silgen_name", "_cdecl", "_implements", "_unavailableFromAsync",
        "derivative", "differentiable", "NSManaged", "GKInspectable", "concurrent", "_noAllocation", "_noLocks",
        "_implicitSelfCapture", "export",
    ]

    /// Whether any of these may be a result builder: an attribute not known not to be one, or one under a `#if`.
    var mayHoldAResultBuilder: Bool {
        contains { element in
            guard case .attribute(let attribute) = element else { return true }
            return !Self.notResultBuilders.contains(attribute.attributeName.trimmedDescription)
        }
    }
}

private extension ClosureExprSyntax {
    /// Whether this is an argument of a call, in its parentheses or as a trailing closure, whose parameter may be
    /// declared with a builder. A closure called on the spot is the call itself.
    var isPassedToACall: Bool {
        guard let parent else { return false }
        if parent.is(LabeledExprSyntax.self) || parent.is(MultipleTrailingClosureElementSyntax.self) {
            return true
        }
        if let call = parent.as(FunctionCallExprSyntax.self) {
            return call.calledExpression.id != id
        }
        return parent.is(SubscriptCallExprSyntax.self) || parent.is(MacroExpansionExprSyntax.self)
            || parent.is(MacroExpansionDeclSyntax.self)
    }
}

private extension ExprSyntax {
    /// Whether this value can take `empty`'s place: not a value that already is it, nor an `if` or `switch`
    /// expression, whose branches aren't sites of their own either, nor a value under `try?`.
    func canBeReplaced(by empty: EmptyValue) -> Bool {
        let core = withoutValueWrapping
        guard !core.is(IfExprSyntax.self), !core.is(SwitchExprSyntax.self) else { return false }
        if let attempt = core.as(TryExprSyntax.self), attempt.questionOrExclamationMark?.text == "?" {
            return false
        }
        return !empty.isWritten(as: self)
    }

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

private extension TokenSyntax {
    /// The name this token gives, without the backticks around one written as `` `Type` ``.
    var plainName: String {
        text.filter { $0 != "`" }
    }
}
