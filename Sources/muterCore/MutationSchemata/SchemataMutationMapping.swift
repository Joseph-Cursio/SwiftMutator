import Foundation
import SwiftSyntax

typealias MutationSchemata = [MutationSchema]

/// A file's mutants, by the code block each one rewrites. A value rather than a class, so that discovery's tasks can
/// each build their file's and hand it back, and nothing after discovery can change one that another step holds.
struct SchemataMutationMapping: Sendable, Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let filePath: String
    private var mappings: [CodeBlockKey: MutationSchemata]
    // Preserves the code-block text for each key so `codeBlocks` / `description` keep reporting source.
    private var codeBlockText: [CodeBlockKey: String]
    /// The statement lists whose switch goes in a closure called on the spot, as `CompileRecovery` found a result
    /// builder that can't take an `if` (`switchInAClosureCalledOnTheSpot(theListOf:)`).
    private var calledOnTheSpot: Set<CodeBlockKey> = []

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

    private init(
        filePath: String,
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
    func relative(to root: URL) -> Self {
        withPaths { RepoRelativePath.of($0, under: root) }
    }

    /// The same mutants with every relative path joined to `root`, as a test plan is read; an absolute path stays as
    /// it is. The inverse of `relative(to:)`.
    func resolved(under root: URL) -> Self {
        withPaths { RepoRelativePath.resolve($0, under: root.path) }
    }

    private func withPaths(_ path: (String) -> String) -> Self {
        Self(
            filePath: path(filePath),
            mappings: mappings.mapValues { schemata in schemata.map { $0.with(filePath: path($0.filePath)) } },
            codeBlockText: codeBlockText,
            calledOnTheSpot: calledOnTheSpot
        )
    }

    // Key-based add for merging two mappings without reconstructing a syntax node from text.
    private mutating func add(
        _ key: CodeBlockKey,
        text: String,
        _ schemata: MutationSchemata
    ) {
        codeBlockText[key] = text
        mappings[key, default: []].append(contentsOf: schemata)
    }

    static func + (
        lhs: Self,
        rhs: Self
    ) -> Self {
        var result = Self(
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

    enum CodingKeys: String, CodingKey {
        case filePath
        case mappings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let schematas = try container.decode([MutationSchema].self, forKey: .mappings)
        let decodedPath = try container.decode(String.self, forKey: .filePath)

        // Re-key each decoded schema by its own stable source offset rather than collapsing them all
        // under one empty-block key (which previously merged every schema into a single mapping entry).
        var byKey: [CodeBlockKey: MutationSchemata] = [:]
        for schema in schematas {
            let key = CodeBlockKey(offset: schema.position.utf8Offset, text: schema.snapshot.before)
            byKey[key, default: []].append(schema)
        }

        self.init(
            filePath: decodedPath,
            mappings: byKey
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(filePath, forKey: .filePath)
        try container.encode(mutationSchemata, forKey: .mappings)
    }

    static func == (
        lhs: Self,
        rhs: Self
    ) -> Bool {
        lhs.codeBlocks == rhs.codeBlocks &&
            lhs.mutationSchemata == rhs.mutationSchemata
    }

    // Pretty print for testing assertions description
    var debugDescription: String { description }

    var description: String {
        let listing = mappings.sorted { $0.key < $1.key }.reduce(into: "") { accum, entry in
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
            \(listing)
        )
        """
    }
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
