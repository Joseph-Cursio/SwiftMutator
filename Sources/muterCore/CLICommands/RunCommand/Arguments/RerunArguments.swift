import ArgumentParser

/// When a test is suspect, and which kills and survivors a run tests again, for the commands that test mutants: each
/// in place of its configuration key for this run.
struct RerunArguments: ParsableArguments, KeyFlagArguments {
    @Option(
        name: .customLong("suspect-test-file-percent"),
        help: ArgumentHelp(
            "The share of the files with a killed mutant, from 1 to 100, a test must have failed for mutants in to be "
                + "suspect, in place of suspectTestFilePercent.",
            valueName: "percent"
        )
    )
    var suspectTestFilePercent: Int?

    @Option(
        name: .customLong("suspect-test-minimum-files"),
        help: ArgumentHelp(
            "How many files with a killed mutant there must be, at least 1, before a test can be suspect, in place of "
                + "suspectTestMinimumFiles.",
            valueName: "count"
        )
    )
    var suspectTestMinimumFiles: Int?

    @Option(
        name: .customLong("control-run-every"),
        help: ArgumentHelp(
            "How many mutants to test for each control run, a run with no mutant on, 0 for none, in place of "
                + "controlRunEvery.",
            valueName: "count"
        )
    )
    var controlRunEvery: Int?

    @Option(
        name: .customLong("suspect-kill-reruns"),
        help: ArgumentHelp(
            "How many kills to test again alone because only suspect tests failed for them, 0 for none, in place of "
                + "suspectKillReruns.",
            valueName: "count"
        )
    )
    var suspectKillReruns: Int?

    @Option(
        name: .customLong("property-test-filter"),
        help: ArgumentHelp(
            "A test filter that selects the property tests alone, as swift test --filter or xcodebuild's "
                + "-only-testing: takes it, to test kills again with. Repeatable. In place of propertyTestFilter.",
            valueName: "filter"
        )
    )
    var propertyTestFilter: [String] = []

    @Option(
        name: .customLong("property-survivor-reruns"),
        help: ArgumentHelp(
            "How many times to test each survivor again with only the property tests, 0 for none, in place of "
                + "propertySurvivorReruns.",
            valueName: "count"
        )
    )
    var propertySurvivorReruns: Int?

    @Option(
        name: .customLong("property-survivor-rerun-limit"),
        help: ArgumentHelp(
            "How many survivors to test again with the property tests, 0 for none, in place of "
                + "propertySurvivorRerunLimit.",
            valueName: "count"
        )
    )
    var propertySurvivorRerunLimit: Int?

    /// As their keys are decoded. Whether the filter has the property tests it needs, and the survivor reruns a
    /// filter, is checked once the run's flags are in, as a flag or a key may give each
    /// (`MuterConfiguration.propertyRerunsUnsupportedReason`).
    func validate() throws {
        try Self.refuse(
            suspectTestFilePercent, of: "--suspect-test-file-percent", outside: MuterConfiguration.filePercents
        )
        try Self.refuse(
            suspectTestMinimumFiles, of: "--suspect-test-minimum-files", outside: MuterConfiguration.minimumFiles
        )
        let counts: [(flag: String, value: Int?)] = [
            ("--control-run-every", controlRunEvery),
            ("--suspect-kill-reruns", suspectKillReruns),
            ("--property-survivor-reruns", propertySurvivorReruns),
            ("--property-survivor-rerun-limit", propertySurvivorRerunLimit),
        ]
        for (flag, value) in counts {
            try Self.refuse(value, of: flag, outside: MuterConfiguration.counts)
        }
        if let problem = PropertyTestPattern.problem(with: propertyTestFilter) {
            throw ValidationError("--property-test-filter: \(problem).")
        }
    }

    func set(in flags: inout KeyFlags) {
        flags.suspectTestFilePercent = suspectTestFilePercent
        flags.suspectTestMinimumFiles = suspectTestMinimumFiles
        flags.controlRunEvery = controlRunEvery
        flags.suspectKillReruns = suspectKillReruns
        flags.propertyTestFilter = propertyTestFilter.isEmpty ? nil : propertyTestFilter
        flags.propertySurvivorReruns = propertySurvivorReruns
        flags.propertySurvivorRerunLimit = propertySurvivorRerunLimit
    }
}
