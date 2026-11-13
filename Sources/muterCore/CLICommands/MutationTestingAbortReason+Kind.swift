import ArgumentParser

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
