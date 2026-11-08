import Foundation
import SwiftParser
import SwiftSyntax

final class MuterRewriter: SyntaxRewriter {
    private let schemataMappings: SchemataMutationMapping
    /// The type holding the one copy of the environment every switch in this file reads.
    private let environmentCacheName: String

    required init(_ schemataMappings: SchemataMutationMapping) {
        self.schemataMappings = schemataMappings
        environmentCacheName = Self.environmentCacheName(forFileAt: schemataMappings.filePath)
    }

    /// The name of the environment cache of the file at `path`: `__SwiftMutator_` and a hash of the file's name. The
    /// cache is internal, so each file of a module needs a name of its own, and a module can't hold two files of the
    /// same name. The name doesn't depend on where the project is, so the rewritten code is the same on every machine.
    static func environmentCacheName(forFileAt path: String) -> String {
        "__SwiftMutator_" + URL(fileURLWithPath: path).lastPathComponent.stableHash
    }

    /// Appends the environment cache to a file that received switches. It goes at the end, so no
    /// line of the file moves and every recorded mutant position stays valid. A `static let` is
    /// initialised once, lazily and thread-safely, and unlike a top-level global it is safe in
    /// `main.swift`, where a global would not be initialised until execution reached it.
    ///
    /// The cache is `@usableFromInline internal`, not `fileprivate`: an `@inlinable`, `@_alwaysEmitIntoClient`
    /// or `@_transparent` body, or a public function's default argument, can reference only public and
    /// `@usableFromInline` declarations, and a mutant there failed the build every mutant shares.
    ///
    /// The cache is `nonisolated`: in a module built with `-default-isolation MainActor` the enum is
    /// isolated to the main actor, and a mutant in nonisolated code, an actor, a `Sendable` closure or
    /// another global actor couldn't read it. `[String: String]` is `Sendable`, so no compiler back to
    /// Swift 5.9 warns about the attribute.
    ///
    /// The cache also adds the mutant named in the file `activeMutantFileKey` names, as if its own
    /// variable were set: a `swift test` run can't set that variable, because SwiftPM keys its cache of
    /// compiled package manifests on the whole environment. The file's first line names the mutant and the
    /// rest, if any, the run's activation marker (`activationMarkerKey`), whose path may hold a line break, so a
    /// file written with `echo` works too. A file that can't be read stops the tests: switching no mutant on
    /// would let every mutant survive.
    ///
    /// Reading the cache creates `<marker>.reached`: the run got its marker's path and can write there. `ran`, the
    /// condition after a mutant's own, creates the marker: the mutant's block ran. Each is created once per process,
    /// and any later process's write leaves it there, so `swift test --parallel` is safe. A write that fails does
    /// nothing: a test process with no marker reads as one that can't show it ran (`ActivationMarker`). `String`'s
    /// `write(toFile:)` because a file that imports only `class Foundation.ProcessInfo` sees no `FileManager`, yet
    /// sees `String`'s members. The body reads a bare `environment[`, so `\(cache).environment[` still finds switches.
    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        let rewritten = super.visit(node)
        guard rewritten.description.contains("\(environmentCacheName).environment[") else {
            return rewritten
        }

