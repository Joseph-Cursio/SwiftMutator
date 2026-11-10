import SwiftSyntax

extension MutationSwitch {
    /// The statements of each mutant's branch: its copy of `original`, without the copy's `#sourceLocation`
    /// directives.
    ///
    /// Each mutant's branch holds a copy of the list and the original's branch holds the list, so the compiler
    /// read each of the list's directives once per branch. It takes a directive that opens a location again, but
    /// not a `#sourceLocation()` that closes one when none is open: after the first branch closed it, every later
    /// branch failed to compile, the original's among them, which fails the build every mutant shares. Without
    /// the copies' directives the compiler reads the list's directives once, in the original's branch, which
    /// starts in the location the original does. Code after a dropped directive in a mutant's branch takes the
    /// location in effect where the switch starts, so `#fileID` or `#line` there can differ from the original's.
    ///
    /// A mutant that removes a statement removes the directives in it, so `original` tells which there are.
    /// swift-syntax parses a directive in an `#if` clause of a type's members as unexpected text, which a copy
    /// can't drop. Dropping the others could leave it closing a location none opens, so then every copy keeps
    /// its directives, as before.
    static func branches(
        switchingOn schemata: MutationSchemata,
        of original: CodeBlockItemListSyntax
    ) -> [CodeBlockItemListSyntax] {
        let copies = schemata.map(\.syntaxMutation)
        let directives = original.tokens(viewMode: .sourceAccurate).filter { $0.tokenKind == .poundSourceLocation }
        guard !directives.isEmpty, directives.allSatisfy(startsAStatementOrMember) else {
            return copies
        }
        return copies.map { SourceLocationRemover().rewrite($0).cast(CodeBlockItemListSyntax.self) }
    }

    /// Whether the `#sourceLocation` token `directive` starts a statement or a member, which `SourceLocationRemover`
    /// can drop.
    static func startsAStatementOrMember(_ directive: TokenSyntax) -> Bool {
        guard let parent = directive.parent?.as(PoundSourceLocationSyntax.self)?.parent else {
            return false
        }
        return parent.is(CodeBlockItemSyntax.self) || parent.is(MemberBlockItemSyntax.self)
    }
}
