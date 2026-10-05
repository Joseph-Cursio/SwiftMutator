import SwiftParser
import SwiftSyntax

final class MuterRewriter: SyntaxRewriter {
    private let schemataMappings: SchemataMutationMapping

    /// The file-private type holding the one copy of the environment every switch in a file reads.
    static let environmentCacheName = "__SwiftMutator"

    required init(_ schemataMappings: SchemataMutationMapping) {
        self.schemataMappings = schemataMappings
    }

    /// Appends the environment cache to a file that received switches. It goes at the end, so no
    /// line of the file moves and every recorded mutant position stays valid. A `static let` is
    /// initialised once, lazily and thread-safely, and unlike a top-level global it is safe in
    /// `main.swift`, where a global would not be initialised until execution reached it.
    ///
    /// The cache also adds the mutant named in the file `activeMutantFileKey` names, as if its own
    /// variable were set: a `swift test` run can't set that variable, because SwiftPM keys its cache of
    /// compiled package manifests on the whole environment. Only the file's first line counts, so a file
    /// written with `echo` works too. A file that can't be read stops the tests: switching no mutant on
    /// would let every mutant survive.
    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        let rewritten = super.visit(node)
        guard rewritten.description.contains("\(Self.environmentCacheName).environment[") else {
            return rewritten
        }

        // A plain literal, so `\\(path)` keeps the interpolation in the generated code.
        let cache = Parser.parse(source: """

        fileprivate enum \(Self.environmentCacheName) {
            static let environment: [String: String] = {
                var environment = ProcessInfo.processInfo.environment
                if let path = environment["\(activeMutantFileKey)"] {
                    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                        fatalError("SwiftMutator could not read the active mutant from \\(path)")
                    }
                    let identifier = String(contents.prefix { !$0.isNewline })
                    if !identifier.isEmpty {
                        environment[identifier] = "YES"
                    }
                }
                return environment
            }()
        }

        """).statements

        return rewritten.with(\.statements, CodeBlockItemListSyntax(Array(rewritten.statements) + Array(cache)))
    }

    override func visit(_ node: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
        guard let mutationSchemata = schemataMappings.schemata(node) else {
            return super.visit(node)
        }

        // Rewrite the CHILDREN first, on the original node, then wrap the result.
        //
        // Applying the switch first and visiting the synthesized node loses every nested code block's
        // mutants: wrapping shifts the nested blocks' source positions, so their mapping entries no
        // longer match and their switches are silently never inserted. A closure or ternary body
        // therefore had mutants discovered and then dropped. Visiting the original node keeps the
        // nested positions the discovery pass recorded, and the rewritten children become the switch's
        // default branch.
        let childrenRewritten = super.visit(node)

        return MutationSwitch.apply(
            mutationSchemata: mutationSchemata,
            with: childrenRewritten
        )
    }
}
