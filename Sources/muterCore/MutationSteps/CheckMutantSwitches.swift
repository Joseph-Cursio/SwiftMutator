import Foundation

/// Stops the run when a mutant's switch isn't in the mutated project's code. Such a mutant's tests would run the
/// original code, pass, and record a survivor: twice before, a rewrite that silently inserted no switch turned every
/// mutant into one (see `CodeBlockKey` and `MuterRewriter.visit(_:)` on nested blocks). It reads the files back from
/// disk after `ApplySchemata`, and before a test plan's mutants are tested, as its code may have been edited by hand
/// since the plan was made, so it comes after `LockMutatedProject`.
///
/// A switch is found by its mutant's ID as a quoted string, which is all a switch made by any SwiftMutator has in
/// common. The environment cache a switch reads isn't checked: a switch without it fails the build every mutant
/// shares, which stops the run anyway, and `CheckTestPlanCode` refuses `swift test` code from before the
/// active-mutant file. This proves a switch is there, not that a run switched it on.
struct CheckMutantSwitches: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager

    /// How many of a file's missing mutants the error names, so that a rewrite that missed thousands stays readable.
    static let namedPerFile = 10

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        var gaps: [Gap] = []
        for mapping in state.mutationMapping where !mapping.isEmpty {
            guard let data = fileManager.contents(atPath: mapping.filePath) else {
                gaps.append(Gap(mapping: mapping, missing: mapping.mutationSchemata, unreadable: true))
                continue
            }
            let missing = Self.mutantsWithoutASwitch(in: String(decoding: data, as: UTF8.self), of: mapping)
            if !missing.isEmpty {
                gaps.append(Gap(mapping: mapping, missing: missing, unreadable: false))
            }
        }
        guard gaps.isEmpty else {
            throw MuterError.literal(reason: Self.reason(for: gaps, usingTestPlan: state.runOptions.isUsingTestPlan))
        }
        return []
    }

    /// A file whose code lacks some of its mutants' switches, or can't be read.
    struct Gap {
        let mapping: SchemataMutationMapping
        let missing: MutationSchemata
        let unreadable: Bool
    }

    /// `mapping`'s mutants whose IDs `code` doesn't hold as a quoted string, in job order. The code is split at its
    /// quotes once, as a file can hold thousands of mutants: every run of text between two quotes is a candidate,
    /// whether it is a string's contents or the code between two strings, so an escaped quote can't hide one.
    static func mutantsWithoutASwitch(in code: String, of mapping: SchemataMutationMapping) -> MutationSchemata {
        let betweenQuotes = Set(code.components(separatedBy: "\"").dropFirst().dropLast())
        return mapping.mutationSchemata.filter { !betweenQuotes.contains($0.id) }
    }

    /// Why the run stopped: each file and the mutants it lacks, and what to do.
    static func reason(for gaps: [Gap], usingTestPlan: Bool) -> String {
        let missing = gaps.map(\.missing.count).reduce(0, +)
        let files = gaps.map { gap in
            let total = gap.mapping.mutationSchemata.count
            let what = gap.unreadable
                ? "could not be read, so none of its \(total) mutants' switches could be found"
                : "lacks the switches of \(gap.missing.count) of its \(total) mutants"
            let named = gap.missing.prefix(namedPerFile).map { "    \($0.id)" }
            let more = gap.missing.count > namedPerFile ? ["    and \(gap.missing.count - namedPerFile) more"] : []
            return (["  \(gap.mapping.filePath) \(what):"] + named + more).joined(separator: "\n")
        }
        let cause = usingTestPlan
            ? """
            The test plan's mutated project no longer holds the code the plan was made with: it may have been edited, \
            or made again by another SwiftMutator. Make the test plan again with \
            `swift-mutator mutate-without-running`.
            """
            : """
            This is a bug in SwiftMutator's rewriting: please report it with the files and mutants named here.
            """
        return """
        SwiftMutator stopped before testing: \(missing) \(missing == 1 ? "mutant has" : "mutants have") no switch in \
        the mutated project's code. Their tests would run the original code, and every one would survive.

        \(files.joined(separator: "\n"))

        \(cause)
        """
    }
}
