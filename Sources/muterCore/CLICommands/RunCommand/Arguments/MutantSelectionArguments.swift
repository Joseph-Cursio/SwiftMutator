import ArgumentParser

/// The mutants a run, or a test plan, holds: by file, by coverage, by call and by operator.
struct MutantSelectionArguments: ParsableArguments, KeyFlagArguments {
    @Option(
        help: ArgumentHelp(
            "Only mutate these Swift files, folders or globs, in the project; comma-separated or repeated. The "
                + "excludes and the coverage filter still apply.",
            valueName: "path"
        )
    )
    var filesToMutate: [String] = []

    @Option(
        help: ArgumentHelp(
            "Leave out the files this path fragment or glob matches, as an `exclude` entry does, for this run; "
                + "`!` in front keeps what it matches. Repeatable.",
            valueName: "pattern"
        )
    )
    var exclude: [String] = []

    @Option(
        name: .customLong("exclude-calls"),
        help: ArgumentHelp(
            "Never remove the calls of the function with this name with RemoveSideEffects, as an `excludeCalls` entry "
                + "does, for this run. Repeatable.",
            valueName: "name"
        )
    )
    var excludeCalls: [String] = []

    @Option(
        name: .customLong("coverage-threshold"),
        help: ArgumentHelp(
            "Leave out the files whose share of lines the tests ran is at or below this percentage, from 0 to 100, in "
                + "place of coverageThreshold.",
            valueName: "percent"
        )
    )
    var coverageThreshold: Double?

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

    /// As `coverageThreshold` is checked once the run's flags are in (`LoadConfiguration.valueOutOfRange(in:)`).
    func validate() throws {
        if let coverageThreshold, !MuterConfiguration.coveragePercents.contains(coverageThreshold) {
            throw ValidationError(
                "--coverage-threshold must be a percentage from 0 to 100, not \(ScoreGate.shown(coverageThreshold))."
            )
        }
    }

    func set(in flags: inout KeyFlags) {
        flags.excludeCalls = excludeCalls
        flags.coverageThreshold = coverageThreshold
    }
}

private func namedOperator(_ name: String) throws -> MutationOperator.Id {
    guard let found = MutationOperator.Id(rawValue: name) else {
        throw MuterError.literal(reason: MutationOperator.Id.description)
    }

    return found
}
