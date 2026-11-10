import Foundation
import SwiftSyntax

extension CodeBlockItemListSyntax {
    /// Whether these are a body's statements, of anything but a file's top level or a `#if` clause.
    var isABody: Bool {
        guard let parent else {
            return false
        }
        return parent.is(CodeBlockSyntax.self) || parent.is(ClosureExprSyntax.self)
            || parent.is(AccessorBlockSyntax.self) || parent.is(SwitchCaseSyntax.self)
    }

    /// The closure, getter, function or other declaration whose code these statements are, through the `if`, `switch`,
    /// loop and `do` statements between.
    var owner: Syntax? {
        var node = parent
        while let current = node {
            if current.is(ClosureExprSyntax.self) || current.is(AccessorBlockSyntax.self) || current.is(DeclSyntax.self)
                && !current.is(IfConfigDeclSyntax.self) && !current.is(VariableDeclSyntax.self) {
                return current
            }
            node = current.parent
        }
        return nil
    }

    /// Whether these may be a result builder's parts: in a closure whose type isn't written and that returns no value,
    /// or a getter or function marked `@…Builder` or of a `some` type.
    var mayBeABuildersParts: Bool {
        guard let owner else {
            return false
        }
        if let closure = owner.as(ClosureExprSyntax.self) {
            return closure.signature?.returnClause == nil && !closure.returnsAValue
        }
        // A `return` of a value turns the builder off.
        if let function = owner.as(FunctionDeclSyntax.self) {
            return (function.attributes.containsResultBuilder || function.signature.returnClause?.type.isOpaque == true)
                && !(function.body.map { ValueReturnFinder.findsAValueReturn(in: Syntax($0.statements)) } ?? false)
        }
        if let accessorBlock = owner.as(AccessorBlockSyntax.self),
           case let .getter(statements) = accessorBlock.accessors {
            return Self.mayBeAResultBuilder(owner) && !ValueReturnFinder.findsAValueReturn(in: Syntax(statements))
        }
        guard let accessor = owner.as(AccessorDeclSyntax.self), accessor.accessorSpecifier.tokenKind == .keyword(.get)
        else {
            return false
        }
        return Self.mayBeAResultBuilder(owner)
            && !(accessor.body.map { ValueReturnFinder.findsAValueReturn(in: Syntax($0.statements)) } ?? false)
    }

    /// Whether these are the parts of a result builder known to take no `if`, where no mutant's switch builds: an
    /// App's or a Scene's `SceneBuilder`, a `WidgetBundleBuilder`, an `AppShortcutsBuilder`, and the
    /// `RegexComponentBuilder` of `Regex { … }`, `wholeMatch { … }` and the like. It's a closure passed to one, a
    /// `Group` among another's parts, or a getter or function marked with one or of a `some` type it builds.
    var isInABuilderThatTakesNoIf: Bool {
        guard let owner else {
            return false
        }
        if let closure = owner.as(ClosureExprSyntax.self) {
            guard let callee = closure.callee else {
                return false
            }
            let parts = RemoveSideEffectsOperator.Visitor.name(of: callee)
                .split(separator: ".")
                .map { String($0.prefix { $0 != "<" }) }
            if parts.contains(where: Self.regexBuilderTypes.contains)
                || parts.last.map(Self.regexAlgorithms.contains) == true {
                return true
            }
            // The statement the `Group` is, with any modifiers on it, as `Group { … }.defaultSize(…)`.
            var node = closure.parent
            while let base = node, let member = base.parent?.as(MemberAccessExprSyntax.self),
                  member.base?.id == base.id, let call = member.parent?.as(FunctionCallExprSyntax.self) {
                node = Syntax(call)
            }
            let statement = node?.parent?.as(CodeBlockItemSyntax.self)
            return parts.last == "Group"
                && statement?.parent?.as(CodeBlockItemListSyntax.self)?.isInABuilderThatTakesNoIf == true
        }
        // A `some` type makes a builder only of code with no `return` of a value.
        let isABuilder = !ValueReturnFinder.findsAValueReturn(in: Syntax(self))
        if let function = owner.as(FunctionDeclSyntax.self) {
            return function.attributes.namesAnIflessBuilder
                || isABuilder && function.signature.returnClause.map { Self.isAnIflessBuildersType($0.type) } ?? false
        }
        var ancestor = owner.parent
        while let node = ancestor {
            if let binding = node.as(PatternBindingSyntax.self) {
                let declaration = binding.parent?.parent?.as(VariableDeclSyntax.self)
                return declaration?.attributes.namesAnIflessBuilder == true
                    || isABuilder && binding.typeAnnotation.map { Self.isAnIflessBuildersType($0.type) } ?? false
                    || binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "appShortcuts"
            }
            if let subscriptDecl = node.as(SubscriptDeclSyntax.self) {
                return subscriptDecl.attributes.namesAnIflessBuilder
                    || isABuilder && Self.isAnIflessBuildersType(subscriptDecl.returnClause.type)
            }
            ancestor = node.parent
        }
        return false
    }

    private static let regexBuilderTypes: Set<String> = [
        "Regex", "Capture", "TryCapture", "Local", "One", "OneOrMore", "ZeroOrMore", "Optionally", "Repeat", "ChoiceOf",
        "Lookahead", "NegativeLookahead", "Anchor",
    ]

    /// The string methods that take a `RegexComponentBuilder` closure, but for the names that are common elsewhere,
    /// as `contains` and `split`.
    private static let regexAlgorithms: Set<String> = [
        "wholeMatch", "firstMatch", "prefixMatch", "matches", "replacing", "replace", "firstRange", "ranges",
        "trimmingPrefix", "trimPrefix",
    ]

    /// `some Scene`, `some Widget` or `some RegexComponent`.
    private static func isAnIflessBuildersType(_ type: TypeSyntax) -> Bool {
        guard let opaque = type.as(SomeOrAnyTypeSyntax.self), type.isOpaque else {
            return false
        }
        let name = opaque.constraint.trimmedDescription.split(separator: ".").last
        return ["Scene", "Widget", "RegexComponent"].contains(name)
    }

    /// Whether the getter at `node` may be a result builder's: its property or subscript is marked `@…Builder`, or is
    /// of a `some` type, as a protocol can make it one without a mark, as `View` does `body`.
    static func mayBeAResultBuilder(_ node: Syntax) -> Bool {
        var ancestor = node.parent
        while let current = ancestor {
            if let binding = current.as(PatternBindingSyntax.self) {
                let declaration = binding.parent?.parent?.as(VariableDeclSyntax.self)
                return binding.typeAnnotation?.type.isOpaque == true
                    || declaration?.attributes.containsResultBuilder == true
            }
            if let subscriptDecl = current.as(SubscriptDeclSyntax.self) {
                return subscriptDecl.returnClause.type.isOpaque || subscriptDecl.attributes.containsResultBuilder
            }
            ancestor = current.parent
        }
        return false
    }
}

extension AttributeListSyntax {
    /// Whether one of the attributes is a builder known to take no `if`.
    var namesAnIflessBuilder: Bool {
        contains { element in
            let name = element.as(AttributeSyntax.self)?.attributeName.trimmedDescription.split(separator: ".").last
            return ["SceneBuilder", "WidgetBundleBuilder", "AppShortcutsBuilder", "RegexComponentBuilder"]
                .contains(name.map(String.init))
        }
    }
}
