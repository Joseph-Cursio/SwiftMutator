@testable import muterCore
import XCTest

extension RecordedResultsTests {
    // A survivor's property reruns are of the result they follow: a later line of the key, or its retirement, sets
    // them aside. They never change the result: a survivor a property told apart stays a survivor.
    func test_aPropertySurvivorRerun_isKeptForTheResultItFollows_andOutcomesCarryIt() throws {
        let survivor = MutantResult.make(path: "Sources/Max.swift", line: 4, outcome: .passed)
        let rerun = PropertySurvivorRerunResult.make(of: survivor, outcome: .failed, run: 3, of: 10)
        let retested = MutantResult.make(session: 2, path: survivor.path, line: 4, outcome: .failed)

        let kept = try read(file(header, sum, survivor, rerun, end))
        let replaced = try read(file(header, survivor, rerun, end, resumed, retested))
        let retirement = ResultsRetired(session: 2, keys: [rerun.key])
        let retired = try read(file(header, survivor, rerun, end, resumed, retirement))
        let orphan = try read(file(header, rerun, end))

        XCTAssertEqual(kept.propertySurvivorReruns, [survivor.key: rerun])
        XCTAssertEqual(kept.unreadableLines, [])
        XCTAssertEqual(replaced.propertySurvivorReruns, [:])
        XCTAssertEqual(retired.propertySurvivorReruns, [:])
        XCTAssertEqual(orphan.propertySurvivorReruns, [:], "of no result")
        XCTAssertEqual(orphan.unreadableLines, [], "read, but kept for no result")

        let mutations = kept.mutationTestOutcome().mutations
        let carried = try XCTUnwrap(mutations.first { $0.propertySurvivorRerun != nil })
        XCTAssertEqual(carried.testSuiteOutcome, .passed, "still a survivor")
        XCTAssertEqual(carried.propertySurvivorRerun?.failedOnRun, 3)
        XCTAssertEqual(carried.propertySurvivorRerun?.runs, 10)
        XCTAssertEqual(mutations.count { $0.propertySurvivorRerun != nil }, 1)
    }

    // A survivor rerun is no property rerun of a kill: each kind is read into its own place.
    func test_aPropertySurvivorRerun_isNoPropertyRerunOfAKill() throws {
        let survivor = MutantResult.make(path: "Sources/Max.swift", line: 4, outcome: .passed)
        let rerun = PropertySurvivorRerunResult.make(of: survivor, outcome: .passed)

        let recorded = try read(file(header, survivor, rerun))

        XCTAssertEqual(recorded.propertyReruns, [:])
        let mutations = recorded.mutationTestOutcome().mutations
        XCTAssertEqual(mutations.compactMap(\.propertyRerun), [])
        XCTAssertEqual(mutations.compactMap(\.propertySurvivorRerun?.passedEveryRun), [true])
    }
}
