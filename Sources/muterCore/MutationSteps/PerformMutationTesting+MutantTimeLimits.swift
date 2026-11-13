import Foundation

/// How long a mutant's test run may take when `mutationTestTimeout` doesn't say.
extension PerformMutationTesting {
    /// With no `mutationTestTimeout`, a SwiftPM or xcodebuild mutant's test run may take this many times one timed run
    /// of its test command with no mutant on, and once more for each worker beyond the first, but never less than
    /// `minimumTestRunTimeout` seconds. Every worker's tests compete for the same cores. A mutant that makes the code
    /// loop forever then costs a few test runs, not the minutes a build takes.
    static let testRunTimeoutMultiplier: TimeInterval = 5
    static let minimumTestRunTimeout: TimeInterval = 20
    /// With no `mutationTestTimeout` and no timed test run that passed, a mutant's test run may take
    /// this many times the baseline run, build included, but never less than `minimumDefaultTimeout` seconds
    /// (`defaultTimeout(testRunSeconds:baselineSeconds:on:)`).
    static let defaultTimeoutMultiplier: TimeInterval = 3
    static let minimumDefaultTimeout: TimeInterval = 10
    /// With `buildTimeout` set, a run of the test command with no mutant on that follows the baseline and skips the
    /// build, the direct or the timed test run, may take this many times the baseline run, build included, or the
    /// slowest xcodebuild worker's run with no mutant on if that took longer, as the timed run, on the first worker,
    /// runs its tests one at a time as they did, but never less than `minimumFollowingRunLimit`
    /// seconds, nor more than `buildTimeout` (`followingRunLimit`). It should take less than the baseline.
    static let followingRunMultiplier: TimeInterval = 5
    static let minimumFollowingRunLimit: TimeInterval = 60

    /// The time limit of a run with no mutant on that follows the baseline and skips the build, or nil without a
    /// `buildTimeout`: such a run is limited only in a run that limits its builds.
    static func followingRunLimit(
        buildTimeout: TimeInterval?,
        baselineSeconds: TimeInterval,
        checkRunSeconds: TimeInterval? = nil
    ) -> TimeInterval? {
        guard let buildTimeout else { return nil }
        let longest = max(baselineSeconds, checkRunSeconds ?? 0)
        return min(buildTimeout, max(longest * followingRunMultiplier, minimumFollowingRunLimit))
    }

    /// The default time limit for a mutant's test run on `workers` workers, from one timed run of its test command.
    static func defaultTimeout(testRunSeconds: TimeInterval, workers: Int) -> TimeInterval {
        let multiplier = testRunTimeoutMultiplier + Double(max(workers, 1) - 1)
        return max(testRunSeconds * multiplier, minimumTestRunTimeout)
    }

    /// The default time limit for a mutant's test run on `pool`'s workers: from `testRunSeconds`, one timed run of its
    /// test command, if there was one, else from the baseline's `baselineSeconds`, build included, or from a lone
    /// xcodebuild worker's run with no mutant on, on its simulator, when that took longer
    /// (`SimulatorWorkerSetup.Workers.checkRunSeconds`). The baseline may have spread its tests over parallel
    /// testing's clones, but that worker tests one test at a time, as its run with no mutant on did.
    static func defaultTimeout(
        testRunSeconds: TimeInterval?,
        baselineSeconds: TimeInterval,
        on pool: SimulatorWorkerSetup.Workers
    ) -> TimeInterval {
        if let testRunSeconds {
            return defaultTimeout(testRunSeconds: testRunSeconds, workers: pool.count)
        }
        let checkRunSeconds = pool.count == 1 ? pool.checkRunSeconds ?? 0 : 0
        return max(max(baselineSeconds, checkRunSeconds) * defaultTimeoutMultiplier, minimumDefaultTimeout)
    }
}
