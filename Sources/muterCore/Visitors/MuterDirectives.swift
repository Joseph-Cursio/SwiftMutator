import SwiftSyntax

/// A comment that tells SwiftMutator what to leave out: `muter:` and a word, first in a comment of any kind, as
/// `// muter:disable` or `/* muter:enable */`. A comment that only mentions one, as `// see muter:disable`, isn't one.
enum MuterDirective: String, CaseIterable {
    /// Leaves out what follows, until a `muter:enable` or the end of the file.
    case disable = "muter:disable"
    case enable = "muter:enable"
    /// Leaves out the line after the comment's.
    case disableNextLine = "muter:disable-next-line"
    /// Leaves out the declaration the comment is above or beside: a function, type, extension, property and the like.
    case disableDeclaration = "muter:disable-declaration"

    /// The directive `piece` is, if it's a comment that starts with one's word alone.
    init?(_ piece: TriviaPiece) {
        let text: Substring
        switch piece {
        case let .lineComment(comment):
            text = comment.dropFirst(2)
        case let .docLineComment(comment):
            text = comment.dropFirst(3)
        case let .blockComment(comment):
            text = comment.dropFirst(2).dropLast(2)
        case let .docBlockComment(comment):
            text = comment.dropFirst(3).dropLast(2)
        default:
            return nil
        }
        let word = text.drop(while: \.isWhitespace).prefix { !$0.isWhitespace }
        self.init(rawValue: String(word))
    }
}

/// What a file's directives leave out, worked out once from the whole file.
struct MuterDirectives {
    private struct Effect {
        let position: AbsolutePosition
        let disables: Bool
    }

    /// Each `disable` and `enable`'s effect, by where it starts, in order.
    private let effects: [Effect]
    /// The code `disable-next-line` and `disable-declaration` leave out.
    private let ranges: [Range<AbsolutePosition>]

    init(in root: Syntax, converter: SourceLocationConverter) {
        var effects: [Effect] = []
        var ranges: [Range<AbsolutePosition>] = []
        for token in root.tokens(viewMode: .sourceAccurate) {
            for (isLeading, trivia, start) in [
                (true, token.leadingTrivia, token.position),
                (false, token.trailingTrivia, token.endPositionBeforeTrailingTrivia),
            ] {
                if let disables = Self.lastSwitch(in: trivia) {
                    let position = Self.switchPosition(disables, isLeading, token)
                    effects.append(Effect(position: position, disables: disables))
                }
                var position = start
                for piece in trivia {
                    let end = position.advanced(by: piece.sourceLength.utf8Length)
                    switch MuterDirective(piece) {
                    case .disableNextLine:
                        ranges.append(Self.line(after: end, converter: converter))
                    case .disableDeclaration:
                        let first = isLeading ? token : Self.firstToken(onTheLineOf: token, converter: converter)
                        let node = Self.declaration(startingWith: first)
                        ranges.append(node.positionAfterSkippingLeadingTrivia ..< node.endPositionBeforeTrailingTrivia)
                    default:
                        break
                    }
                    position = end
                }
            }
        }
        self.effects = effects.sorted { $0.position < $1.position }
        self.ranges = ranges
    }

    /// Whether what starts at `position` is left out by a `disable` that is still on there.
    func isSwitchedOff(at position: AbsolutePosition) -> Bool {
        effects.last { $0.position <= position }?.disables ?? false
    }

    /// Whether `position` is in a line or declaration a directive leaves out.
    func isLeftOut(_ position: AbsolutePosition) -> Bool {
        ranges.contains { $0.contains(position) }
    }

    /// Whether the last `disable` or `enable` in `trivia` is a `disable`; nil if it holds neither.
    private static func lastSwitch(in trivia: Trivia) -> Bool? {
        for piece in trivia.reversed() {
            switch MuterDirective(piece) {
            case .disable: return true
            case .enable: return false
            default: continue
            }
        }
        return nil
    }

