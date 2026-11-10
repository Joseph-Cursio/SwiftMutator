import Foundation

/// A session's last line, written when mutation testing stops however it can. A run killed by SIGKILL, or that
/// crashed, has none.
struct ResultsEnd: Codable, Equatable {
    enum Reason: String, Codable {
        case finished
        case aborted
        case interrupted
    }

    var kind = "end"
    let session: Int
    let endedAt: Date
    let reason: Reason
    /// Why it stopped early: the stopping signal's name (`"SIGINT"`) for an interruption a signal caused, or else a
    /// short code (`detail(for:)`).
    let detail: String?
    /// How long this session's mutation testing took. For a first session, exactly its `MutationTestOutcome`'s
    /// `testDuration`; a resumed session's outcome adds the earlier sessions'.
    let testDurationSeconds: Double
    /// How many mutant lines the session wrote: those of the mutants it tested, those of the mutants it took out of the
    /// build, which have no run behind them, those of the mutants it tested again, which have `rerun`, and in a session
    /// that reuses an earlier run's results, those of the results it kept, which have `reusedFrom`, and `rerun` too if
    /// a rerun gave them.
    let recorded: Int

    /// A short code for why mutation testing stopped with `error`, never a log: the abort reason's kind
    /// (`MutationTestingAbortReason.Kind`), with the worker or control run it names, or else the error's type. None
    /// for a cancellation, which `interrupted` says.
    static func detail(for error: Error) -> String? {
        if error is CancellationError {
            return nil
        }
        guard case let MuterError.mutationTestingAborted(reason) = error else {
            return String(describing: type(of: error))
        }
        let code = reason.kind.rawValue
        switch reason {
        case let .workerBaselineTestFailed(worker, _, _), let .simulatorUnavailable(worker, _, _),
             let .buildTimeoutReached(.workerBaseline(worker, _), _, _, _):
            return "\(code)(worker: \(worker))"

        case let .controlRunNotSwitchedOff(number, _):
            return "\(code)(number: \(number))"

        case .baselineTestFailed, .buildForTestingFailed, .buildTimeoutReached, .tooManyBuildErrors,
             .mutantNotSwitchedOn, .noMutantCodeShownRunning, .unknownError:
            return code
        }
    }
}
