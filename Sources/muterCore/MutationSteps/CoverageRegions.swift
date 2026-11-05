import SwiftSyntax

/// What Swift's coverage has regions for: every function, accessor, closure and instance property's value, and a
/// `main.swift`'s statements. Globals, static properties and default arguments have none, so a file that holds nothing
/// else is named by no coverage data, even when the tests read its values.
enum CoverageRegions {
    /// Whether the Swift file at `path` holds values of the kind coverage has no regions for, and no code it has one
    /// for.
    static func holdsOnlyValues(_ path: FilePath) -> Bool {
        guard let source = sourceCode(fromFileAt: path)?.code else { return false }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(source)
        return finder.holdsAValue && !finder.holdsCode
    }

    private final class Finder: SyntaxVisitor {
        var holdsAValue = false
        var holdsCode = false

        override func visit(_ node: InitializerClauseSyntax) -> SyntaxVisitorContinueKind {
            holdsAValue = holdsAValue || node.isADeclarationsValue
            return .visitChildren
        }

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            holdsCode = holdsCode || node.body != nil
            return .visitChildren
        }

        override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
            holdsCode = holdsCode || node.body != nil
            return .visitChildren
        }

        override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
            holdsCode = true
            return .skipChildren
        }

        override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
            holdsCode = true
            return .skipChildren
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            holdsCode = true
            return .skipChildren
        }

        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            let isStatic = node.modifiers.contains {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }
            let isAMember = node.parent?.is(MemberBlockItemSyntax.self) == true
            if isAMember, !isStatic, node.bindings.contains(where: { $0.initializer != nil }) {
                holdsCode = true
            }
            return .visitChildren
        }

        override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
            if case .decl = node.item {
                return .visitChildren
            }
            holdsCode = true
            return .skipChildren
        }
    }
}
