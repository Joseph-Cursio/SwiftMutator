import Foundation
import SwiftParser
import SwiftSyntax

/// A mutant `CompileRecovery` took out of the build: all its mutants share one, so a mutant that doesn't compile would
/// stop every other's tests. It keeps its place among the run's mutants, and its result says it wasn't tested.
struct LeftOutMutant: Equatable, Sendable {
    /// What the compiler's errors could be pinned on.
    enum Blame: Equatable, Sendable {
        /// The errors are in this mutant's own code.
        case itself
        /// On a switch as a whole, with no one mutant of it to blame.
        case itsSwitch
        /// In the function, accessor or closure around it, with no one mutant to blame.
        case itsEnclosingCode
        /// Elsewhere in its file, or in a build that had failed too many times to look closer.
        case itsFile
    }

    let blame: Blame
    /// The errors of the build that took it out.
    let errors: [CompilerError]
    /// That build's log, as the log folder keeps it.
    let buildLog: String

    /// The kept log of a mutant left out: why, as its tests have no log to give. Line numbers are of the file as it was
    /// rewritten for that build, so the errors are the compiler's own words, with the place left to the build's log.
    var log: String {
        let why = switch blame {
        case .itself: "as it doesn't compile"
        case .itsSwitch: "with the other mutants of its code, as the compiler's error could be any of theirs"
        case .itsEnclosingCode: "with the other mutants around it, as the compiler's error could be any of theirs"
        case .itsFile: "with the rest of its file's mutants, as the compiler's error could be any of theirs"
        }
        return (
            ["This mutant was taken out of the build, \(why). Its tests never ran.", ""]
                + errors.map { "  \($0.message)" }
                + ["", "The build's log is \(buildLog)."]
        ).joined(separator: "\n") + "\n"
    }
}

/// The mutants a run won't test, as they don't compile, for the warning that names them.
struct MutantsLeftOut: Equatable {
    struct Mutant: Equatable {
        let key: MutantKey
        /// What it changes, as its snapshot says.
        let change: String
        let mutant: LeftOutMutant

        /// `Sources/U/Version.swift:9:19 RelationalOperatorReplacement (< to >): binary operator '>' cannot be applied`
        var line: String {
            let change = change.isEmpty ? "" : " (\(change))"
            let others = switch mutant.blame {
            case .itself: ""
            case .itsSwitch: " [with the others of its code]"
            case .itsEnclosingCode: " [with the others around it]"
            case .itsFile: " [with the rest of its file]"
            }
            return "\(key)\(change): \(mutant.errors.first?.message ?? "")\(others)"
        }
    }

    /// How many a warning names; each one's log says why, whatever the warning leaves out.
    static let namedAtMost = 10

    let mutants: [Mutant]
    /// How many mutants the run does test.
    let toTest: Int
}

/// Keeps a mutant that doesn't compile from ending the run: each mutant is compiled into the one build they all share.
/// Given a failed build's log, it pins each compile error in a rewritten file on the mutants at fault, and writes those
/// files again without them. It stops, so that the failure stops the run as it would have, as soon as nothing can be
/// done: no error is in a file with mutants left, as for an error the project has anyway, or a failed test, or an error
/// is in code SwiftMutator wrote that every mutant shares.
struct CompileRecovery {
    /// How many failed builds it takes out mutants after: each takes out a file at least once the widening below has
    /// reached files, so only a project with very many files that fail one at a time gets here. It stops, as a build
    /// costs as much as a project's incremental build, and says so (`RunEvent.stoppedTakingOutMutants`).
    static let maximumBuilds = 20
    /// How many failed builds pin errors as closely as they can. The compiler can report one error of many per build,
    /// and each build takes as long as a project's incremental build. Then, for as many, errors are blamed on the code
    /// around them, and after that on their files, so that a project with many mutants that don't compile costs some
    /// innocent mutants rather than dozens of builds.
    static let buildsPerWidening = 5

    /// By switch ID, which mutants repeating a place and operator share.
    private(set) var leftOut: [String: LeftOutMutant] = [:]
    private(set) var failedBuilds = 0
    /// Each file's mutants still in the build. A file left without any stays, so its code is written back without
    /// switches.
    private var mappings: [SchemataMutationMapping]
    private let preparedSources: [FilePath: String]
    /// The copy, where a build runs, so what a relative path in its log is relative to.
    private let projectCopy: URL

    /// Whether the most failed builds have been taken out after, so the last build's errors may still be mutants'.
    var stopsAtTheMostBuilds: Bool { failedBuilds >= Self.maximumBuilds }

    @Dependency(\.writeFile)
    private var writeFile: WriteFile

    /// nil in a run of a test plan, whose copy may have been fixed by hand, and can't be rewritten: `preparedSources`
    /// is empty as it doesn't run `ApplySchemata`.
    init?(of state: AnyMutationTestState) {
        guard !state.runOptions.isUsingTestPlan, !state.preparedSources.isEmpty else { return nil }
        mappings = state.mutationMapping
        preparedSources = state.preparedSources
        projectCopy = state.mutatedProjectDirectoryURL
    }