        // A plain literal, so `\\(path)` keeps the interpolation in the generated code.
        let cache = Parser.parse(source: """

        @usableFromInline internal enum \(environmentCacheName) {
            @usableFromInline nonisolated static let environment: [String: String] = {
                var environment = ProcessInfo.processInfo.environment
                if let path = environment["\(activeMutantFileKey)"] {
                    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                        fatalError("SwiftMutator could not read the active mutant from \\(path)")
                    }
                    let lines = contents.split(maxSplits: 1, omittingEmptySubsequences: false) { $0.isNewline }
                    if let identifier = lines.first, !identifier.isEmpty {
                        environment[String(identifier)] = "YES"
                    }
                    if lines.count > 1, !lines[1].isEmpty {
                        environment["\(activationMarkerKey)"] = String(lines[1])
                    }
                }
                if let marker = environment["\(activationMarkerKey)"] {
                    try? "".write(toFile: marker + "\(ActivationMarker.reachedSuffix)", atomically: false, encoding: .utf8)
                }
                return environment
            }()
            @usableFromInline nonisolated static let ran: Bool = {
                if let marker = environment["\(activationMarkerKey)"] {
                    try? "".write(toFile: marker, atomically: false, encoding: .utf8)
                }
                return true
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

        if schemataMappings.switchesInAClosureCalledOnTheSpot(node),
           let closure = node.parent?.as(ClosureExprSyntax.self),
           node.canBeSwitchedInAClosure(of: closure) {
            return MutationSwitch.inAClosureCalledOnTheSpot(
                mutationSchemata: mutationSchemata,
                with: childrenRewritten,
                onALineStartingWith: MutationSwitch.startOfTheFirstLine(of: node),
                readingEnvironmentFrom: environmentCacheName,
                throwing: node.throwsInItsClosure,
                awaiting: node.awaitsInItsClosure
            )
        }
        return MutationSwitch.apply(
            mutationSchemata: mutationSchemata,
            with: childrenRewritten,
            onALineStartingWith: MutationSwitch.startOfTheFirstLine(of: node),
            readingEnvironmentFrom: environmentCacheName,
            returningItsExpression: node.isAMacroItsBodyReturns
        )
    }

    /// A statement at a file's top level, beside declarations, which can't go in the switch.
    override func visit(_ node: CodeBlockItemSyntax) -> CodeBlockItemSyntax {
        guard let mutationSchemata = schemataMappings.schemata(at: .statement(node)) else {
            return super.visit(node)
        }
        let childrenRewritten = super.visit(node)
        // A `;` stays after the switch, for a statement that follows on its line.
        let list = CodeBlockItemListSyntax([childrenRewritten.with(\.semicolon, nil)])
        let switched = MutationSwitch.apply(
            mutationSchemata: mutationSchemata,
            with: list,
            onALineStartingWith: MutationSwitch.startOfTheFirstLine(of: node),
            readingEnvironmentFrom: environmentCacheName
        )
        guard let statement = switched.first else { return childrenRewritten }
        return statement.with(\.semicolon, node.semicolon)
    }

    /// A stored property's or a global's initial value, or a default argument, which have no statement list. Its
    /// switch is an `if` expression, so that each branch type-checks by itself, as a body's does, and `CompileRecovery`
    /// can tell the branches apart. A closure called on the spot holds it where that can't compile: a default argument,
    /// a macro alone as a branch (`MutationSwitch.apply`), and under an attribute that may copy the value into a call.
    /// The closure can't stand everywhere: `try` and `await` in a `main.swift`'s value would have to go around its
    /// call.
    override func visit(_ node: InitializerClauseSyntax) -> InitializerClauseSyntax {
        guard let mutationSchemata = schemataMappings.schemata(at: .initialValue(node.value)) else {
            return super.visit(node)
        }
        let childrenRewritten = super.visit(node)
        let isAMacro = node.value.is(MacroExpansionExprSyntax.self)
        let inAClosure = isAMacro || node.isADefaultArgument || node.isUnderAnAttribute
        // The value's line break and indentation go before the closure's brace, which would otherwise touch the `=`,
        // or end a comment after it.
        let value = inAClosure ? childrenRewritten.value.with(\.leadingTrivia, []) : childrenRewritten.value
        let switched = MutationSwitch.apply(
            mutationSchemata: mutationSchemata,
            with: CodeBlockItemListSyntax([CodeBlockItemSyntax(item: .expr(value))]),
            onALineStartingWith: MutationSwitch.startOfTheFirstLine(of: node.value),
            readingEnvironmentFrom: environmentCacheName,
            returningItsExpression: isAMacro
        )
        guard inAClosure else {
            guard case let .expr(switchedValue)? = switched.first?.item else { return childrenRewritten }
            return childrenRewritten.with(\.value, switchedValue)
        }
        let call = FunctionCallExprSyntax(
            calledExpression: ClosureExprSyntax(
                leftBrace: .leftBraceToken(leadingTrivia: childrenRewritten.value.leadingTrivia),
                statements: switched
            ),
            leftParen: .leftParenToken(),
            arguments: [],
            rightParen: .rightParenToken()
        )
        return childrenRewritten.with(\.value, ExprSyntax(call))
    }
}
