@testable import muterCore
import XCTest

/// Which error a run command shows once its work has ended under `Interruptions`.
final class RunCommandTests: XCTestCase {
    func test_withoutASignal_theWorksErrorIsShown() {
        let ended = Interruptions.Ended(result: .failure(MuterError.noSourceFilesDiscovered), signal: nil)

        XCTAssertEqual(ended.errorToShow as? MuterError, .noSourceFilesDiscovered)
    }

    func test_workThatSucceeded_showsNoError_whetherOrNotASignalCame() {
        XCTAssertNil(Interruptions.Ended(result: .success(()), signal: nil).errorToShow)
        XCTAssertNil(Interruptions.Ended(result: .success(()), signal: SIGINT).errorToShow)
    }

    // Stopping has been said, and what the work threw then, such as the failure of a process the stop killed, says
    // nothing about the project.
    func test_afterASignal_anErrorTheStopMayHaveCaused_isNotShown() {
        let cancelled = Interruptions.Ended(result: .failure(CancellationError()), signal: SIGINT)
        let copyFailed = Interruptions.Ended(
            result: .failure(MuterError.projectCopyFailed(reason: "cp was killed")),
            signal: SIGTERM
        )

        XCTAssertNil(cancelled.errorToShow)
        XCTAssertNil(copyFailed.errorToShow)
    }

    // Mutation testing aborted, and its summary on standard error pointed at "the error below"; then a Ctrl-C came
    // while worker clones were removed. No signal causes an abort, so the abort came first.
    func test_anAbortBeforeASignal_isStillShown() {
        let aborts = [
            MuterError.mutationTestingAborted(reason: .tooManyBuildErrors),
            MuterError.mutationTestingAborted(
                reason: .workerBaselineTestFailed(worker: 1, directory: "/project_mutated_worker1", log: "error: x")
            ),
        ]

        for abort in aborts {
            let ended = Interruptions.Ended(result: .failure(abort), signal: SIGINT)
            XCTAssertEqual(ended.errorToShow as? MuterError, abort)
        }
    }
}
