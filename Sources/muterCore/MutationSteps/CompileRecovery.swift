import Foundation

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
            let changeNote = change.isEmpty ? "" : " (\(change))"
            let others = switch mutant.blame {
            case .itself: ""
            case .itsSwitch: " [with the others of its code]"
            case .itsEnclosingCode: " [with the others around it]"
            case .itsFile: " [with the rest of its file]"
            }
            return "\(key)\(changeNote): \(mutant.errors.first?.message ?? "")\(others)"
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
    /// How many mutants the last failed build has switched in a closure called on the spot, as a result builder there
    /// can't take an `if` (`SchemataMutationMapping.switchInAClosureCalledOnTheSpot(theListOf:)`). They stay in the
    /// build.
    private(set) var switchedInAClosure = 0
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
    /// `testsMayHaveRun` when the command goes on to test what it builds, as a baseline does. A switch that a result
    /// builder can't take goes in a closure called on the spot instead, and its mutants stay (`switchedInAClosure`).
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
        var files: [Int: SchemataMutationMapping] = [:]
        var switched = 0
        for (index, mapping) in mappings.enumerated() where !mapping.isEmpty {
            guard let errors = errorsByFile[mapping.filePath.canonicalPath],
                  let prepared = preparedSources[mapping.filePath]
            else { continue }
            let switches = await Self.switchesABuilderCantTake(errors, inCodeOf: mapping, prepared: prepared)
            var next = mapping
            for id in Set(switches.values) {
                switched += next.switchInAClosureCalledOnTheSpot(theListOf: id) ?? 0
            }
            let others = errors.filter { switches[$0] == nil }
            guard let inFile = others.isEmpty ? [:] : await Self.mutantsToBlame(
                for: others, inCodeOf: mapping, prepared: prepared, afterFailedBuilds: failedBuilds, buildLog: buildLog
            ) else { return nil }
            blamed.merge(inFile) { first, _ in first }
            if !inFile.isEmpty || !switches.isEmpty { files[index] = next }
        }
        guard !blamed.isEmpty || switched > 0 else { return nil }

        var count = 0
        for (index, var mapping) in files.sorted(by: { $0.key < $1.key }) {
            let before = mapping.mutationSchemata.count
            mapping.keepOnly { blamed[$0.id] == nil }
            count += before - mapping.mutationSchemata.count
            mappings[index] = mapping
            try await writeAgain(mapping)
        }
        leftOut.merge(blamed) { first, _ in first }
        switchedInAClosure = switched
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
            let plainLine = FailedTestLine.withoutColours(line)
            if plainLine.hasPrefix("Build complete!") {
                built = true
            } else if plainLine.hasPrefix("Building for") {
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

    /// Of `errors`, in `mapping`'s file as rewritten from `prepared`, those that say a result builder can't take a
    /// switch that can go in a closure called on the spot instead, each with the ID of a mutant of that switch.
    static func switchesABuilderCantTake(
        _ errors: [CompilerError],
        inCodeOf mapping: SchemataMutationMapping,
        prepared: String
    ) async -> [CompilerError: String] {
        guard errors.contains(where: MutantLocator.saysABuilderCantTakeASwitch) else { return [:] }
        let code = await ApplySchemata.rewritten(prepared, with: mapping)
        let filePath = mapping.filePath
        return await ApplySchemata.onAStackOfItsOwn {
            let locator = MutantLocator(rewritten: code, filePath: filePath)
            var switches: [CompilerError: String] = [:]
            for error in errors {
                switches[error] = locator.switchABuilderCantTake(error)
            }
            return switches
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
                    error, everyMutant: everyMutant, afterFailedBuilds: failedBuilds, removals: removals
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
