import SwiftSyntax

final class AddImportRewriter: SyntaxRewriter {
    private let visitor = AddImportVisitior()
    private let accessLevel: String?

    init(accessLevel: String? = nil) {
        self.accessLevel = accessLevel
        super.init()
    }

    private(set) var newLinesAddedToFile = 0

    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        visitor.walk(node)

        guard !visitor.isImportingFoundation else {
            return super.visit(node)
        }

        newLinesAddedToFile = 2

        return super.visit(
            SourceFileSyntax(
                statements: insertImportFoundation(in: node.statements),
                endOfFileToken: node.endOfFileToken
            )
        )
    }

    /// The module's own access level on Foundation imports, so the injected import agrees with it.
    private var accessLevelModifier: DeclModifierSyntax? {
        let keyword: Keyword
        switch accessLevel {
        case "internal": keyword = .internal
        case "package": keyword = .package
        case "fileprivate": keyword = .fileprivate
        case "private": keyword = .private
        default: return nil
        }
        return DeclModifierSyntax(name: .keyword(keyword, trailingTrivia: .space))
    }

    private func insertImportFoundation(
        in node: CodeBlockItemListSyntax
    ) -> CodeBlockItemListSyntax {
        var items: [CodeBlockItemSyntax] = [
            CodeBlockItemSyntax(
                item: CodeBlockItemSyntax.Item(
                    ImportDeclSyntax(
                        leadingTrivia: .space,
                        modifiers: DeclModifierListSyntax(
                            accessLevelModifier.map { [$0] } ?? []
                        ) + [
                            DeclModifierSyntax(
                                name: TokenSyntax(
                                    .keyword(.import),
                                    trailingTrivia: .space,
                                    presence: .present
                                )
                            ),
                        ],
                        importKeyword: .keyword(.class),
                        path: ImportPathComponentListSyntax([
                            ImportPathComponentSyntax(
                                leadingTrivia: .space,
                                name: .identifier("Foundation")
                            ),
                            ImportPathComponentSyntax(
                                name: .periodToken()
                            ),
                            ImportPathComponentSyntax(
                                name: .identifier("ProcessInfo")
                            ),
                        ]),
                        trailingTrivia: .newlines(2)
                    )
                )
            ),
        ]

        for item in node {
            items.append(item)
        }

        return CodeBlockItemListSyntax(items)
    }
}

final class AddImportVisitior: SyntaxAnyVisitor {
    private(set) var isImportingFoundation = false

    init() {
        super.init(viewMode: .all)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if isImportingProcessInfo(node) || isImportingFoundation(node) {
            isImportingFoundation = true
        }

        return super.visit(node)
    }

    private func isImportingFoundation(_ node: ImportDeclSyntax) -> Bool {
        node.path.count == 1 && node.path.first?.name.text == "Foundation"
    }

    private func isImportingProcessInfo(_ node: ImportDeclSyntax) -> Bool {
        node.description.contains("Foundation.ProcessInfo")
    }
}
