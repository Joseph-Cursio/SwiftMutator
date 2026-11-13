import SwiftSyntax

/// Every statement list in a file, in source order.
final class CodeBlockListCollector: SyntaxVisitor {
    private var lists: [CodeBlockItemListSyntax] = []

    static func lists(in source: SourceFileSyntax) -> [CodeBlockItemListSyntax] {
        let collector = CodeBlockListCollector(viewMode: .sourceAccurate)
        collector.walk(source)
        return collector.lists
    }

    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
        lists.append(node)
        return .visitChildren
    }
}

extension CodeBlockItemListSyntax {
    /// The stored property's or global's value this list is in, when it's in a closure passed to what looks like a
    /// type's initializer, `VStack { … }`, and the value's type isn't named, or is `some …`.
    var valueWhoseTypeCanDependOnIt: ExprSyntax? {
        var isInATypesClosure = false
        var ancestor = parent
        while let current = ancestor {
            if let closure = current.as(ClosureExprSyntax.self), closure.isPassedToAType {
                isInATypesClosure = true
            }
            if let clause = current.as(InitializerClauseSyntax.self), clause.isADeclarationsValue {
                guard isInATypesClosure, let binding = clause.parent?.as(PatternBindingSyntax.self) else { return nil }
                let type = binding.typeAnnotation?.type
                return type == nil || type?.isOpaque == true ? clause.value : nil
            }
            ancestor = current.parent
        }
        return nil
    }

    func isNested(inside outer: CodeBlockItemListSyntax) -> Bool {
        var ancestor = parent
        while let current = ancestor {
            if current.id == outer.id {
                return true
            }
            ancestor = current.parent
        }
        return false
    }

    /// The statements of a getter or function whose result type is `some …` and that is not a
    /// result builder: neither marked `@…Builder` nor a `body`, which `View` makes a builder.
    var isOpaqueNonBuilderBody: Bool {
        guard let parent else {
            return false
        }
        // `var x: some View { … }`: the getter's statements sit directly in the accessor block.
        if let accessorBlock = parent.as(AccessorBlockSyntax.self) {
            return accessorBlock.parent?.as(PatternBindingSyntax.self)?.isOpaqueNonBuilder ?? false
        }
        guard let block = parent.as(CodeBlockSyntax.self) else {
            return false
        }
        if let function = block.parent?.as(FunctionDeclSyntax.self) {
            return function.signature.returnClause?.type.isOpaque == true
                && !function.attributes.containsResultBuilder
        }
        // `var x: some View { get { … } }`
        if let accessor = block.parent?.as(AccessorDeclSyntax.self) {
            var ancestor = accessor.parent
            while let current = ancestor {
                if let binding = current.as(PatternBindingSyntax.self) {
                    return binding.isOpaqueNonBuilder
                }
                ancestor = current.parent
            }
        }
        return false
    }
}

extension ClosureExprSyntax {
    /// Whether this closure is an argument of a call to a capitalized name, as a type's initializer is.
    var isPassedToAType: Bool {
        var ancestor = parent
        while let current = ancestor {
            if let call = current.as(FunctionCallExprSyntax.self) {
                let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
                    ?? call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
                    ?? call.calledExpression.as(GenericSpecializationExprSyntax.self)?.expression.trimmedDescription
                return name?.first?.isUppercase == true
            }
            guard current.is(LabeledExprSyntax.self) || current.is(LabeledExprListSyntax.self)
                || current.is(MultipleTrailingClosureElementSyntax.self)
                || current.is(MultipleTrailingClosureElementListSyntax.self)
            else { return false }
            ancestor = current.parent
        }
        return false
    }
}

extension PatternBindingSyntax {
    var isOpaqueNonBuilder: Bool {
        guard typeAnnotation?.type.isOpaque == true else {
            return false
        }
        if pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "body" {
            return false
        }
        let declaration = parent?.parent?.as(VariableDeclSyntax.self)
        return !(declaration?.attributes.containsResultBuilder ?? false)
    }
}

extension TypeSyntax {
    /// Whether the type is `some …`.
    var isOpaque: Bool {
        self.as(SomeOrAnyTypeSyntax.self)?.someOrAnySpecifier.tokenKind == .keyword(.some)
    }
}

extension AttributeListSyntax {
    /// Whether one of the attributes is a result builder, by a name that ends in `Builder`, as `@ViewBuilder` does.
    var containsResultBuilder: Bool {
        contains { element in
            element.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
        }
    }
}
