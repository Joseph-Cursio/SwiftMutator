import Foundation

/// Stops the run when xcodebuild's build for testing rewrote a mutated file and its mutants' switches went with it, as
/// a build step that generates code writes its files, such as a Run Script phase running SwiftGen or Sourcery, or
/// copying a template over a file. The build succeeds, the switches' code being in each file alone, and every such
/// mutant's tests would run the original code, pass, and record a survivor. It reads the files back as
/// `CheckMutantSwitches` does before the build, leaving out the mutants `CompileRecovery` took out of it. Not for
/// `swift test`, whose build plugins write only in its build folder, nor for a wrapper script, which builds with each
/// mutant's run.
struct CheckMutantSwitchesAfterTheBuild: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager

    func run(with state: AnyMutationTestState) throws -> [MutationTestState.Change] {
        guard state.muterConfiguration.buildSystem == .xcodebuild else { return [] }
        let leftOut = state.mutantsLeftOut
        var gaps: [CheckMutantSwitches.Gap] = []
        for mapping in state.mutationMapping where !mapping.isEmpty {
            let inTheBuild = mapping.mutationSchemata.filter { leftOut[$0.id] == nil }
            guard !inTheBuild.isEmpty else { continue }
            guard let data = fileManager.contents(atPath: mapping.filePath) else {
                gaps.append(.init(mapping: mapping, missing: inTheBuild, unreadable: true))
                continue
            }
            let missing = CheckMutantSwitches.mutantsWithoutASwitch(in: String(lossyUTF8: data), of: mapping)
                .filter { leftOut[$0.id] == nil }
            if !missing.isEmpty {
                gaps.append(.init(mapping: mapping, missing: missing, unreadable: false))
            }
        }
        guard gaps.isEmpty else {
            throw MuterError.literal(reason: Self.reason(
                for: gaps,
                inCopy: state.mutatedProjectDirectoryURL,
                usingTestPlan: state.runOptions.isUsingTestPlan
            ))
        }
        return []
    }

    /// Why the run stopped: each file the build rewrote, by its path in the project, which `inCopy` is a copy of, the
    /// mutants it lost, and what to do: an `exclude` entry for each file, or a way to skip the step. A test plan's copy
    /// is rewritten already, and `run-without-mutating` reads no `exclude`, so with `usingTestPlan`, the plan is made
    /// again.
    static func reason(for gaps: [CheckMutantSwitches.Gap], inCopy copy: URL, usingTestPlan: Bool) -> String {
        let missing = gaps.map(\.missing.count).reduce(0, +)
        let paths = gaps.map { RepoRelativePath.of($0.mapping.filePath, under: copy) }
        let files = zip(gaps, paths).map { gap, path in
            let what = gap.unreadable
                ? "could no longer be read"
                : "lost the switches of \(gap.missing.count) of its \(gap.mapping.mutationSchemata.count) mutants"
            let named = gap.missing.prefix(CheckMutantSwitches.namedPerFile).map { "    \($0.id)" }
            let more = gap.missing.count > CheckMutantSwitches.namedPerFile
                ? ["    and \(gap.missing.count - CheckMutantSwitches.namedPerFile) more"]
                : []
            return (["  \(path) \(what):"] + named + more).joined(separator: "\n")
        }
        let one = gaps.count == 1
        // A leading `/` anchors the entry at a folder: `Strings.swift` alone would leave out `LocalizedStrings.swift`.
        let entries = paths.map { "\"/\($0)\"" }.joined(separator: ", ")
        let again = usingTestPlan
            ? " Then make the test plan again with `swift-mutator mutate-without-running`: the build rewrote its copy."
            : ""
        return """
        SwiftMutator stopped before testing: the build rewrote \(one ? "a file" : "\(gaps.count) files") SwiftMutator \
        had mutated, and \(missing) \(missing == 1 ? "mutant has" : "mutants have") no switch left in its code. Their \
        tests would run the original code, and every one would survive.

        \(files.joined(separator: "\n"))

        A build step writes \(one ? "this file" : "these files"): look for a Run Script phase of the target that \
        compiles \(one ? "it" : "them"), such as one running SwiftGen or Sourcery, or copying a template. Leave \
        \(one ? "it" : "them") out with `exclude: [\(entries)]` in the configuration, or have the phase skip \
        SwiftMutator's builds: add a build setting of your own, such as `SWIFTMUTATOR=YES`, to `arguments`, and start \
        the script with `[ "$SWIFTMUTATOR" = YES ] && exit 0`.\(again)
        """
    }
}
