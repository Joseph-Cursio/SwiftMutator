import SwiftParser
import SwiftSyntax

final class MutationSourceCodePreparationChange: Equatable {
    static func == (
        lhs: MutationSourceCodePreparationChange,
        rhs: MutationSourceCodePreparationChange
    ) -> Bool {
        lhs.newLines == rhs.newLines
    }

    let newLines: Int

    init(
        newLines: Int
    ) {
        self.newLines = newLines
    }
}

extension MutationSourceCodePreparationChange: Nullable {
    static var null: MutationSourceCodePreparationChange {
        .init(
            newLines: 0
        )
    }
}

class MuterVisitor: SyntaxAnyVisitor {
    private let muterDisableTag = "muter:disable"
    private let muterEnabledTag = "muter:enable"
    private(set) var isDisabled = false

    let configuration: MuterConfiguration?
    let sourceCodeInfo: SourceCodeInfo
    let mutationOperatorId: MutationOperator.Id
    let regionsWithoutCoverage: [Region]

    var sourceCodePreparationChange: MutationSourceCodePreparationChange = .null

    private(set) var schemataMappings: SchemataMutationMapping

    required init(
        configuration: MuterConfiguration? = nil,
        sourceCodeInfo: SourceCodeInfo,
        mutationOperatorId: MutationOperator.Id,
        regionsWithoutCoverage: [Region]
    ) {
        self.configuration = configuration
        self.sourceCodeInfo = sourceCodeInfo
        self.mutationOperatorId = mutationOperatorId
        self.regionsWithoutCoverage = regionsWithoutCoverage

        schemataMappings = SchemataMutationMapping(
            filePath: sourceCodeInfo.path
        )

        super.init(viewMode: .sourceAccurate)
    }

    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        guard hasTestCoverage(node) else {
            return .skipChildren
        }

        checkNodeForDisableTag(node)

        return super.visitAny(node)
    }

    func checkNodeForDisableTag(_ node: SyntaxProtocol) {
        isDisabled = isDisabled
            && !node.containsLineComment(muterEnabledTag)
            || !isDisabled
            && node.containsLineComment(muterDisableTag)
    }

    private func hasTestCoverage(
        _ node: SyntaxProtocol
    ) -> Bool {
        guard !regionsWithoutCoverage.isEmpty else {
            return true
        }

        let nodeRegion = nodeRegion(node)

        return regionsWithoutCoverage.include { $0.contains(nodeRegion) }.isEmpty
    }

    private func nodeRegion(_ node: SyntaxProtocol) -> Region {
        let start = startLocation(for: node)
        let end = endLocation(for: node)

        return Region(
            lineStart: start.line,
            columnStart: start.column,
            lineEnd: end.line,
            columnEnd: end.column
        )
    }

    func startLocation(
        for node: SyntaxProtocol
    ) -> MutationPosition {
        let converter = SourceLocationConverter(
            fileName: sourceCodeInfo.path,
            tree: sourceCodeInfo.code
        )

        let sourceLocation = node.startLocation(
            converter: converter
        )

        return mutationPosition(
            for: sourceLocation
        )
    }

    func endLocation(
        for node: SyntaxProtocol
    ) -> MutationPosition {
        let sourceLocation = node.endLocation(
            converter: SourceLocationConverter(
                fileName: sourceCodeInfo.path,
                tree: sourceCodeInfo.code
            ),
            afterTrailingTrivia: true
        )

        return mutationPosition(
            for: sourceLocation
        )
    }

    private func mutationPosition(
        for sourceLocation: SourceLocation
    ) -> MutationPosition {
        MutationPosition(
            utf8Offset: sourceLocation.offset,
            line: sourceLocation.line - sourceCodePreparationChange.newLines,
            column: sourceLocation.column
        )
    }

    /// Where `node` sits in its block's text, found from the node's own position. Searching the text
    /// for the node finds the FIRST copy, so of two identical ternaries the second one's mutant
    /// changed the first instead. `nil` if the offsets don't line up, and the text search is used.
    static func range(
        of node: SyntaxProtocol,
        in block: CodeBlockItemListSyntax,
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

    func transform(
        node: SyntaxProtocol,
        mutatedSyntax: SyntaxProtocol
    ) -> CodeBlockItemListSyntax {
        let codeBlockItemListSyntax = node.codeBlockItemListSyntax
        let codeBlockDescription = codeBlockItemListSyntax.description
        let mutationDescription = mutatedSyntax.description
        let range = Self.range(of: node, in: codeBlockItemListSyntax, description: codeBlockDescription)
            ?? codeBlockDescription.range(of: node.description)
        let codeBlockTree = Parser.parse(source: codeBlockDescription)
        guard let range
        else {
            return codeBlockItemListSyntax
        }

        // The incremental parse reuses every statement after the edit, so the edit must be exact
        // and in UTF-8 bytes: the replaced text's bytes, replaced by the mutation's.
        let utf8 = codeBlockDescription.utf8
        let edit = SourceEdit(
            range: AbsolutePosition(utf8Offset: utf8.distance(from: utf8.startIndex, to: range.lowerBound))
                ..< AbsolutePosition(utf8Offset: utf8.distance(from: utf8.startIndex, to: range.upperBound)),
            replacement: mutationDescription
        )

        let codeBlockWithMutation = codeBlockDescription.replacingCharacters(
            in: range,
            with: mutationDescription
        )

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

    func add(
        mutation: SyntaxProtocol,
        with syntax: SyntaxProtocol,
        at position: MutationPosition,
        snapshot: MutationOperator.Snapshot
    ) {
        guard !isDisabled else {
            return
        }

        // A stored-property initializer has no statement list of its own; walking up reaches the
        // file's top level, where a switch around declarations cannot compile. Skip it rather than
        // break the build every mutant shares.
        guard !syntax.cannotHoldMutationSwitch else {
            return
        }

        let schemata = makeSchemata(
            with: syntax,
            mutation: mutation,
            at: position,
            for: snapshot
        )

        schemataMappings.add(
            syntax.codeBlockItemListSyntax,
            schemata
        )
    }

    func makeSchemata(
        with syntax: SyntaxProtocol,
        mutation: SyntaxProtocol,
        at position: MutationPosition,
        for snapshot: MutationOperator.Snapshot
    ) -> MutationSchema {
        MutationSchema(
            filePath: sourceCodeInfo.path,
            mutationOperatorId: mutationOperatorId,
            syntaxMutation: transform(
                node: syntax,
                mutatedSyntax: mutation
            ),
            position: position,
            snapshot: snapshot
        )
    }
}
