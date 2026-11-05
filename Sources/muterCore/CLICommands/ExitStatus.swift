import ArgumentParser

/// The statuses SwiftMutator's own commands exit with, besides 0, a usage error's 64, `report`'s 1 for a results file
/// it can't read, and 128 plus the signal for a run a signal stopped (`Interruptions.exit(by:)`): 2 for a score below
/// `--fail-under`, or every mutant a build error, 3 for a failed baseline, 4 for mutation testing an error stopped
/// partway, 5, 6 and 7 for a refused resume, lock or test plan, and 255 for any other error.
extension ExitCode {
    /// A command stopped on any other error, such as a missing configuration, a configuration that doesn't parse, a
    /// `--mutant` that names no mutant, a `--since` that git can't answer, or a project that doesn't build for testing.
    /// It exits 255, through -1, as SwiftMutator always has.
    static let stoppedOnAnError = ExitCode(-1)

    /// The headline score is below the threshold `--fail-under` or `failUnder` sets, or every mutant was a build error
    /// (`ScoreGate`). Every report, the
    /// results file and `summary.json` were written first, as for any finished run.
    static let scoreBelowThreshold = ExitCode(2)

    /// The baseline run, with no mutant on, failed in the project's copy or in a parallel worker's clone of it
    /// (`MutationTestingAbortReason.baselineTestFailed` and `.workerBaselineTestFailed`), so no mutant was tested. A
    /// failure no mutant that doesn't compile explains (`CompileRecovery`).
    /// `report` never exits with it: a run whose baseline failed has no results file, or a resumed one's keeps the
    /// earlier session's end, so a shard whose baseline failed is a shard missing from the merge, which exits 4.
    static let baselineFailed = ExitCode(3)

    /// An error stopped mutation testing partway, such as five build errors in a row (every other
    /// `MutationTestingAbortReason`); the results so far are kept. `report` exits with it for a results file whose run
    /// stopped so, and for shards whose merged report lacks results (`MergedShards.lacksResults`): one stopped so, was
    /// interrupted, or isn't given.
    static let abortedMidRun = ExitCode(4)

    /// SwiftMutator refused to resume the run in a results file, or to reuse its results, because this run might not
    /// reproduce them. Nothing was tested. The message names what would let it through. A new run without `--resume`
    /// or `--reuse` isn't refused for these reasons.
    static let resumeRefused = ExitCode(5)

    /// Another SwiftMutator run holds a lock this run needs: on the results file that `--resume` names, or on the
    /// project's copy. Nothing was copied or removed. The same command can go ahead once that run has ended.
    static let anotherRunHoldsTheLock = ExitCode(6)

    /// SwiftMutator refused to test a test plan, because it might not describe the project or can't be tested as it
    /// is: one in a newer format, run in another folder than its project's that has a configuration, whose mutated
    /// files changed in the project since it was made, or whose copy of the project isn't there. Nothing was tested.
    /// The message names what would let it through. A folder without a configuration stops on that first, as an
    /// error.
    static let testPlanRefused = ExitCode(7)

    /// The status a run command exits with when its work failed with `error`, or nil when it exits 0: nothing to
    /// mutate and a shard with no mutant are not failures. A refused resume or reuse, a run refused because another
    /// run holds a lock it needs, a refused test plan, a failed baseline and an abort each have a status of their own,
    /// so a script can tell them from any other error.
    static func exitStatus(afterRunFailedWith error: Error) -> ExitCode? {
        switch error {
        case is NothingToMutate, is EmptyShard:
            return nil
        case let refused as ResumeRefused:
            return refused.isInUse ? .anotherRunHoldsTheLock : .resumeRefused
        case MutatedProjectLockError.inUse:
            return .anotherRunHoldsTheLock
        case is TestPlanRefused:
            return .testPlanRefused
        case let MuterError.mutationTestingAborted(reason):
            return reason.exitStatus
        default:
            return .stoppedOnAnError
        }
    }
}

extension MutationTestingAbortReason {
    /// Which reason this is, without its details. Its name is the code a results file's end line gives
    /// (`ResultsEnd.detail(for:)`), from which `report` finds the status the run exited with (`ResultsEnd.exitStatus`),
    /// so the two can't disagree.
    enum Kind: String, CaseIterable, Sendable {
        case baselineTestFailed
        case workerBaselineTestFailed
        case tooManyBuildErrors
        case mutantNotSwitchedOn
        case controlRunNotSwitchedOff
        case simulatorUnavailable
        case unknownError

        /// The status a run that stopped for a reason of this kind exits with: `baselineFailed` when no mutant was
        /// tested because a baseline failed, and `abortedMidRun` for the rest. No `default`, so a new kind needs a
        /// status chosen.
        var exitStatus: ExitCode {
            switch self {
            case .baselineTestFailed, .workerBaselineTestFailed:
                return .baselineFailed
            case .tooManyBuildErrors, .mutantNotSwitchedOn, .controlRunNotSwitchedOff, .simulatorUnavailable,
                 .unknownError:
                return .abortedMidRun
            }
        }
    }

    /// Which reason this is. No `default`, so a new reason needs a kind, and with it a status and an end-line code.
    var kind: Kind {
        switch self {
        case .baselineTestFailed: .baselineTestFailed
        case .workerBaselineTestFailed: .workerBaselineTestFailed
        case .tooManyBuildErrors: .tooManyBuildErrors
        case .mutantNotSwitchedOn: .mutantNotSwitchedOn
        case .controlRunNotSwitchedOff: .controlRunNotSwitchedOff
        case .simulatorUnavailable: .simulatorUnavailable
        case .unknownError: .unknownError
        }
    }

    /// The status a run that stopped for this reason exits with, its kind's.
    var exitStatus: ExitCode {
        kind.exitStatus
    }
}