    /// Takes out of the code the mutants that the build whose output is `log`, kept as `buildLog`, was failed by, and
    /// says how many; nil, changing nothing, when no mutant can be blamed and the failure has to stand.
    /// `testsMayHaveRun` when the command goes on to test what it builds, as a baseline does.
    mutating func takeOutMutants(
        failing log: String,
        keptAs buildLog: String,
        testsMayHaveRun: Bool = false
    ) async throws -> Int? {
        guard !Task.isCancelled, failedBuilds < Self.maximumBuilds, !testsMayHaveRun || !Self.testsStarted(in: log)
        else { return nil }
        failedBuilds += 1

        let errorsByFile = Dictionary(grouping: Set(CompilerError.all(in: log))) { error in
            let path = error.filePath.hasPrefix("/")
                ? error.filePath
                : projectCopy.appendingPathComponent(error.filePath).path
            return path.canonicalPath
        }
        var blamed: [String: LeftOutMutant] = [:]
        var files: [Int] = []
        for (index, mapping) in mappings.enumerated() where !mapping.isEmpty {
            guard let errors = errorsByFile[mapping.filePath.canonicalPath],
                  let prepared = preparedSources[mapping.filePath]
            else { continue }
            guard let inFile = await Self.mutantsToBlame(
                for: errors, inCodeOf: mapping, prepared: prepared, afterFailedBuilds: failedBuilds, buildLog: buildLog
            ) else { return nil }
            blamed.merge(inFile) { first, _ in first }
            if !inFile.isEmpty { files.append(index) }
        }
        guard !blamed.isEmpty else { return nil }

        var count = 0
        for index in files {
            let before = mappings[index].mutationSchemata.count
            mappings[index].keepOnly { blamed[$0.id] == nil }
            count += before - mappings[index].mutationSchemata.count
            try await writeAgain(mappings[index])
        }
        leftOut.merge(blamed) { first, _ in first }
        return count
    }

    /// Whether `log`'s last build finished, so that what failed after it is a test, not a compile error, whatever its
    /// lines look like. `swift test` says "Build complete!" before its tests run, as a command that builds something
    /// else first does before a build that can still fail, and a compiler's error can quote a line that holds these
    /// words. So only a line that starts with them counts, after the last line that starts a build. Not every build
    /// says either.
    static func testsStarted(in log: String) -> Bool {
        var built = false
        for line in log.split(whereSeparator: \.isNewline) where line.contains("Build") {
            let line = FailedTestLine.withoutColours(line)
            if line.hasPrefix("Build complete!") {
                built = true
            } else if line.hasPrefix("Building for") {
                built = false
            }
        }
        return built
    }

    /// Writes `mapping`'s file with its mutants' switches and no others. As `CheckMutantSwitches` does for the first
    /// rewrite, stops if a switch is missing: its mutant's tests would run the original code, and it would survive.
    private func writeAgain(_ mapping: SchemataMutationMapping) async throws {
        guard let prepared = preparedSources[mapping.filePath] else { return }
        let code = await ApplySchemata.rewritten(prepared, with: mapping)
        let missing = CheckMutantSwitches.mutantsWithoutASwitch(in: code, of: mapping)
        guard missing.isEmpty else {
            let gap = CheckMutantSwitches.Gap(mapping: mapping, missing: missing, unreadable: false)
            throw MuterError.literal(reason: CheckMutantSwitches.reason(for: [gap], usingTestPlan: false))
        }
        do {
            try writeFile(code, mapping.filePath)
        } catch {
            throw MuterError.literal(reason: error.localizedDescription)
        }
    }

    /// The mutants of `mapping` that `errors`, in its file as rewritten from `prepared`, are blamed on, by switch ID;
    /// nil when any error is in code that SwiftMutator wrote for every mutant.
    static func mutantsToBlame(
        for errors: [CompilerError],
        inCodeOf mapping: SchemataMutationMapping,
        prepared: String,
        afterFailedBuilds failedBuilds: Int,
        buildLog: String
    ) async -> [String: LeftOutMutant]? {
        let code = await ApplySchemata.rewritten(prepared, with: mapping)
        let everyMutant = mapping.mutationSchemata.map(\.id)
        let removals = Set(mapping.mutationSchemata.filter { $0.mutationOperatorId == .removeSideEffects }.map(\.id))
        let filePath = mapping.filePath
        // The locator's walk recurses, once per mutant in a list.
        return await ApplySchemata.onAStackOfItsOwn {
            let locator = MutantLocator(rewritten: code, filePath: filePath)
            var mutants: [String: (blame: LeftOutMutant.Blame, errors: [CompilerError])] = [:]
            let inOrder = errors.sorted { ($0.line, $0.column, $0.message) < ($1.line, $1.column, $1.message) }
            for error in inOrder {
                guard let (blame, ids) = locator.mutantsAt(
                    error, everyMutant: everyMutant, removals: removals, afterFailedBuilds: failedBuilds
                ) else { return nil }
                for id in ids {
                    var mutant = mutants[id] ?? (blame, [])
                    mutant.errors.append(error)
                    mutants[id] = mutant
                }
            }
            return mutants.mapValues {
                LeftOutMutant(blame: $0.blame, errors: $0.errors, buildLog: buildLog)
            }
        }
    }
}

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
        removals: Set<String> = [],
        afterFailedBuilds failedBuilds: Int
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
