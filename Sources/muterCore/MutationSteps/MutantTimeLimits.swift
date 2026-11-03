import Foundation

/// How long a mutant's test run may take when `mutationTestTimeout` doesn't say.
extension PerformMutationTesting {
    /// With no `mutationTestTimeout`, a SwiftPM mutant's test run may take this many times one timed run of its test
    /// command with no mutant on, and once more for each worker beyond the first, but never less than
    /// `minimumTestRunTimeout` seconds. Every worker's tests compete for the same cores. A mutant that makes the code
    /// loop forever then costs a few test runs, not the minutes a build takes.
    static let testRunTimeoutMultiplier: TimeInterval = 5
    static let minimumTestRunTimeout: TimeInterval = 20
    /// With no `mutationTestTimeout` and no timed test run, as for another build system, a mutant's test run may take
    /// this many times the baseline run, build included, but never less than `minimumDefaultTimeout` seconds.
    static let defaultTimeoutMultiplier: TimeInterval = 3
    static let minimumDefaultTimeout: TimeInterval = 10

    /// The default time limit for a mutant's test run on `workers` workers, from one timed run of its test command.
    static func defaultTimeout(testRunSeconds: TimeInterval, workers: Int) -> TimeInterval {
        let multiplier = testRunTimeoutMultiplier + Double(max(workers, 1) - 1)
        return max(testRunSeconds * multiplier, minimumTestRunTimeout)
    }
}
