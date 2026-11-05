import ArgumentParser
import Foundation

/// The mutants a run, or a test plan, holds: by file and by operator.
struct MutantSelectionArguments: ParsableArguments {
    @Option(help: "Only mutate a given list of source code files.")
    var filesToMutate: [String] = []

    @Option(
        parsing: .upToNextOption,
        help: "The list of mutant operators to be used: \(MutationOperator.Id.description)",
        transform: namedOperator
    )
    /// The operators named, in their order; none when `--operators` wasn't given.
    var operators: [MutationOperator.Id] = []

    @Option(
        parsing: .upToNextOption,
        help: "The mutant operators to leave out, in place of skipOperators.",
        transform: namedOperator
    )
    /// The operators to leave out; none when `--skip-operators` wasn't given.
    var skipOperators: [MutationOperator.Id] = []

    /// Whether `--operators` was given, which wins over the configuration's `operators` and `skipOperators`.
    var operatorsAreNamed: Bool {
        !operators.isEmpty
    }

    /// `--skip-operators`'s operators, or nil when it wasn't given, which leaves it to `skipOperators`.
    var skippedOperators: [MutationOperator.Id]? {
        skipOperators.isEmpty ? nil : skipOperators
    }

    /// The operators to mutate with: every one when none was named.
    var mutationOperatorsList: MutationOperatorList {
        !operators.isEmpty ? operators.withoutRepeats : .allOperators
    }
}

private func namedOperator(_ name: String) throws -> MutationOperator.Id {
    guard let found = MutationOperator.Id(rawValue: name) else {
        throw MuterError.literal(reason: MutationOperator.Id.description)
    }

    return found
}
