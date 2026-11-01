import ArgumentParser
import Foundation

/// How mutants are tested, for the commands that test them: each in place of its configuration key for this run.
struct TestingArguments: ParsableArguments {
    @Option(
        name: .customLong("workers"),
        help: ArgumentHelp(
            "How many mutants to test at once, in place of mutationTestWorkers. Only SwiftPM projects test more than "
                + "one.",
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
}
