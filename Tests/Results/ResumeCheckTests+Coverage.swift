@testable import muterCore
import XCTest

extension ResumeCheckTests {
    // Without coverage in either session, as when both skipped it, or the same coverage in both, discovery has the same
    // to go on.
    func test_coverageInNeitherSession_orTheSameInBoth_isNoChange() {
        let gathered = coverage(78, ["/project_mutated/Sources/Untested.swift"])

        XCTAssertNil(coverageChange(nil, nil))
        XCTAssertNil(coverageChange(gathered, gathered))
    }

    // A session without coverage discovers every mutant, so this is what a change in discovery most often comes from.
    // Only coverage this run has can leave out a mutant the last session discovered, and only coverage the last session
    // had can have left out one this run discovers.
    func test_coverageGatheredInOneSessionOnly_saysWhich_andWhichWayItCanMoveDiscovery() {
        let gathered = coverage(78, ["/project_mutated/Sources/Untested.swift"])

        XCTAssertEqual(coverageChange(nil, gathered), .gatheredOnlyNow)
        XCTAssertEqual(coverageChange(gathered, nil), .gatheredOnlyThen)
        XCTAssertEqual(
            "\(ResumeCheck.CoverageChange.gatheredOnlyNow)",
            "coverage couldn't be gathered then, and is now"
        )
        XCTAssertEqual(
            "\(ResumeCheck.CoverageChange.gatheredOnlyThen)",
            "coverage was gathered then, and couldn't be now"
        )
        XCTAssertTrue(ResumeCheck.CoverageChange.gatheredOnlyNow.isGatheredInOneSessionOnly)
        XCTAssertTrue(ResumeCheck.CoverageChange.gatheredOnlyThen.isGatheredInOneSessionOnly)
        XCTAssertTrue(ResumeCheck.CoverageChange.gatheredOnlyNow.canLeaveOutMutants)
        XCTAssertFalse(ResumeCheck.CoverageChange.gatheredOnlyNow.canBringInMutants)
        XCTAssertFalse(ResumeCheck.CoverageChange.gatheredOnlyThen.canLeaveOutMutants)
        XCTAssertTrue(ResumeCheck.CoverageChange.gatheredOnlyThen.canBringInMutants)
    }

    func test_theSameFilesWithoutCoverage_inAnotherOrder_isNoChange() {
        XCTAssertNil(
            coverageChange(
                coverage(78, ["/project_mutated/Sources/A.swift", "/project_mutated/Sources/B.swift"]),
                coverage(78, ["/project_mutated/Sources/B.swift", "/project_mutated/Sources/A.swift"])
            )
        )
    }

    // xcodebuild names them by their absolute path in the copy, which moves with the project, as when another CI agent
    // resumes the run. SwiftPM names them by their path in the project, which a move leaves as it is.
    func test_theSameFilesWithoutCoverage_inTheCopiesOfAProjectThatMoved_isNoChange() {
        XCTAssertNil(
            ResumeCheck.coverageChange(
                from: coverage(78, ["/agent1/App_mutated/App/Untested.swift"]),
                in: URL(fileURLWithPath: "/agent1/App_mutated"),
                to: coverage(78, ["/agent2/App_mutated/App/Untested.swift"]),
                in: URL(fileURLWithPath: "/agent2/App_mutated")
            )
        )
        XCTAssertNil(
            ResumeCheck.coverageChange(
                from: coverage(78, ["App/Untested.swift"]),
                in: URL(fileURLWithPath: "/agent1/App_mutated"),
                to: coverage(78, ["App/Untested.swift"]),
                in: URL(fileURLWithPath: "/agent2/App_mutated")
            )
        )
        XCTAssertEqual(
            ResumeCheck.coverageChange(
                from: coverage(78, ["/agent1/App_mutated/App/Untested.swift"]),
                in: URL(fileURLWithPath: "/agent1/App_mutated"),
                to: coverage(78, ["/agent2/App_mutated/App/Tested.swift"]),
                in: URL(fileURLWithPath: "/agent2/App_mutated")
            ),
            .filesWithoutCoverageChanged
        )
    }

    // A session an older SwiftMutator ran tested in `App_mutated`; this one tests in `App_mutated.noindex`.
    func test_theSameFilesWithoutCoverage_inACopyAnOlderSwiftMutatorNamed_isNoChange() {
        XCTAssertNil(
            ResumeCheck.coverageChange(
                from: coverage(78, ["/code/App_mutated/App/Untested.swift"]),
                in: URL(fileURLWithPath: "/code/App_mutated"),
                to: coverage(78, ["/code/App_mutated.noindex/App/Untested.swift"]),
                in: URL(fileURLWithPath: "/code/App_mutated.noindex")
            )
        )
    }

    // A file without coverage is left out whole, which matters more than the percent, whatever it did. Either way,
    // discovery can find more mutants or fewer.
    func test_otherFilesWithoutCoverage_isAChange_whateverThePercent() {
        let change = coverageChange(
            coverage(78, ["/project_mutated/Sources/A.swift"]),
            coverage(78, ["/project_mutated/Sources/A.swift", "/project_mutated/Sources/B.swift"])
        )

        XCTAssertEqual(change, .filesWithoutCoverageChanged)
        XCTAssertEqual(
            coverageChange(coverage(78, ["/project_mutated/Sources/A.swift"]), coverage(81, [])),
            .filesWithoutCoverageChanged
        )
        XCTAssertEqual(change.map { "\($0)" }, "the files without coverage changed")
        XCTAssertEqual(change?.isGatheredInOneSessionOnly, false)
        XCTAssertEqual(change?.canLeaveOutMutants, true)
        XCTAssertEqual(change?.canBringInMutants, true)
    }

    func test_aChangedPercentAlone_namesBothPercents() {
        let change = coverageChange(
            coverage(78, ["/project_mutated/Sources/A.swift"]),
            coverage(81, ["/project_mutated/Sources/A.swift"])
        )

        XCTAssertEqual(change, .percentChanged(was: 78, isNow: 81))
        XCTAssertEqual(change.map { "\($0)" }, "coverage was 78% and is 81% now")
        XCTAssertEqual(change?.isGatheredInOneSessionOnly, false)
        XCTAssertEqual(change?.canLeaveOutMutants, true)
        XCTAssertEqual(change?.canBringInMutants, true)
    }

    func coverage(_ percent: Int, _ filesWithoutCoverage: [String]) -> CoverageSummary {
        CoverageSummary(percent: percent, filesWithoutCoverage: filesWithoutCoverage)
    }

    /// The change between two sessions that gathered coverage in the same copy.
    func coverageChange(
        _ recorded: CoverageSummary?,
        _ current: CoverageSummary?
    ) -> ResumeCheck.CoverageChange? {
        let copy = URL(fileURLWithPath: "/project_mutated")
        return ResumeCheck.coverageChange(from: recorded, in: copy, to: current, in: copy)
    }
}
