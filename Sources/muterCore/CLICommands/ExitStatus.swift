import ArgumentParser

/// The statuses SwiftMutator's own commands exit with, besides 0, a usage error's 64, and 128 plus the signal for a run
/// a signal stopped (`Interruptions.exit(by:)`).
extension ExitCode {
    /// A command stopped on an error. It exits 255, through -1, as SwiftMutator always has. `report` exits with it too,
    /// for a run that stopped on an error.
    static let stoppedOnAnError = ExitCode(-1)

    /// SwiftMutator refused to resume the run in a results file, or to reuse its results, because this run might not
    /// reproduce them. Nothing was tested. The message names what would let it through. A new run without `--resume`
    /// or `--reuse` isn't refused for these reasons.
    static let resumeRefused = ExitCode(5)

    /// Another SwiftMutator run holds a lock this run needs: on the results file that `--resume` names, or on the
    /// project's copy. Nothing was copied or removed. The same command can go ahead once that run has ended.
    static let anotherRunHoldsTheLock = ExitCode(6)

    /// The status a run command exits with when its work failed with `error`, or nil when it exits 0: nothing to
    /// mutate and a shard with no mutant are not failures. A refused resume or reuse, and a run refused because
    /// another run holds a lock it needs, each have a status of their own, so a script can tell them from an error.
    static func exitStatus(afterRunFailedWith error: Error) -> ExitCode? {
        switch error {
        case is NothingToMutate, is EmptyShard:
            return nil
        case let refused as ResumeRefused:
            return refused.isInUse ? .anotherRunHoldsTheLock : .resumeRefused
        case MutatedProjectLockError.inUse:
            return .anotherRunHoldsTheLock
        default:
            return .stoppedOnAnError
        }
    }
}
