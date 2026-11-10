import ArgumentParser
@testable import muterCore

extension RunCommandTests {
    /// One of each abort reason, with the status a run it stopped exits with: 3 when no mutant was tested because a
    /// baseline failed, 4 for the rest. Built from every kind of reason, so a new kind is in it or the tests don't
    /// compile.
    static var everyAbortReason: [(MutationTestingAbortReason, ExitCode)] {
        MutationTestingAbortReason.Kind.allCases.map { kind in
            let reason = sampleAbortReason(of: kind)
            let status: ExitCode = switch kind {
            case .baselineTestFailed, .workerBaselineTestFailed, .buildForTestingFailed, .buildTimeoutReached:
                .baselineFailed

            case .tooManyBuildErrors, .mutantNotSwitchedOn, .controlRunNotSwitchedOff, .simulatorUnavailable,
                 .noMutantCodeShownRunning, .unknownError: .abortedMidRun
            }
            return (reason, status)
        }
    }

    /// An abort reason of `kind`. No `default`, so a new kind needs one.
    static func sampleAbortReason(of kind: MutationTestingAbortReason.Kind) -> MutationTestingAbortReason {
        switch kind {
        case .baselineTestFailed: .baselineTestFailed(log: "", mutatedFilePaths: [])
        case .workerBaselineTestFailed: .workerBaselineTestFailed(worker: 2, directory: "/x_worker2", log: "")
        case .buildForTestingFailed: .buildForTestingFailed(description: "xcodebuild failed", log: nil)
        case .buildTimeoutReached: .buildTimeoutReached(step: .baseline, seconds: 600, output: "", log: nil)
        case .tooManyBuildErrors: .tooManyBuildErrors
        case .noMutantCodeShownRunning: .noMutantCodeShownRunning(runs: 5)
        case .mutantNotSwitchedOn: .mutantNotSwitchedOn(id: "Foo_1", description: "no space left")
        case .controlRunNotSwitchedOff: .controlRunNotSwitchedOff(number: 1, description: "no space left")
        case .simulatorUnavailable: .simulatorUnavailable(worker: 1, line: "device not found", log: nil)
        case .unknownError: .unknownError(description: "?")
        }
    }
}
