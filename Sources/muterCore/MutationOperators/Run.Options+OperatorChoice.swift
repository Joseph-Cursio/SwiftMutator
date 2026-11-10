extension Run.Options {
    /// The operators the run mutates with, when the configuration or `--skip-operators` has a say; nil leaves what the
    /// command line gave. `--operators` wins over both of the configuration's keys, and `--skip-operators` is taken in
    /// place of `skipOperators`.
    ///
    /// A test plan's own operators stand for its run, and `--mutant` discovers every operator to find its mutant, so
    /// neither looks at the keys. Throws when no operator is left, which leaves the run nothing to mutate.
    func chosenOperators(given configuration: MuterConfiguration) throws -> MutationOperatorList? {
        guard !isUsingTestPlan, mutant == nil else { return nil }
        return try operatorsFromTheKeys(of: configuration)
    }

    /// What `chosenOperators(given:)` says, whether or not this is a test plan's run or `--mutant`'s.
    func operatorsFromTheKeys(of configuration: MuterConfiguration) throws -> MutationOperatorList? {
        let listed = operatorsAreNamed ? nil : configuration.operators
        let skipped = skipOperators ?? (operatorsAreNamed ? nil : configuration.skipOperators)
        guard listed != nil || skipped != nil else { return nil }

        let chosen = (listed ?? mutationOperatorsList).withoutRepeats.filter { skipped?.contains($0) != true }
        guard !chosen.isEmpty else {
            throw MuterError.literal(
                reason: "Every operator is left out, so there is nothing to mutate. "
                    + "Check --operators, --skip-operators and the operators and skipOperators keys."
            )
        }
        return chosen
    }
}
