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
///
/// A body's one statement has the same offset and text as the body, so the key says which of them it is of, or the
/// rewriter would switch both.
struct CodeBlockKey: Hashable {
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
}

/// A file's mutants, by the code block each one rewrites. A value rather than a class, so that discovery's tasks can
/// each build their file's and hand it back, and nothing after discovery can change one that another step holds.
struct SchemataMutationMapping: Sendable {
    let filePath: String
    fileprivate var mappings: [CodeBlockKey: MutationSchemata]
    // Preserves the code-block text for each key so `codeBlocks` / `description` keep reporting source.
    fileprivate var codeBlockText: [CodeBlockKey: String]
    /// The statement lists whose switch goes in a closure called on the spot, as `CompileRecovery` found a result
    /// builder that can't take an `if` (`switchInAClosureCalledOnTheSpot(theListOf:)`).
    fileprivate var calledOnTheSpot: Set<CodeBlockKey> = []

    var count: Int {
        mappings.count
    }

    var isEmpty: Bool {
        mappings.isEmpty
    }

    /// The file's mutants in the order mutation testing runs them (`JobOrder.InFile`). Repeats of one place and
    /// operator keep the order discovery found them in, which their occurrences number: blocks in source order, and
    /// each block's mutants as they were added.
    var mutationSchemata: MutationSchemata {
        mappings.keys
            .sorted { ($0.offset, $0.text) < ($1.offset, $1.text) }
            .flatMap { mappings[$0] ?? [] }
            .enumerated()
            .sorted { ($0.element.orderInFile, $0.offset) < ($1.element.orderInFile, $1.offset) }
            .map(\.element)
    }

    var codeBlocks: [String] {
        mappings.keys.compactMap { codeBlockText[$0] }.sorted()
    }

