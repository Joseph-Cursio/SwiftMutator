import Foundation
@testable import muterCore

extension ExampleRerunResult {
    /// The line of `result`'s example rerun, which came to `outcome`: a failure names the example `sum()`.
    static func make(of result: MutantResult, outcome: TestSuiteOutcome) -> Self {
        let failed = outcome == .failed
        return ExampleRerunResult(
            session: result.session,
            path: result.path,
            line: result.line,
            column: result.column,
            occurrence: result.occurrence,
            mutationOperatorId: result.mutationOperatorId,
            outcome: outcome,
            endedBy: .exited,
            exitStatus: outcome == .passed ? 0 : 1,
            durationSeconds: 1.5,
            worker: 0,
            finishedAt: result.finishedAt + 1,
            killedBy: failed ? [.init(name: "sum()", location: "SumTests.swift:12:5")] : nil,
            failedTestCount: failed ? 1 : nil,
            firstFailedTestLine: nil,
            log: nil
        )
    }
}
