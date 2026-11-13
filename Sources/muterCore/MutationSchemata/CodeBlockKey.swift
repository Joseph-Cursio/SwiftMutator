import SwiftSyntax

/// A key that identifies a code block by its STABLE source position (the UTF-8 byte offset of its
/// first token) plus its text, rather than by SwiftSyntax node identity.
///
/// The mapping used to be keyed by `CodeBlockItemListSyntax` directly, but `Syntax` hashes on
/// `SyntaxIdentifier` — i.e. node IDENTITY, tied to a specific parse tree. `ApplySchemata` re-parses
/// each source file (on-demand re-parsing avoids memory exhaustion on large codebases), producing
/// fresh node identities, so the rewriter's lookup never matched what discovery inserted — schemata
/// were silently never applied and every mutant was reported as "survived" (0% score). Two parses of
/// the same bytes yield the same offset + text, so this key is stable across re-parsing.
///
/// A body's one statement has the same offset and text as the body, so the key says which of them it is of, or the
/// rewriter would switch both.
struct CodeBlockKey: Hashable, Comparable {
    enum Kind: Hashable {
        case statements
        case statement
        case initialValue
    }

    let offset: Int
    let text: String
    let kind: Kind

    init(_ node: CodeBlockItemListSyntax) {
        self.init(of: node, kind: .statements)
    }

    init(_ place: MutationSwitchPlace) {
        switch place {
        case let .statements(list): self.init(list)
        case let .statement(statement): self.init(of: statement, kind: .statement)
        case let .initialValue(value): self.init(of: value, kind: .initialValue)
        }
    }

    init(offset: Int, text: String) {
        self.offset = offset
        self.text = text
        kind = .statements
    }

    private init(of node: some SyntaxProtocol, kind: Kind) {
        offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        text = node.description
        self.kind = kind
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.text < rhs.text
    }
}
