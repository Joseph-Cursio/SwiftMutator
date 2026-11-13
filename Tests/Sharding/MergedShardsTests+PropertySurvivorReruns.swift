@testable import muterCore
import XCTest

extension MergedShardsTests {
    // A key is in one shard alone, so each shard's survivor reruns follow its results into the merged outcome.
    func test_eachShardsPropertySurvivorReruns_followItsResults() throws {
        let rerun = PropertySurvivorRerunResult.make(of: sum9, outcome: .failed, run: 2, of: 5)

        let merged = try merge(
            file("/a/results.jsonl", header(1), sum9, sum3, rerun, end(testDuration: 40)),
            file("/b/results.jsonl", header(2, mutantsDiscovered: 1), alpha5, end(testDuration: 55.5))
        )

        let mutations = merged.mutationTestOutcome().mutations
        XCTAssertEqual(mutations.map(\.point.position.line), [5, 3, 9])
        XCTAssertEqual(mutations.map(\.propertySurvivorRerun?.failedOnRun), [nil, nil, 2])
        XCTAssertEqual(mutations.map(\.testSuiteOutcome), [.failed, .failed, .passed])
    }
}
