import SwiftSyntax

/// The position in a source file of a mutation.
struct MutationPosition: Codable, Equatable, Comparable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The UTF-8 byte offset of the mutation. Used so we don't have to evaluate line wraps in order to interpret
    /// line/column pairs.
    let utf8Offset: Int

    /// The line where the mutation occurs.
    let line: Int

    /// The column where the mutation occurs.
    let column: Int

    init(
        utf8Offset: Int = 0,
        line: Int = 0,
        column: Int = 0
    ) {
        self.utf8Offset = utf8Offset
        self.line = line
        self.column = column
    }

    init(sourceLocation: SourceLocation) {
        self.init(
            utf8Offset: sourceLocation.offset,
            line: sourceLocation.line,
            column: sourceLocation.column
        )
    }

    /// By offset, then line, then column: a strict weak ordering, so `sorted()` sorts positions. (Joining the three
    /// comparisons with `&&` made most pairs of positions neither less nor greater, and `sorted()` left them as they
    /// were.)
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.utf8Offset, lhs.line, lhs.column) < (rhs.utf8Offset, rhs.line, rhs.column)
    }

    var description: String {
        "\(utf8Offset)_\(line)_\(column)"
    }

    var debugDescription: String {
        """
        MutationPosition(
            utf8Offset: \(utf8Offset),
            line: \(line),
            column: \(column)
        )
        """
    }

    static var null: Self {
        Self(utf8Offset: 0)
    }
}
