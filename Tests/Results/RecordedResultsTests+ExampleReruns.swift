@testable import muterCore
import XCTest

extension RecordedResultsTests {
    // An example rerun is of the result it follows: a later line of the key, or its retirement, sets it aside, and
    // each kind of rerun is read into its own place.
    func test_anExampleRerun_isKeptForTheResultItFollows_andOutcomesCarryIt() throws {
        let rerun = ExampleRerunResult.make(of: sum, outcome: .failed)
        let retested = MutantResult.make(session: 2, path: sum.path, outcome: .failed)

        let kept = try read(file(header, sum, rerun, product, end))
        let replaced = try read(file(header, sum, rerun, product, end, resumed, retested))
        let retirement = ResultsRetired(session: 2, keys: [sum.key])
        let retired = try read(file(header, sum, rerun, product, end, resumed, retirement))
        let orphan = try read(file(header, rerun, end))

        XCTAssertEqual(kept.exampleReruns, [sum.key: rerun])
        XCTAssertEqual(kept.propertyReruns, [:])
        XCTAssertEqual(kept.unreadableLines, [])
        XCTAssertEqual(replaced.exampleReruns, [:])
        XCTAssertEqual(retired.exampleReruns, [:])
        XCTAssertEqual(orphan.exampleReruns, [:], "of no result")
        XCTAssertEqual(orphan.unreadableLines, [], "read, but kept for no result")
        let mutations = kept.mutationTestOutcome().mutations
        XCTAssertEqual(mutations.compactMap(\.exampleRerun?.outcome), [.failed])
        XCTAssertEqual(mutations.compactMap(\.propertyRerun), [])
    }
}
