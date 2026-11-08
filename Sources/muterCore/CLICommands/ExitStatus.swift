import ArgumentParser

/// The statuses SwiftMutator's own commands exit with, besides 0, a usage error's 64, `report`'s 1 for a results file
/// it can't read, and 128 plus the signal for a run a signal stopped (`Interruptions.exit(by:)`): 2 for a score below
/// `--fail-under`, or every mutant a build error, or more new survivors than `--max-new-survivors` allows against
/// `--baseline`'s file, or a score more than `--max-score-drop` points below that file's, or more doubtful kills than
/// `--max-doubtful-kills` allows, 3 for a failed baseline, 4 for mutation testing an error stopped partway, 5, 6 and
/// 7 for a refused resume, lock or test plan, 8 for a refused baseline file, and 255 for any other error.
extension ExitCode {
    /// A command stopped on any other error, such as a missing configuration, a configuration that doesn't parse, a
    /// `--mutant` that names no mutant, or a `--since` that git can't answer. It exits 255, through -1, as SwiftMutator
    /// always has.
    static let stoppedOnAnError = ExitCode(-1)

    /// The headline score is below the threshold `--fail-under` or `failUnder` sets, or every mutant was a build error
    /// (`ScoreGate`), or more of the run's survivors are new against `--baseline`'s file than `--max-new-survivors`
    /// allows (`NewSurvivorsCheck`), or its score fell more than `--max-score-drop` points below that file's
    /// (`ScoreDropCheck`), or more of its kills are doubtful than `--max-doubtful-kills` allows
    /// (`DoubtfulKillsCheck`): every failed check exits with it. Every report, the results file and
    /// `summary.json` were written first, as for any finished run.
    static let scoreBelowThreshold = ExitCode(2)

    /// The baseline run, with no mutant on, failed in the project's copy or in a parallel worker's clone of it
    /// (`MutationTestingAbortReason.baselineTestFailed` and `.workerBaselineTestFailed`), or xcodebuild's build for
    /// testing did (`.buildForTestingFailed`), or one of them ran past `buildTimeout` (`.buildTimeoutReached`), so no
    /// mutant was tested. A failure no mutant that doesn't compile explains (`CompileRecovery`).
    /// `report` exits with it too, for the results file such a run leaves, which says only why (`ResultsStopped`); in a
    /// merge, that shard is left out, as one whose file isn't given, which exits 4.
    static let baselineFailed = ExitCode(3)

    /// An error stopped mutation testing partway, such as five build errors in a row (every other
    /// `MutationTestingAbortReason`); the results so far are kept. `report` exits with it for a results file whose run
    /// stopped so, for shards whose merged report lacks results (`MergedShards.lacksResults`): one stopped so, was
    /// interrupted, or isn't given; and for the file of a run a signal stopped before its first mutant
    /// (`ResultsStopped`), as `report` can't die of the signal.
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

    /// SwiftMutator refused `--baseline`'s file (`BaselineRefused`): there is none at the path, it can't be read, it
    /// holds a key it doesn't know or is of a newer format, or it records a run of another scope, whose mutants differ,
    /// such as one with other operators or another configuration. A run refuses it before any mutant is tested, and
    /// `report` before any report is made. The message names every reason.
    static let baselineRefused = ExitCode(8)

    /// The status a run command exits with when its work failed with `error`, or nil when it exits 0: nothing to
    /// mutate and a shard with no mutant are not failures. A `--baseline` run left with only mutants of code no test
    /// ran exits as its checks do (`OnlyUncoveredMutants`). A refused resume or reuse, a run refused because another
    /// run holds a lock it needs, a refused test plan, a refused baseline file, a failed baseline and an abort each
    /// have a status of their own, so a script can tell them from any other error.
    static func exitStatus(afterRunFailedWith error: Error) -> ExitCode? {
        switch error {
        case let error as OnlyUncoveredMutants:
            return error.checks.exitStatus
        case is NothingToMutate, is EmptyShard:
            return nil
        case let refused as ResumeRefused:
            return refused.isInUse ? .anotherRunHoldsTheLock : .resumeRefused
        case MutatedProjectLockError.inUse:
            return .anotherRunHoldsTheLock
        case is TestPlanRefused:
            return .testPlanRefused
        case is BaselineRefused:
            return .baselineRefused
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
        case buildForTestingFailed
        case buildTimeoutReached
        case tooManyBuildErrors
        case mutantNotSwitchedOn
        case controlRunNotSwitchedOff
        case simulatorUnavailable
        case noMutantCodeShownRunning
        case unknownError

        /// The status a run that stopped for a reason of this kind exits with: `baselineFailed` when no mutant was
        /// tested because a baseline or a build failed, or ran past its limit, and `abortedMidRun` for the rest. No
        /// `default`, so a new kind needs a status chosen.
        var exitStatus: ExitCode {
            switch self {
            case .baselineTestFailed, .workerBaselineTestFailed, .buildForTestingFailed, .buildTimeoutReached:
                return .baselineFailed
            case .tooManyBuildErrors, .mutantNotSwitchedOn, .controlRunNotSwitchedOff, .simulatorUnavailable,
                 .noMutantCodeShownRunning, .unknownError:
                return .abortedMidRun
            }
        }
    }

    /// Which reason this is. No `default`, so a new reason needs a kind, and with it a status and an end-line code.
    var kind: Kind {
        switch self {
        case .baselineTestFailed: .baselineTestFailed
        case .workerBaselineTestFailed: .workerBaselineTestFailed
        case .buildForTestingFailed: .buildForTestingFailed
        case .buildTimeoutReached: .buildTimeoutReached
        case .tooManyBuildErrors: .tooManyBuildErrors
        case .mutantNotSwitchedOn: .mutantNotSwitchedOn
        case .controlRunNotSwitchedOff: .controlRunNotSwitchedOff
        case .simulatorUnavailable: .simulatorUnavailable
        case .noMutantCodeShownRunning: .noMutantCodeShownRunning
        case .unknownError: .unknownError
        }
    }

    /// The status a run that stopped for this reason exits with, its kind's.
    var exitStatus: ExitCode {
        kind.exitStatus
    }
}
