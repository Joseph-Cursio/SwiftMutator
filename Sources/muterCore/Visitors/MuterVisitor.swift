import Foundation
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
    let coverage: FileCoverage

    var sourceCodePreparationChange: MutationSourceCodePreparationChange = .null
    /// The mutated project's folder, which each mutant's switch ID gives its file's path from (`MutationSchema.id`).
    /// Discovery sets it; a test of one file can leave it out.
    var projectRoot: URL?

    private(set) var schemataMappings: SchemataMutationMapping

    /// One for the whole file: making one takes a pass over the whole file, and every node's coverage check asks for
    /// a location, so making them each time took minutes on a long file in a debug build.
    private lazy var locationConverter = SourceLocationConverter(
        fileName: sourceCodeInfo.path,
        tree: sourceCodeInfo.code
    )

    /// Lazy, because `sourceCodePreparationChange` is set after `init`.
    private lazy var executionCounts = ExecutionCounts(
        coverage: coverage,
        source: sourceCodeInfo.code,
        location: { [unowned self] position in
            let position = mutationPosition(for: locationConverter.location(for: position))
            return ExecutionCounts.Point(line: position.line, column: position.column)
        }
    )

    required init(
        configuration: MuterConfiguration? = nil,
        sourceCodeInfo: SourceCodeInfo,
        mutationOperatorId: MutationOperator.Id,
        coverage: FileCoverage
    ) {
        self.configuration = configuration
        self.sourceCodeInfo = sourceCodeInfo
        self.mutationOperatorId = mutationOperatorId
        self.coverage = coverage

        schemataMappings = SchemataMutationMapping(
            filePath: sourceCodeInfo.path
        )

        super.init(viewMode: .sourceAccurate)
    }

    /// Makes what the coverage checks need at the top of the tree. Made at the first mutant, which can be deep in a
    /// long expression, their own recursion would start on top of the visitor's, and could run out of a discovery
    /// thread's stack.
    override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
        _ = locationConverter
        if !coverage.functions.isEmpty {
            _ = executionCounts
        }

        return super.visit(node)
    }

    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        checkNodeForDisableTag(node)

        return super.visitAny(node)
    }

    func checkNodeForDisableTag(_ node: SyntaxProtocol) {
        isDisabled = isDisabled
            && !node.containsLineComment(muterEnabledTag)
            || !isDisabled
            && node.containsLineComment(muterDisableTag)
    }

    /// Whether the tests ran `node`, by the innermost region that holds all of it.
    func hasTestCoverage(
        _ node: SyntaxProtocol
    ) -> Bool {
        coverage.functions.isEmpty || executionCounts.ran(node)
    }

    func startLocation(
        for node: SyntaxProtocol
    ) -> MutationPosition {
        let sourceLocation = node.startLocation(
            converter: locationConverter
        )

        return mutationPosition(
            for: sourceLocation
        )
    }

    func endLocation(
        for node: SyntaxProtocol
    ) -> MutationPosition {
        let sourceLocation = node.endLocation(
            converter: locationConverter,
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

    /// Adds the mutant that replaces `syntax` with `mutation`. `changed` is the node the mutant changes, when that
    /// isn't `syntax` itself, as RemoveSideEffects replaces a body's statement list to remove one statement.
    func add(
        mutation: SyntaxProtocol,
        with syntax: SyntaxProtocol,
        at position: MutationPosition,
        snapshot: MutationOperator.Snapshot,
        changing changed: SyntaxProtocol? = nil
    ) {
        guard !isDisabled else {
            return
        }

        // Checked by the node it changes, not by the nodes around it. A region the tests never ran can start inside
        // all of them, as the right-hand side of `a && b > c`, which is a closure of its own, does: such a mutant could
        // only survive. And a local function's or type's code can run though the code that declares it never did.
        guard hasTestCoverage(changed ?? syntax) else {
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
            snapshot: snapshot,
            under: projectRoot
        )
    }
}
