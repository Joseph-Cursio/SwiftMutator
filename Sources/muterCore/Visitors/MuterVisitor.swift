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
    private(set) var isDisabled = false
    /// What the file's `muter:` comments leave out. Worked out once, from the whole file.
    private var directives: MuterDirectives?

    let configuration: MuterConfiguration?
    let sourceCodeInfo: SourceCodeInfo
    let mutationOperatorId: MutationOperator.Id
    let coverage: FileCoverage

    var sourceCodePreparationChange: MutationSourceCodePreparationChange = .null
    /// The mutated project's folder, which each mutant's switch ID gives its file's path from (`MutationSchema.id`).
    /// Discovery sets it; a test of one file can leave it out.
    var projectRoot: URL?
    /// The code an `#if` leaves out of the build. Discovery sets it, when it can tell; a test of one file can leave it
    /// out, and then every branch keeps its mutants.
    var inactiveRegions: [Range<AbsolutePosition>] = []

    private(set) var schemataMappings: SchemataMutationMapping
    /// The mutants of this code with nowhere to put a switch, which aren't in `schemataMappings`.
    private(set) var droppedMutants: [DroppedMutant] = []

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

        // A mutant of a `#if` condition changes which branch compiles, and a branch for another platform may not build,
        // which fails the build every mutant shares.
        guard node.parent?.as(IfConfigClauseSyntax.self)?.condition?.id != node.id else {
            return .skipChildren
        }

        return super.visitAny(node)
    }

    /// Asks where `node` is, not which nodes came before it, as nodes that share a comment would each act on it.
    func checkNodeForDisableTag(_ node: SyntaxProtocol) {
        isDisabled = directives(in: node.root).isSwitchedOff(at: node.positionAfterSkippingLeadingTrivia)
    }

    private func directives(in root: Syntax) -> MuterDirectives {
        if let directives {
            return directives
        }
        let made = MuterDirectives(in: root, converter: locationConverter)
        directives = made
        return made
    }

    /// Whether the tests ran `node`, by the innermost region that holds all of it.
    func hasTestCoverage(
        _ node: SyntaxProtocol
    ) -> Bool {
        coverage.functions.isEmpty || executionCounts.ran(node)
    }

    /// Where `node` starts. Before its leading trivia, unless asked otherwise, which for a node that starts a line is
    /// the end of the line before.
    func startLocation(
        for node: SyntaxProtocol,
        afterLeadingTrivia: Bool = false
    ) -> MutationPosition {
        let sourceLocation = node.startLocation(
            converter: locationConverter,
            afterLeadingTrivia: afterLeadingTrivia
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

    /// The lines `node`'s code is on, without the comments and blank lines around it, as the original file numbers
    /// them.
    private func lines(of node: SyntaxProtocol) -> ClosedRange<Int> {
        let first = locationConverter.location(for: node.positionAfterSkippingLeadingTrivia).line
        let last = locationConverter.location(for: node.endPositionBeforeTrailingTrivia).line
        let offset = sourceCodePreparationChange.newLines
        return (first - offset)...max(first, last) - offset
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
        let codeBlockWithMutation = String(decoding: codeBlockBytes, as: UTF8.self)

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
    /// isn't `syntax` itself, as RemoveSideEffects replaces a body's statement list to remove one statement. `span` is
    /// the code whose lines `--changed-lines` checks, when that is more than `changed`, as an operator's operands are.
    func add(
        mutation: SyntaxProtocol,
        with syntax: SyntaxProtocol,
        at position: MutationPosition,
        snapshot: MutationOperator.Snapshot,
        changing changed: SyntaxProtocol? = nil,
        spanning span: SyntaxProtocol? = nil
    ) {
        // By where the code it changes starts, as the inactive region and coverage checks below are, and by where the
        // mutant is reported, which for a ternary's first link is where its list ends.
        let directives = directives(in: syntax.root)
        guard !isDisabled,
              !directives.isLeftOut((changed ?? syntax).positionAfterSkippingLeadingTrivia),
              !directives.isLeftOut(AbsolutePosition(utf8Offset: position.utf8Offset))
        else {
            return
        }

        // Before coverage, which can also skip such code, so that a run says the same with coverage and without.
        guard !isInInactiveRegion(changed ?? syntax) else {
            let lines = lines(of: span ?? changed ?? syntax)
            drop(reason: .inInactiveIfConfig, at: position, snapshot: snapshot, lines: lines)
            return
        }

        // Checked by the node it changes, not by the nodes around it. A region the tests never ran can start inside
        // all of them, as the right-hand side of `a && b > c`, which is a closure of its own, does: such a mutant could
        // only survive. And a local function's or type's code can run though the code that declares it never did.
        guard hasTestCoverage(changed ?? syntax) else {
            return
        }

        let lines = lines(of: span ?? changed ?? syntax)
        guard let place = syntax.mutationSwitchPlace else {
            drop(reason: .noPlaceForASwitch, at: position, snapshot: snapshot, lines: lines)
            return
        }

        var schemata = makeSchemata(
            with: syntax,
            mutation: mutation,
            in: place,
            at: position,
            for: snapshot
        )
        schemata.lines = lines

        schemataMappings.add(at: place, schemata)
    }

    private func isInInactiveRegion(_ node: SyntaxProtocol) -> Bool {
        let position = node.positionAfterSkippingLeadingTrivia
        return inactiveRegions.contains { $0.contains(position) }
    }

    private func drop(
        reason: DroppedMutant.Reason,
        at position: MutationPosition,
        snapshot: MutationOperator.Snapshot,
        lines: ClosedRange<Int>
    ) {
        droppedMutants.append(DroppedMutant(
            path: mutantPath,
            mutationOperatorId: mutationOperatorId,
            position: position,
            snapshot: snapshot,
            lines: lines,
            reason: reason
        ))
    }

    /// The path a dropped mutant is listed by: relative to the project, or the file's name in a test of one file.
    private var mutantPath: String {
        projectRoot.map { RepoRelativePath.of(sourceCodeInfo.path, under: $0) }
            ?? URL(fileURLWithPath: sourceCodeInfo.path).lastPathComponent
    }

    func makeSchemata(
        with syntax: SyntaxProtocol,
        mutation: SyntaxProtocol,
        in place: MutationSwitchPlace,
        at position: MutationPosition,
        for snapshot: MutationOperator.Snapshot
    ) -> MutationSchema {
        MutationSchema(
            filePath: sourceCodeInfo.path,
            mutationOperatorId: mutationOperatorId,
            syntaxMutation: transform(
                node: syntax,
                mutatedSyntax: mutation,
                in: place.code
            ),
            position: position,
            snapshot: snapshot,
            under: projectRoot
        )
    }
}
