@testable import muterCore
import XCTest

extension MergedShardsTests {
    // A key is in one shard alone, so each shard's example reruns follow its results into the merged outcome.
    func test_eachShardsExampleReruns_followItsResults() throws {
        let rerun = ExampleRerunResult.make(of: alpha5, outcome: .passed)

        let merged = try merge(
            file("/a/results.jsonl", header(1), sum9, sum3, end(testDuration: 40)),
            file("/b/results.jsonl", header(2, mutantsDiscovered: 1), alpha5, rerun, end(testDuration: 55.5))
        )

        let mutations = merged.mutationTestOutcome().mutations
        XCTAssertEqual(mutations.map(\.point.position.line), [5, 3, 9])
        XCTAssertEqual(mutations.map(\.exampleRerun?.outcome), [.passed, nil, nil])
    }
}
