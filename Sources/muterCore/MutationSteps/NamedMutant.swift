import Foundation

/// The mutant `--mutant` names, for a file whose mutants lack it. `--mutant` discovers every operator, but a mutant
/// nested in an opaque body is pruned when an operator it doesn't use mutates the body's own statements. So a run under
/// `operators` or `skipOperators` can test and report a mutant that every operator's discovery prunes. Only the keys'
/// operators keep it then, and as it alone gets tested, it conflicts with nothing.
struct NamedMutant: Sendable {
    let reference: MutantReference
    /// What the configuration's keys leave; nil when they say nothing, or leave no operators.
    let configuredOperators: MutationOperatorList?

    /// nil unless `--mutant` is given.
    init?(_ state: AnyMutationTestState) {
        guard let mutantReference = state.runOptions.mutant else { return nil }
        self.reference = mutantReference.relative(
            toFirstOf: [state.projectDirectoryURL, state.mutatedProjectDirectoryURL]
        )
        configuredOperators = try? state.runOptions.operatorsFromTheKeys(of: state.muterConfiguration)
    }

    func isHeld(by mappings: [SchemataMutationMapping], under root: URL) -> Bool {
        MutantKey.keys(for: mappings.flatMap(\.mutationSchemata), under: root).contains(where: reference.matches)
    }
}
