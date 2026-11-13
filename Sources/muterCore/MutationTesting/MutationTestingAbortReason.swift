public enum MutationTestingAbortReason: Equatable, Sendable {
    /// `mutatedFilePaths` are the files SwiftMutator rewrote to insert mutants. A compile error in one of
    /// them points at SwiftMutator's own rewriting rather than at the user's configuration, so the message
    /// needs them to tell the two apart.
    case baselineTestFailed(log: String, mutatedFilePaths: [String])
    /// The mutated project's baseline passed, but a parallel worker's clone of it, at `directory`,
    /// failed the same build-and-test run.
    case workerBaselineTestFailed(worker: Int, directory: String, log: String)
    /// xcodebuild's build for testing failed, as `description` says, and no mutant that fails it was left to take out
    /// (`CompileRecovery`). `log` is where its log is kept, if it is.
    case buildForTestingFailed(description: String, log: String?)
    /// `step`, ahead of the first mutant, ran for `buildTimeout`'s `seconds` and was stopped. `output` is what it
    /// printed, and `log` where that is kept, if it is.
    case buildTimeoutReached(step: BuildStep, seconds: Double, output: String, log: String?)
    case tooManyBuildErrors
    /// The mutant `id`'s run couldn't be told to switch it on: under xcodebuild, its `muter.xctestrun` couldn't be
    /// written, as `description` says. The file left by the run before would have switched that run's mutant on.
    case mutantNotSwitchedOn(id: String, description: String)
    /// Control run `number`'s xcodebuild worker's `.xctestrun` couldn't be written with no mutant on, as `description`
    /// says. The file left by the run before would have switched that run's mutant on.
    case controlRunNotSwitchedOff(number: Int, description: String)
    /// The simulator that worker `worker`'s xcodebuild run tested on is gone, as `line` of the run's log says: every
    /// run on it would fail without testing its mutant. `log` is where that run's log is kept, if it is.
    case simulatorUnavailable(worker: Int, line: String, log: String?)
    /// None of the first `runs` mutants' `swift test` runs showed it read the mutants' switches, though coverage says
    /// the tests reach those mutants: no mutant was switched on, or no run can say so, and every verdict would mean
    /// nothing.
    case noMutantCodeShownRunning(runs: Int)
    case unknownError(description: String)

    /// A step ahead of the first mutant that builds the project, which `buildTimeout` limits and a failure of stops the
    /// run.
    public enum BuildStep: Equatable, Sendable {
        /// One of xcodebuild's builds for testing (`BuildForTesting`).
        case buildForTesting
        /// One of the baseline's runs in the mutated project, which builds it and runs its tests with no mutant on.
        case baseline
        /// The baseline in parallel worker `worker`'s clone of the mutated project, at `directory`.
        case workerBaseline(worker: Int, directory: String)
    }
}
