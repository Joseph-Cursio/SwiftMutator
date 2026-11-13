import Foundation
@testable import muterCore

extension PropertySurvivorRerunResult {
    /// The line of `result`'s property survivor reruns, ended by run `run` of `runs` with `outcome`: a failure names
    /// `ordered()`.
    static func make(
        of result: MutantResult,
        outcome: TestSuiteOutcome,
        run: Int = 1,
        of runs: Int = 1,
        session: Int? = nil
    ) -> Self {
        let failed = outcome == .failed || outcome == .runtimeError
        return PropertySurvivorRerunResult(
            session: session ?? result.session,
            path: result.path,
            line: result.line,
            column: result.column,
            occurrence: result.occurrence,
            mutationOperatorId: result.mutationOperatorId,
            run: run,
            runs: runs,
            outcome: outcome,
            endedBy: .exited,
            exitStatus: outcome == .passed ? 0 : 1,
            durationSeconds: 1.5,
            worker: 0,
            finishedAt: result.finishedAt + 1,
            killedBy: failed ? [.init(name: "ordered()", location: "SortProperties.swift:8:5")] : nil,
            failedTestCount: failed ? 1 : nil,
            firstFailedTestLine: nil,
            log: nil
        )
    }
}
