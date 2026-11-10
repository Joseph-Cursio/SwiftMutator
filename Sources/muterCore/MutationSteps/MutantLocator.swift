import Foundation
import SwiftParser
import SwiftSyntax

/// Where the compiler's errors are in a rewritten file, which `MutationSwitch` and `MuterRewriter` wrote.
struct MutantLocator {
    enum Place: Equatable {
        /// In a mutant's branch, which holds no other switch: nested switches are all in final `else`s.
        case branch(String, chain: [String])
        /// In the condition of a switch's branch, which SwiftMutator wrote.
        case condition
        /// On a chain's `if` or `else`, or in its final `else`: not one branch's.
        case wholeSwitch(chain: [String])
        /// In the environment cache SwiftMutator appends to the file.
        case environmentCache
        /// In an `import`, which no mutant changes, and which SwiftMutator's own `import Foundation` is one of.
        case importDeclaration
        /// In no switch.
        case outside
    }

    private let tree: SourceFileSyntax
    private let converter: SourceLocationConverter
    private let cacheName: String

    init(rewritten code: String, filePath: String) {
        tree = Parser.parse(source: code)
        converter = SourceLocationConverter(fileName: filePath, tree: tree)
        cacheName = MuterRewriter.environmentCacheName(forFileAt: filePath)
    }

    /// Who `error` is blamed on, and how widely: nil for an error in the code SwiftMutator wrote that every mutant
    /// shares, where it isn't any mutant's. That used to stop the run, and must still: taking the mutants out would
    /// make the file compile, and hide a bug that loses every mutant. nil too for an error in an `import`, which is the
    /// project's, however its next build goes. `removals` are the mutants that remove a statement.
    func mutantsAt(
        _ error: CompilerError,
        everyMutant: [String],
        afterFailedBuilds failedBuilds: Int,
        removals: Set<String> = []
    ) -> (blame: LeftOutMutant.Blame, ids: [String])? {
        let place = place(line: error.line, column: error.column)
        let closely: (LeftOutMutant.Blame, [String])
        switch place {
        case .condition, .environmentCache, .importDeclaration:
            return nil

        case let .branch(id, chain):
            // The compiler reports this on the first branch of a differing type, whichever mutants are at fault.
            closely = error.message.contains("branches have mismatching types") ? (.itsSwitch, chain) : (.itself, [id])

        case let .wholeSwitch(chain):
            closely = (.itsSwitch, chain)

        case .outside:
            closely = removalsAround(error, removals: removals) ?? around(error, everyMutant: everyMutant)
        }
        switch (failedBuilds - 1) / CompileRecovery.buildsPerWidening {
        case 0: return closely
        case 1: return around(error, everyMutant: everyMutant)
        default: return (.itsFile, everyMutant)
        }
    }

    /// The mutants around `error` that remove a statement, if any. A missing `return`, a `guard` that falls through and
    /// a use before initialization come of a statement that is gone, and are reported on code around it, so these are
    /// the ones to take out first: every other mutant around them may be innocent. If the error stays, they are gone,
    /// and the next build's blame is the others'.
    private func removalsAround(_ error: CompilerError, removals: Set<String>) -> (LeftOutMutant.Blame, [String])? {
        let around = mutantsInEnclosingBody(line: error.line, column: error.column).filter(removals.contains)
        guard !around.isEmpty else { return nil }
        return (around.count == 1 ? .itself : .itsEnclosingCode, around)
    }

    private func around(_ error: CompilerError, everyMutant: [String]) -> (LeftOutMutant.Blame, [String]) {
        let around = mutantsInEnclosingBody(line: error.line, column: error.column)
        return around.isEmpty ? (.itsFile, everyMutant) : (.itsEnclosingCode, around)
    }

    /// Whether `error` says that a result builder can't take an `if`, as one without `buildEither` can't take one with
    /// an `else`, which every switch has (#206).
    static func saysABuilderCantTakeASwitch(_ error: CompilerError) -> Bool {
        error.message.contains("control flow statement cannot be used with result builder")
    }

