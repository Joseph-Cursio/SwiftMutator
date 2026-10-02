import Foundation
import SwiftSyntax

typealias MutationSchemata = [MutationSchema]

/// A key that identifies a code block by its STABLE source position (the UTF-8 byte offset of its
/// first token) plus its text, rather than by SwiftSyntax node identity.
///
/// The mapping used to be keyed by `CodeBlockItemListSyntax` directly, but `Syntax` hashes on
/// `SyntaxIdentifier` — i.e. node IDENTITY, tied to a specific parse tree. `ApplySchemata` re-parses
/// each source file (on-demand re-parsing avoids memory exhaustion on large codebases), producing
/// fresh node identities, so the rewriter's lookup never matched what discovery inserted — schemata
/// were silently never applied and every mutant was reported as "survived" (0% score). Two parses of
/// the same bytes yield the same offset + text, so this key is stable across re-parsing.
struct CodeBlockKey: Hashable {
    let offset: Int
    let text: String

    init(_ node: CodeBlockItemListSyntax) {
        offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        text = node.description
    }

    init(offset: Int, text: String) {
        self.offset = offset
        self.text = text
    }
}

final class SchemataMutationMapping {
    let filePath: String
    fileprivate var mappings: [CodeBlockKey: MutationSchemata]
    // Preserves the code-block text for each key so `codeBlocks` / `description` keep reporting source.
    fileprivate var codeBlockText: [CodeBlockKey: String]

    var count: Int {
        mappings.count
    }

    var isEmpty: Bool {
        mappings.isEmpty
    }

    var mutationSchemata: MutationSchemata {
        Array(mappings.values).reduce([], +).sorted()
    }

    var codeBlocks: [String] {
        mappings.keys.compactMap { codeBlockText[$0] }.sorted()
    }

    var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }

    convenience init(
        filePath: String = ""
    ) {
        self.init(
            filePath: filePath,
            mappings: [:],
            codeBlockText: [:]
        )
    }

    fileprivate init(
        filePath: String = "",
        mappings: [CodeBlockKey: MutationSchemata],
        codeBlockText: [CodeBlockKey: String] = [:]
    ) {
        self.filePath = filePath
        self.mappings = mappings
        self.codeBlockText = codeBlockText
    }

    func add(
        _ codeBlockSyntax: CodeBlockItemListSyntax,
        _ schemata: MutationSchema
    ) {
        let key = CodeBlockKey(codeBlockSyntax)
        codeBlockText[key] = codeBlockSyntax.description
        mappings[key, default: []].append(schemata)
    }

    func add(
        _ codeBlockSyntax: CodeBlockItemListSyntax,
        _ schemata: MutationSchemata
    ) {
        let key = CodeBlockKey(codeBlockSyntax)
        codeBlockText[key] = codeBlockSyntax.description
        mappings[key, default: []].append(contentsOf: schemata)
    }

    func schemata(
        _ codeBlockSyntax: CodeBlockItemListSyntax
    ) -> MutationSchemata? {
        mappings[CodeBlockKey(codeBlockSyntax)]
    }

    /// Drops the mutants of every block nested inside a mutated opaque-typed, non-builder body.
    ///
    /// That body's switch compiles as an `if` expression, whose branches must share one type. A
    /// nested switch inside a builder closure (a SwiftUI `label:`, say) turns the default branch's
    /// view into `_ConditionalContent<…>` while the mutant branches keep the original type, and the
    /// shared build of every mutant fails. The nested mutants go rather than being misreported; the
    /// body's own mutants stay. `source` must be the tree the mappings were discovered in.
    func dropNestedSchemataInOpaqueBodies(of source: SourceFileSyntax) {
        let lists = CodeBlockListCollector.lists(in: source)
        let opaqueBodies = lists.filter { mappings[CodeBlockKey($0)] != nil && $0.isOpaqueNonBuilderBody }

        for body in opaqueBodies {
            for nested in lists where nested.isNested(inside: body) {
                let key = CodeBlockKey(nested)
                mappings[key] = nil
                codeBlockText[key] = nil
            }
        }
    }

    // Key-based add for merging two mappings without reconstructing a syntax node from text.
    fileprivate func add(
        _ key: CodeBlockKey,
        text: String,
        _ schemata: MutationSchemata
    ) {
        codeBlockText[key] = text
        mappings[key, default: []].append(contentsOf: schemata)
    }
}

extension SchemataMutationMapping: Codable {
    enum CodingKeys: String, CodingKey {
        case filePath
        case mappings
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let schematas = try container.decode([MutationSchema].self, forKey: .mappings)
        let filePath = try container.decode(String.self, forKey: .filePath)

        // Re-key each decoded schema by its own stable source offset rather than collapsing them all
        // under one empty-block key (which previously merged every schema into a single mapping entry).
        var mappings: [CodeBlockKey: MutationSchemata] = [:]
        for schema in schematas {
            let key = CodeBlockKey(offset: schema.position.utf8Offset, text: schema.snapshot.before)
            mappings[key, default: []].append(schema)
        }

