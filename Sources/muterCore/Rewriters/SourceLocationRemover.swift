import Foundation
import SwiftSyntax

/// Drops the `#sourceLocation` directives of a mutant's copy of a statement list, at any depth: from its
/// statement lists, a `case` body's among them, and from the member lists of the types it declares.
final class SourceLocationRemover: SyntaxRewriter {
    override func visit(_ node: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
        super.visit(Self.dropping(from: node) { $0.item.is(PoundSourceLocationSyntax.self) })
    }

    override func visit(_ node: MemberBlockItemListSyntax) -> MemberBlockItemListSyntax {
        super.visit(Self.dropping(from: node) { $0.decl.is(PoundSourceLocationSyntax.self) })
    }

    /// A `case` that held nothing but directives compiles, though one with no statement doesn't. `do {}` does
    /// nothing, as the `case` did, and unlike `break` it compiles in a result builder too. It takes the
    /// directives' place and their trivia, so a `//` comment on the `case` line ends before it.
    override func visit(_ node: SwitchCaseSyntax) -> SwitchCaseSyntax {
        let directives = node.statements
        guard let first = directives.first, directives.allSatisfy({ $0.item.is(PoundSourceLocationSyntax.self) }) else {
            return super.visit(node)
        }
        let after = directives.dropFirst().reduce(first.trailingTrivia) { $0 + $1.leadingTrivia + $1.trailingTrivia }
        let doNothing = DoStmtSyntax(
            doKeyword: .keyword(.do, leadingTrivia: first.leadingTrivia, trailingTrivia: .space),
            body: CodeBlockSyntax(statements: [], rightBrace: .rightBraceToken(trailingTrivia: after))
        )
        return super.visit(node.with(\.statements, [CodeBlockItemSyntax(item: .stmt(StmtSyntax(doNothing)))]))
    }

    /// `list` without the directives `isDirective` picks. Each directive's trivia goes to the element after it, or
    /// to the one before it at the end of the list, so the lines and comments stay as they were: a block comment
    /// after a directive can run onto the next line, and code can follow it there.
    private static func dropping<List: SyntaxCollection>(
        from list: List,
        directives isDirective: (List.Element) -> Bool
    ) -> List {
        guard list.contains(where: isDirective) else {
            return list
        }
        var kept: [List.Element] = []
        var trivia = Trivia()
        for element in list {
            if isDirective(element) {
                trivia += element.leadingTrivia + element.trailingTrivia
            } else {
                kept.append(trivia.isEmpty ? element : element.with(\.leadingTrivia, trivia + element.leadingTrivia))
                trivia = []
            }
        }
        if !trivia.isEmpty, let last = kept.popLast() {
            kept.append(last.with(\.trailingTrivia, last.trailingTrivia + trivia))
        }
        return List(kept)
    }
}
