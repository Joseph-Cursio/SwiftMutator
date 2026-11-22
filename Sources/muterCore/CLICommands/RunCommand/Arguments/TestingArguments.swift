import ArgumentParser

/// How mutants are tested, for the commands that test them: each in place of its configuration key for this run.
struct TestingArguments: ParsableArguments, KeyFlagArguments {
    @Option(
        name: .customLong("workers"),
        help: ArgumentHelp(
            "How many mutants to test at once, in place of mutationTestWorkers (SwiftPM; xcodebuild on a "
                + "simulator, which gets one simulator per worker, or on a Mac whose tests no app hosts).",
            valueName: "count"
        )
    )
    var workers: Int?

    @Option(
        name: .customLong("timeout"),
        help: ArgumentHelp(
            "Seconds before a mutant's test run is stopped, in place of mutationTestTimeout. At most a day, 86400.",
            valueName: "seconds"
        )
    )
    var timeout: Double?

    // Each pair is nil when neither of its flags is given, which leaves the key.
    // swiftlint:disable discouraged_optional_boolean

    @Flag(
        name: .customLong("stop-at-first-failure"),
        inversion: .prefixedNo,
        help: ArgumentHelp(
            "Stop a mutant's test run at its first failed test, or don't, in place of stopAtFirstFailure. SwiftPM, "
                + "and xcodebuild on a simulator or on a Mac whose tests no app hosts."
        )
    )
    var stopAtFirstFailure: Bool?

    @Flag(
        name: .customLong("workers-share-build"),
        inversion: .prefixedNo,
        help: ArgumentHelp(
            "Let SwiftPM workers test from one build when they can, or give each a clone, in place of "
                + "workersShareBuild."
        )
    )
    var workersShareBuild: Bool?

    @Flag(
        name: .customLong("one-worker-simulator"),
        inversion: .prefixedNo,
        help: ArgumentHelp(
            "Test one xcodebuild worker on a simulator SwiftMutator makes whenever the destination is a simulator, "
                + "or never, in place of oneWorkerSimulator."
        )
    )
    var oneWorkerSimulator: Bool?

    @Flag(
        name: .customLong("keep-all-logs"),
        inversion: .prefixedNo,
        help: ArgumentHelp(
            "Keep the log of every mutant's test run, or only those its results line can't stand in for, in place "
                + "of keepAllLogs."
        )
    )
    var keepAllLogs: Bool?

    // swiftlint:enable discouraged_optional_boolean

    /// A day: a mutant's test run that may take longer is a mistake, not a limit.
    static let longestTimeout: Double = 86_400

    func validate() throws {
        if let workers, workers < 1 {
            throw ValidationError("--workers must be at least 1.")
        }
        if let timeout, !(timeout > 0 && timeout <= Self.longestTimeout) {
            throw ValidationError("--timeout must be a number of seconds above 0, and at most a day (86400).")
        }
    }

    func set(in flags: inout KeyFlags) {
        flags.stopAtFirstFailure = .given(stopAtFirstFailure)
        flags.workersShareBuild = .given(workersShareBuild)
        flags.oneWorkerSimulator = .given(oneWorkerSimulator)
        flags.keepAllLogs = .given(keepAllLogs)
    }
}