    /// A comment on a line of its own takes effect from there. One beside code leaves that code off: a `disable`
    /// covers the statement or element it ends, and an `enable` starts after it.
    private static func switchPosition(_ disables: Bool, _ isLeading: Bool, _ token: TokenSyntax) -> AbsolutePosition {
        if isLeading {
            return token.position
        }
        return disables
            ? outermostNode(endingWith: token).positionAfterSkippingLeadingTrivia
            : token.endPositionBeforeTrailingTrivia
    }

    /// Stops short of a list, of statements, members, cases, elements or arguments, whose last one `token` may end,
    /// but which holds others too.
    private static func outermostNode(endingWith token: TokenSyntax) -> Syntax {
        var node = Syntax(token)
        while let parent = node.parent,
              !parent.kind.isSyntaxCollection,
              parent.lastToken(viewMode: .sourceAccurate)?.id == token.id {
            node = parent
        }
        return node
    }

    /// The whole of the line after the one `position` is on, which is empty after the file's last line.
    private static func line(
        after position: AbsolutePosition,
        converter: SourceLocationConverter
    ) -> Range<AbsolutePosition> {
        let line = converter.location(for: position).line + 1
        let start = converter.position(ofLine: line, column: 1)
        let end = converter.position(ofLine: line + 1, column: 1)
        return start ..< max(start, end)
    }

    /// The first token of the line `token`'s code ends on. A line that goes on with a string literal from an earlier
    /// line, as a multi-line one's closing `"""` does, starts where the literal's first line does.
    private static func firstToken(onTheLineOf token: TokenSyntax, converter: SourceLocationConverter) -> TokenSyntax {
        func lineNumber(of position: AbsolutePosition) -> Int {
            converter.location(for: position).line
        }
        var line = lineNumber(of: token.endPositionBeforeTrailingTrivia)
        var first = token
        while true {
            while let previous = first.previousToken(viewMode: .sourceAccurate),
                  lineNumber(of: previous.positionAfterSkippingLeadingTrivia) == line {
                first = previous
            }
            guard let literal = first.ancestorOrSelf(mapping: { $0.as(StringLiteralExprSyntax.self) }),
                  let opening = literal.firstToken(viewMode: .sourceAccurate),
                  lineNumber(of: opening.positionAfterSkippingLeadingTrivia) < line
            else {
                return first
            }
            first = opening
            line = lineNumber(of: opening.positionAfterSkippingLeadingTrivia)
        }
    }

    /// The declaration `token` starts, past its attributes and modifiers, as a function's `func` keyword does. If it
    /// starts none, the statement, member, case, element or argument it starts.
    private static func declaration(startingWith token: TokenSyntax) -> Syntax {
        if let declaration = declaration(holding: token),
           token.position <= Self.endOfAttributesAndModifiers(of: declaration) {
            return Syntax(declaration)
        }
        var node = Syntax(token)
        while let parent = node.parent,
              !parent.kind.isSyntaxCollection,
              parent.firstToken(viewMode: .sourceAccurate)?.id == token.id {
            node = parent
        }
        return node
    }

    /// The innermost declaration that holds `token`. A `#if` among a declaration's attributes is one too, so the
    /// declaration whose attributes hold it is taken instead.
    private static func declaration(holding token: TokenSyntax) -> DeclSyntax? {
        var found = token.parent?.ancestorOrSelf(mapping: { $0.as(DeclSyntax.self) })
        while let ifConfig = found?.as(IfConfigDeclSyntax.self), ifConfig.parent?.is(AttributeListSyntax.self) == true {
            found = ifConfig.parent?.ancestorOrSelf(mapping: { $0.as(DeclSyntax.self) })
        }
        return found
    }

    /// Where a declaration's keyword starts: after its modifiers, or its attributes when it has none.
    private static func endOfAttributesAndModifiers(of declaration: DeclSyntax) -> AbsolutePosition {
        if let modifiers = declaration.asProtocol(WithModifiersSyntax.self)?.modifiers, !modifiers.isEmpty {
            return modifiers.endPosition
        }
        if let attributes = declaration.asProtocol(WithAttributesSyntax.self)?.attributes, !attributes.isEmpty {
            return attributes.endPosition
        }
        return declaration.position
    }
}
