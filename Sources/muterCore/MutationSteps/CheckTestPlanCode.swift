import Foundation

/// Refuses a `swift test` plan whose mutated code was made by a SwiftMutator from before the active-mutant file. It
/// reads the mutated project's files, so it comes after `LockMutatedProject`: until then another run of the project
/// could be removing them, or copying and rewriting them.
struct CheckTestPlanCode: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        try refuseCodeThatCannotReadTheActiveMutantFile(
            in: state.mutationMapping,
            of: state.mutatedProjectDirectoryURL.path,
            testedWith: state.muterConfiguration
        )
        return []
    }

    /// Why a `swift test` plan made by an older SwiftMutator is refused, and how to make it again.
    static func codePredatesTheActiveMutantFile(_ mutatedProjectPath: String) -> String {
        """
        The test plan's mutated project, \(mutatedProjectPath), was made by an older SwiftMutator. Its code never \
        reads the file this one names each `swift test` run's mutant in, so every mutant would survive. Make the \
        test plan again with `swift-mutator mutate-without-running`.
        """
    }

    /// A `swift test` run names its mutant in the file `activeMutantFileKey` names, which code made by an older
    /// SwiftMutator never reads. Every file in a plan was made by one SwiftMutator, so the first file that settles
    /// it decides: one naming the key reads the file; one holding a mutant's switch without it predates it. Files
    /// with neither, as a file that couldn't be rewritten, settle nothing. Other test commands still switch each
    /// mutant on through its own variable, which older code reads too.
    private func refuseCodeThatCannotReadTheActiveMutantFile(
        in mappings: [SchemataMutationMapping],
        of mutatedProjectPath: String,
        testedWith configuration: MuterConfiguration
    ) throws {
        guard configuration.buildSystem == .swift else { return }
        for mapping in mappings where !mapping.isEmpty {
            guard let data = fileManager.contents(atPath: mapping.filePath) else { continue }
            let code = String(decoding: data, as: UTF8.self)
            if code.contains(activeMutantFileKey) { return }
            if mapping.mutationSchemata.contains(where: { code.contains("\"\($0.id)\"") }) {
                throw MuterError.literal(reason: Self.codePredatesTheActiveMutantFile(mutatedProjectPath))
            }
        }
    }
}