    /// A mutant of the switch on whose `if` `error` says a result builder can't take it, when the switch is all of a
    /// closure's statements, and they can go in a closure called on the spot instead
    /// (`CodeBlockItemListSyntax.canBeSwitchedInAClosure`); nil otherwise. A switch in such a closure already holds
    /// `return`s, so it is never one.
    func switchABuilderCantTake(_ error: CompilerError) -> String? {
        guard Self.saysABuilderCantTakeASwitch(error),
              let token = token(line: error.line, column: error.column), token.tokenKind == .keyword(.if),
              var head = token.parent?.as(IfExprSyntax.self), let id = mutantID(of: head)
        else { return nil }
        while let previous = head.parent?.as(IfExprSyntax.self), previous.elseBody?.id == head.id {
            head = previous
        }
        var statement = Syntax(head)
        if let expressionStatement = statement.parent?.as(ExpressionStmtSyntax.self) {
            statement = Syntax(expressionStatement)
        }
        guard let list = statement.parent?.as(CodeBlockItemSyntax.self)?.parent?.as(CodeBlockItemListSyntax.self),
              list.count == 1, let closure = list.parent?.as(ClosureExprSyntax.self)
        else { return nil }
        // The final `else` holds the closure's statements as they were.
        var last = head
        while case let .ifExpr(next)? = last.elseBody {
            last = next
        }
        guard case let .codeBlock(original)? = last.elseBody,
              original.statements.canBeSwitchedInAClosure(of: closure)
        else { return nil }
        return id
    }

    func place(line: Int, column: Int) -> Place {
        guard let token = token(line: line, column: column) else { return .outside }
        var node = Syntax(token)
        var inFinalElseOf: IfExprSyntax?
        while let parent = node.parent {
            defer { node = parent }
            if parent.as(EnumDeclSyntax.self)?.name.text == cacheName { return .environmentCache }
            if parent.is(ImportDeclSyntax.self) { return .importDeclaration }
            guard let link = parent.as(IfExprSyntax.self), let id = mutantID(of: link) else { continue }
            if node.id == link.conditions.id { return .condition }
            if node.id == link.body.id { return .branch(id, chain: chain(around: link)) }
            if node.id == link.elseBody?.id {
                inFinalElseOf = inFinalElseOf ?? link
                continue
            }
            return .wholeSwitch(chain: chain(around: link))
        }
        return inFinalElseOf.map { .wholeSwitch(chain: chain(around: $0)) } ?? .outside
    }

    /// Every mutant in the nearest function, accessor, initializer, closure, initial value or parameter around a
    /// place that has any. A missing `return`, a `guard` that falls through, a use before initialization and opaque
    /// types that don't match are all reported on code around the switch at fault.
    func mutantsInEnclosingBody(line: Int, column: Int) -> [String] {
        var ancestor = token(line: line, column: column)?.parent
        while let node = ancestor {
            if node.is(ClosureExprSyntax.self) || node.is(FunctionDeclSyntax.self)
                || node.is(InitializerDeclSyntax.self) || node.is(AccessorDeclSyntax.self)
                || node.is(PatternBindingSyntax.self) || node.is(SubscriptDeclSyntax.self)
                || node.is(FunctionParameterSyntax.self) || node.is(EnumCaseParameterSyntax.self) {
                let mutants = node.tokens(viewMode: .sourceAccurate).compactMap { token -> String? in
                    guard token.tokenKind == .keyword(.if), let link = token.parent?.as(IfExprSyntax.self) else {
                        return nil
                    }
                    return mutantID(of: link)
                }
                if !mutants.isEmpty { return mutants }
            }
            ancestor = node.parent
        }
        return []
    }

    /// The compiler counts columns in UTF-8 bytes, as this does, and in its default style its line breaks are this
    /// one's. With `-diagnostic-style=llvm` it doesn't count a lone carriage return as one, so an error after one in a
    /// file is looked for too early, where it can blame other mutants: they are still build errors, and said to be.
    private func token(line: Int, column: Int) -> TokenSyntax? {
        tree.token(at: converter.position(ofLine: line, column: column))
    }

    /// `<cache>.environment["<id>"] != nil`, the first of the two conditions `MutationSwitch` writes; nil for a
    /// project's own `if`.
    private func mutantID(of link: IfExprSyntax) -> String? {
        guard link.conditions.count == 2,
              case let .expression(condition)? = link.conditions.first?.condition,
              let call = condition.as(SequenceExprSyntax.self)?.elements.first?.as(SubscriptCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "environment",
              member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == cacheName,
              let literal = call.arguments.first?.expression.as(StringLiteralExprSyntax.self)
        else { return nil }
        return literal.segments.first?.as(StringSegmentSyntax.self)?.content.text
    }

    /// The mutants of the chain of `else if`s that `link` is one of.
    private func chain(around link: IfExprSyntax) -> [String] {
        var head = link
        while let previous = head.parent?.as(IfExprSyntax.self), previous.elseBody?.id == head.id {
            head = previous
        }
        return sequence(first: head) { $0.elseBody?.as(IfExprSyntax.self) }.compactMap(mutantID)
    }
}
