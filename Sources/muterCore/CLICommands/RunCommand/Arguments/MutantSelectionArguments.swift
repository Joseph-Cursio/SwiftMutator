import ArgumentParser
import Foundation

/// The mutants a run, or a test plan, holds: by file and by operator.
struct MutantSelectionArguments: ParsableArguments {
    @Option(help: "Only mutate a given list of source code files.")
    var filesToMutate: [String] = []

    @Option(
        parsing: .upToNextOption,
        help: "The list of mutant operators to be used: \(MutationOperator.Id.description)",
        transform: {
            guard let `operator` = MutationOperator.Id(rawValue: $0) else {
                throw MuterError.literal(reason: MutationOperator.Id.description)
            }

            return `operator`
        }
    )
    /// The operators named, in their order; none when `--operators` wasn't given.
    var operators: [MutationOperator.Id] = []

    /// The operators to mutate with: every one when none was named.
    var mutationOperatorsList: MutationOperatorList {
        !operators.isEmpty ? operators : .allOperators
    }
}