    var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }

    init(
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
        codeBlockText: [CodeBlockKey: String] = [:],
        calledOnTheSpot: Set<CodeBlockKey> = []
    ) {
        self.filePath = filePath
        self.mappings = mappings
        self.codeBlockText = codeBlockText
        self.calledOnTheSpot = calledOnTheSpot
    }

    mutating func add(
        _ codeBlockSyntax: CodeBlockItemListSyntax,
        _ schemata: MutationSchema
    ) {
        let key = CodeBlockKey(codeBlockSyntax)
        codeBlockText[key] = codeBlockSyntax.description
        mappings[key, default: []].append(schemata)
    }

    mutating func add(
        _ codeBlockSyntax: CodeBlockItemListSyntax,
        _ schemata: MutationSchemata
    ) {
        let key = CodeBlockKey(codeBlockSyntax)
        codeBlockText[key] = codeBlockSyntax.description
        mappings[key, default: []].append(contentsOf: schemata)
    }

    mutating func add(
        at place: MutationSwitchPlace,
        _ schemata: MutationSchema
    ) {
        let key = CodeBlockKey(place)
        codeBlockText[key] = place.code.description
        mappings[key, default: []].append(schemata)
    }

    func schemata(
        _ codeBlockSyntax: CodeBlockItemListSyntax
    ) -> MutationSchemata? {
        mappings[CodeBlockKey(codeBlockSyntax)]
    }

    func schemata(at place: MutationSwitchPlace) -> MutationSchemata? {
        mappings[CodeBlockKey(place)]
    }

    /// Whether the switch of `list`'s mutants goes in a closure called on the spot.
    func switchesInAClosureCalledOnTheSpot(_ list: CodeBlockItemListSyntax) -> Bool {
        calledOnTheSpot.contains(CodeBlockKey(list))
    }

    /// Has the switch of the statement list that holds the mutant `id` go in a closure called on the spot, and says how
    /// many mutants the list holds; nil, changing nothing, when no list holds it, or its switch goes there already.
    ///
    /// A result builder makes `buildEither` calls of an `if` with an `else`, so one that has no `buildEither` can't
    /// take a switch in its closure (#206). Which builder a closure gets can't be told from the syntax, so the
    /// compiler's error says which. In a closure called on the spot the switch is no part of the builder's closure,
    /// which takes the call as one expression. `MuterRewriter` does it only where
    /// `CodeBlockItemListSyntax.canBeSwitchedInAClosure`.
    mutating func switchInAClosureCalledOnTheSpot(theListOf id: String) -> Int? {
        guard let (key, schemata) = mappings.first(where: { key, schemata in
            key.kind == .statements && schemata.contains { $0.id == id }
        }), calledOnTheSpot.insert(key).inserted
        else { return nil }
        return schemata.count
    }

    /// Drops the mutants of every block nested inside a mutated opaque-typed, non-builder body.
    ///
    /// That body's switch compiles as an `if` expression, whose branches must share one type. A
    /// nested switch inside a builder closure (a SwiftUI `label:`, say) turns the default branch's
    /// view into `_ConditionalContent<…>` while the mutant branches keep the original type, and the
    /// shared build of every mutant fails. The nested mutants go rather than being misreported; the
    /// body's own mutants stay. `source` must be the tree the mappings were discovered in. It returns those it drops.
    @discardableResult
    mutating func dropNestedSchemataInOpaqueBodies(of source: SourceFileSyntax) -> MutationSchemata {
        var dropped: MutationSchemata = []
        let lists = CodeBlockListCollector.lists(in: source)
        let opaqueBodies = lists.filter { mappings[CodeBlockKey($0)] != nil && $0.isOpaqueNonBuilderBody }

        for body in opaqueBodies {
            for nested in lists where nested.isNested(inside: body) {
                let key = CodeBlockKey(nested)
                dropped += mappings[key] ?? []
                mappings[key] = nil
                codeBlockText[key] = nil
            }
        }
        // A value's switch is an `if` expression too, and a builder closure can give the type it makes a type of its
        // own. Which closures are builders' can't be told from the syntax, but a generic type's initializer is what
        // makes that type, and a type the value's annotation names can't depend on the closure.
        for list in lists where mappings[CodeBlockKey(list)] != nil {
            guard let value = list.valueWhoseTypeCanDependOnIt,
                  mappings[CodeBlockKey(.initialValue(value))] != nil
            else {
                continue
            }
            let key = CodeBlockKey(list)
            dropped += mappings[key] ?? []
            mappings[key] = nil
            codeBlockText[key] = nil
        }
        return dropped
    }

    /// Keeps only the mutants `isKept` keeps, and the blocks left with any.
    mutating func keepOnly(_ isKept: (MutationSchema) -> Bool) {
        for (key, schemata) in mappings {
            let kept = schemata.filter(isKept)
            mappings[key] = kept.isEmpty ? nil : kept
            if kept.isEmpty {
                codeBlockText[key] = nil
                calledOnTheSpot.remove(key)
            }
        }
    }

    /// The same mutants with every path, the file's and each mutant's, relative to `root`, as a test plan writes
    /// them; a path outside `root` stays absolute. Each mutant keeps its ID and its place in the file's order.
    func relative(to root: URL) -> SchemataMutationMapping {
        withPaths { RepoRelativePath.of($0, under: root) }
    }

    /// The same mutants with every relative path joined to `root`, as a test plan is read; an absolute path stays as
    /// it is. The inverse of `relative(to:)`.
    func resolved(under root: URL) -> SchemataMutationMapping {
        withPaths { RepoRelativePath.resolve($0, under: root.path) }
    }

    private func withPaths(_ path: (String) -> String) -> SchemataMutationMapping {
        SchemataMutationMapping(
            filePath: path(filePath),
            mappings: mappings.mapValues { schemata in schemata.map { $0.with(filePath: path($0.filePath)) } },
            codeBlockText: codeBlockText,
            calledOnTheSpot: calledOnTheSpot
        )
    }

    // Key-based add for merging two mappings without reconstructing a syntax node from text.
    fileprivate mutating func add(
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

    init(from decoder: Decoder) throws {
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
    var result = SchemataMutationMapping(
        filePath: lhs.filePath
    )

    let mergedMappings = lhs.mappings.merging(rhs.mappings) { $0 + $1 }
    let mergedText = lhs.codeBlockText.merging(rhs.codeBlockText) { current, _ in current }

    for (key, schemata) in mergedMappings {
        result.add(key, text: mergedText[key] ?? key.text, schemata)
    }
    result.calledOnTheSpot = lhs.calledOnTheSpot.union(rhs.calledOnTheSpot)

    return result
}

extension [SchemataMutationMapping] {
    /// Merges each file's mappings into one. Keyed by full path, not by file name: two files can
    /// share a name (one `main.swift` per executable target, an `Extensions.swift` in several
    /// modules), and `+` keeps only the left-hand path, so merging them put one file's mutants into
    /// the other, or nowhere.
    /// Sorted by path, so mutants are tested in the same order on every run.
    func mergeByFilePath() -> Self {
        var result = [FilePath: SchemataMutationMapping]()

        for map in self {
            if let exists = result[map.filePath] {
                result[map.filePath] = exists + map
            } else {
                result[map.filePath] = map
            }
        }

        return result.values.sorted { $0.filePath < $1.filePath }
    }
}

// Pretty print for testing assertions description
extension SchemataMutationMapping: CustomStringConvertible, CustomDebugStringConvertible {
    var debugDescription: String { description }

    var description: String {
        let description = mappings.sorted { $0.key < $1.key }.reduce(into: "") { accum, entry in
            let (key, schemata) = entry
            let source = (codeBlockText[key] ?? key.text)
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\"", with: "\\\"")
            accum +=
                """
                source: "\(source)",
                schemata: \(schemata)
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
    /// The stored property's or global's value this list is in, when it's in a closure passed to what looks like a
    /// type's initializer, `VStack { … }`, and the value's type isn't named, or is `some …`.
    var valueWhoseTypeCanDependOnIt: ExprSyntax? {
        var isInATypesClosure = false
        var ancestor = parent
        while let current = ancestor {
            if let closure = current.as(ClosureExprSyntax.self), closure.isPassedToAType {
                isInATypesClosure = true
            }
            if let clause = current.as(InitializerClauseSyntax.self), clause.isADeclarationsValue {
                guard isInATypesClosure, let binding = clause.parent?.as(PatternBindingSyntax.self) else { return nil }
                let type = binding.typeAnnotation?.type
                return type == nil || type?.isOpaque == true ? clause.value : nil
            }
            ancestor = current.parent
        }
        return nil
    }

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

private extension ClosureExprSyntax {
    /// Whether this closure is an argument of a call to a capitalized name, as a type's initializer is.
    var isPassedToAType: Bool {
        var ancestor = parent
        while let current = ancestor {
            if let call = current.as(FunctionCallExprSyntax.self) {
                let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
                    ?? call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
                    ?? call.calledExpression.as(GenericSpecializationExprSyntax.self)?.expression.trimmedDescription
                return name?.first?.isUppercase == true
            }
            guard current.is(LabeledExprSyntax.self) || current.is(LabeledExprListSyntax.self)
                || current.is(MultipleTrailingClosureElementSyntax.self)
                || current.is(MultipleTrailingClosureElementListSyntax.self)
            else { return false }
            ancestor = current.parent
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

extension TypeSyntax {
    /// Whether the type is `some …`.
    var isOpaque: Bool {
        self.as(SomeOrAnyTypeSyntax.self)?.someOrAnySpecifier.tokenKind == .keyword(.some)
    }
}

extension AttributeListSyntax {
    /// Whether one of the attributes is a result builder, by a name that ends in `Builder`, as `@ViewBuilder` does.
    var containsResultBuilder: Bool {
        contains { element in
            element.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
        }
    }
}