        self.init(
            filePath: filePath,
            mappings: mappings
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(filePath, forKey: .filePath)
        try container.encode(mutationSchemata, forKey: .mappings)
    }
}

extension SchemataMutationMapping: Equatable {
    static func == (
        lhs: SchemataMutationMapping,
        rhs: SchemataMutationMapping
    ) -> Bool {
        lhs.codeBlocks == rhs.codeBlocks &&
            lhs.mutationSchemata == rhs.mutationSchemata
    }
}

func + (
    lhs: SchemataMutationMapping,
    rhs: SchemataMutationMapping
) -> SchemataMutationMapping {
    let result = SchemataMutationMapping(
        filePath: lhs.filePath
    )

    let mergedMappings = lhs.mappings.merging(rhs.mappings) { $0 + $1 }
    let mergedText = lhs.codeBlockText.merging(rhs.codeBlockText) { current, _ in current }

    for (key, schemata) in mergedMappings {
        result.add(key, text: mergedText[key] ?? key.text, schemata)
    }

    return result
}

extension [SchemataMutationMapping] {
    func mergeByFileName() -> Self {
        var result = [FileName: SchemataMutationMapping]()

        for map in self {
            if let exists = result[map.fileName] {
                result[map.fileName] = exists + map
            } else {
                result[map.fileName] = map
            }
        }

        return Array(result.values)
    }
}

// Pretty print for testing assertions description
extension SchemataMutationMapping: CustomStringConvertible, CustomDebugStringConvertible {
    var debugDescription: String { description }

    var description: String {
        let description = mappings.keys.sorted().reduce(into: "") { accum, key in
            let source = (codeBlockText[key] ?? key.text)
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\"", with: "\\\"")
            accum +=
                """
                source: "\(source)",
                schemata: \(mappings[key]!)
                """
        }
        return """
        SchemataMutationMapping(
            \(description)
        )
        """
    }
}

extension CodeBlockKey: Comparable {
    static func < (lhs: CodeBlockKey, rhs: CodeBlockKey) -> Bool {
        lhs.text < rhs.text
    }
}

/// Every statement list in a file, in source order.
private final class CodeBlockListCollector: SyntaxVisitor {
    private var lists: [CodeBlockItemListSyntax] = []

    static func lists(in source: SourceFileSyntax) -> [CodeBlockItemListSyntax] {
        let collector = CodeBlockListCollector(viewMode: .sourceAccurate)
        collector.walk(source)
        return collector.lists
    }

    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
        lists.append(node)
        return .visitChildren
    }
}

private extension CodeBlockItemListSyntax {
    func isNested(inside outer: CodeBlockItemListSyntax) -> Bool {
        var ancestor = parent
        while let current = ancestor {
            if current.id == outer.id {
                return true
            }
            ancestor = current.parent
        }
        return false
    }

    /// The statements of a getter or function whose result type is `some …` and that is not a
    /// result builder: neither marked `@…Builder` nor a `body`, which `View` makes a builder.
    var isOpaqueNonBuilderBody: Bool {
        guard let parent else {
            return false
        }
        // `var x: some View { … }`: the getter's statements sit directly in the accessor block.
        if let accessorBlock = parent.as(AccessorBlockSyntax.self) {
            return accessorBlock.parent?.as(PatternBindingSyntax.self)?.isOpaqueNonBuilder ?? false
        }
        guard let block = parent.as(CodeBlockSyntax.self) else {
            return false
        }
        if let function = block.parent?.as(FunctionDeclSyntax.self) {
            return function.signature.returnClause?.type.isOpaque == true
                && !function.attributes.containsResultBuilder
        }
        // `var x: some View { get { … } }`
        if let accessor = block.parent?.as(AccessorDeclSyntax.self) {
            var ancestor = accessor.parent
            while let current = ancestor {
                if let binding = current.as(PatternBindingSyntax.self) {
                    return binding.isOpaqueNonBuilder
                }
                ancestor = current.parent
            }
        }
        return false
    }
}

private extension PatternBindingSyntax {
    var isOpaqueNonBuilder: Bool {
        guard typeAnnotation?.type.isOpaque == true else {
            return false
        }
        if pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "body" {
            return false
        }
        let declaration = parent?.parent?.as(VariableDeclSyntax.self)
        return !(declaration?.attributes.containsResultBuilder ?? false)
    }
}

private extension TypeSyntax {
    var isOpaque: Bool {
        self.as(SomeOrAnyTypeSyntax.self)?.someOrAnySpecifier.tokenKind == .keyword(.some)
    }
}

private extension AttributeListSyntax {
    var containsResultBuilder: Bool {
        contains { element in
            element.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
        }
    }
}
