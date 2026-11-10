import Foundation
import SwiftParser
import SwiftSyntax

extension MuterVisitor {
    /// Where `node` sits in its block's text, found from the node's own position. Searching the text
    /// for the node finds the FIRST copy, so of two identical ternaries the second one's mutant
    /// changed the first instead. `nil` if the offsets don't line up, and the text search is used.
    static func range(
        of node: SyntaxProtocol,
        in block: SyntaxProtocol,
        description: String
    ) -> Range<String.Index>? {
        let offset = node.position.utf8Offset - block.position.utf8Offset
        let utf8 = description.utf8
        guard offset >= 0,
              let start = utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex),
              let end = utf8.index(start, offsetBy: node.description.utf8.count, limitedBy: utf8.endIndex),
              description[start ..< end] == node.description
        else {
            return nil
        }
        return start ..< end
    }

    /// `code`'s text with `mutatedSyntax` in place of `node`, parsed as a statement list, which a branch of a switch
    /// holds whichever place the switch is in.
    func transform(
        node: SyntaxProtocol,
        mutatedSyntax: SyntaxProtocol,
        in code: SyntaxProtocol
    ) -> CodeBlockItemListSyntax {
        let codeBlockDescription = code.description
        let mutationDescription = mutatedSyntax.description
        let range = Self.range(of: node, in: code, description: codeBlockDescription)
            ?? codeBlockDescription.range(of: node.description)
        let codeBlockTree = Parser.parse(source: codeBlockDescription)
        guard let range
        else {
            return codeBlockTree.statements
        }

        // The incremental parse reuses every statement after the edit, so the edit must be exact
        // and in UTF-8 bytes: the replaced text's bytes, replaced by the mutation's.
        let utf8 = codeBlockDescription.utf8
        let bytes = utf8.distance(from: utf8.startIndex, to: range.lowerBound)
            ..< utf8.distance(from: utf8.startIndex, to: range.upperBound)
        let edit = SourceEdit(
            range: AbsolutePosition(utf8Offset: bytes.lowerBound) ..< AbsolutePosition(utf8Offset: bytes.upperBound),
            replacement: mutationDescription
        )

        // The text gets the same edit, byte for byte. A combining mark that starts the next name joins the space
        // before it into one character, and Linux's `replacingCharacters(in:with:)` widens the range to whole
        // characters: `a && \u{064B}x` became `a ||  \u{064B}x`.
        var codeBlockBytes = Array(utf8)
        codeBlockBytes.replaceSubrange(bytes, with: mutationDescription.utf8)
        let codeBlockWithMutation = String(lossyUTF8: codeBlockBytes)

        let parseTransition = IncrementalParseTransition(
            previousIncrementalParseResult: .init(tree: codeBlockTree, lookaheadRanges: .init()),
            edits: ConcurrentEdits(edit)
        )

        let mutationParsed = Parser.parseIncrementally(
            source: codeBlockWithMutation,
            parseTransition: parseTransition
        )

        return mutationParsed.tree.statements
    }
}
