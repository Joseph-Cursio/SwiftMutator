import SwiftSyntax

extension SyntaxProtocol {
    var escapedDescription: String {
        description.replacingOccurrences(
            of: "\n",
            with: "\\n"
        )
        .replacingOccurrences(
            of: "\"",
            with: "\\\""
        )
    }

    func appendingLeadingTrivia(
        _ pieces: TriviaPiece...
    ) -> Self {
        var trivia = leadingTrivia
        if !trivia.isEmpty {
            pieces.forEach { trivia = trivia.appending($0) }
            return withLeadingTrivia(trivia)
        }
        return withLeadingTrivia(Trivia(pieces: pieces))
    }

    func appendingTrailingTrivia(
        _ pieces: TriviaPiece...
    ) -> Self {
        var trivia = trailingTrivia
        if !trivia.isEmpty {
            pieces.forEach { trivia = trivia.appending($0) }
            return withTrailingTrivia(trivia)
        }
        return withTrailingTrivia(Trivia(pieces: pieces))
    }

    func withTrailingTrivia(
        _ trivia: Trivia?
    ) -> Self {
        var copy = self
        if let trivia {
            copy.trailingTrivia = trivia
        }

        return copy
    }

    func withLeadingTrivia(
        _ trivia: Trivia?
    ) -> Self {
        var copy = self
        if let trivia {
            copy.leadingTrivia = trivia
        }

        return copy
    }

    func withoutTrivia() -> Self {
        withLeadingTrivia([]).withTrailingTrivia([])
    }
}
