@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

extension PerformMutationTestingSuspectRerunTests {
    // MARK: Which kills

    private func kill(naming names: [String], at index: Int = 0) -> MutationTestOutcome.Mutation {
        .make(
            testSuiteOutcome: .failed,
            point: .make(filePath: "/project/Sources/F\(index).swift"),
            killingTests: .init(
                tests: names.map { .init(name: $0, location: nil) }, count: names.count, isComplete: true
            )
        )
    }

    private func identity(_ name: String) -> FailedTestLine.TestIdentity {
        .init(name: name, file: nil)
    }

    private func candidates(
        _ outcomes: [Int: MutationTestOutcome.Mutation],
        suspects: [String],
        limit: Int = 100,
        notInTheBuild: Set<Int> = []
    ) -> (indices: [Int], leftOut: Int) {
        PerformMutationTesting.suspectKillCandidates(
            in: outcomes,
            suspects: Set(suspects.map(identity)),
            limit: limit,
            notInTheBuild: notInTheBuild
        )
    }

    func test_candidates_areEveryKillOnlySuspectsFailedFor_upToTheLimit() {
        let outcomes = Dictionary(uniqueKeysWithValues: (0 ..< 10).map { ($0, kill(naming: ["a"], at: $0)) })

        XCTAssertEqual(candidates(outcomes, suspects: ["a"]).indices, Array(0 ..< 10))
        let limited = candidates(outcomes, suspects: ["a"], limit: 5)
        XCTAssertEqual(limited.indices.count, 5)
        XCTAssertEqual(limited.leftOut, 5)
        XCTAssertEqual(candidates(outcomes, suspects: ["a"], limit: 0).indices, [])
    }

    func test_candidates_giveEverySuspectItsShare_beforeAnyGetsMore() {
        var outcomes = Dictionary(uniqueKeysWithValues: (0 ..< 90).map { ($0, kill(naming: ["a"], at: $0)) })
        for index in 90 ..< 95 {
            outcomes[index] = kill(naming: ["b"], at: index)
        }

        let picked = candidates(outcomes, suspects: ["a", "b"], limit: 6).indices

        XCTAssertEqual(picked.count { $0 < 90 }, 3)
        XCTAssertEqual(picked.count { $0 >= 90 }, 3)
    }

    // A suspect that only ever fails beside another test has no kill of its own to judge it by.
    func test_candidates_topUpFromOtherKills_aSuspectWithTooFewOfItsOwn() {
        let outcomes = [
            0: kill(naming: ["a"]),
            1: kill(naming: ["a", "good"]),
            2: kill(naming: ["a", "good"]),
            3: kill(naming: ["a", "good"]),
            4: kill(naming: ["good"]),
        ]

        XCTAssertEqual(candidates(outcomes, suspects: ["a"]).indices.count, 3)
        XCTAssertTrue(candidates(outcomes, suspects: ["a"]).indices.contains(0))
        XCTAssertFalse(candidates(outcomes, suspects: ["a"]).indices.contains(4))
    }

    func test_candidates_leaveOutWhatCantOrNeedntBeTested() {
        var unproven = kill(naming: ["a"])
        unproven.activated = false
        var tested = kill(naming: ["a"])
        tested.rerun = Rerun(because: Rerun.onlySuspectTestsFailed, workers: 1, alone: [])
        var unprovenThenProven = kill(naming: ["a"])
        unprovenThenProven.rerun = Rerun(because: Rerun.codeNotShownRunning, workers: 1)
        let reused = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .failed,
            killingTests: .init(tests: [.init(name: "a", location: nil)], count: 1, isComplete: true),
            reusedFrom: .init(resultsFile: "r", session: 1, despiteChanges: false)
        )
        let outcomes = [
            0: kill(naming: ["a"]),
            1: unproven,
            2: tested,
            3: reused,
            4: kill(naming: ["a"]),
            5: kill(naming: []),
            6: unprovenThenProven,
            7: .make(testSuiteOutcome: .runtimeError),
        ]

        XCTAssertEqual(candidates(outcomes, suspects: ["a"], notInTheBuild: [4]).indices, [0, 6])
    }

    func test_candidates_countAKillThatNamesSeveralSuspects_forEachOfThem() {
        var outcomes: [Int: MutationTestOutcome.Mutation] = [:]
        for index in 0 ..< 3 {
            outcomes[index] = kill(naming: ["a", "b", "good"], at: index)
        }
        for index in 3 ..< 6 {
            outcomes[index] = kill(naming: ["b"], at: index)
        }
        for index in 6 ..< 9 {
            outcomes[index] = kill(naming: ["c"], at: index)
        }

        let picked = candidates(outcomes, suspects: ["a", "b", "c"], limit: 6).indices

        XCTAssertEqual(picked.count { $0 >= 6 }, 3, "\(picked)")
    }

    func test_candidates_countWhatEarlierSessionsTested_towardATestsShare() {
        var outcomes = Dictionary(uniqueKeysWithValues: (0 ..< 3).map { ($0, kill(naming: ["a"], at: $0)) })
        for index in 3 ..< 6 {
            outcomes[index] = kill(naming: ["b"], at: index)
        }
        for index in 6 ..< 9 {
            var tested = kill(naming: ["a"], at: index)
            tested.rerun = Rerun(
                because: Rerun.onlySuspectTestsFailed,
                workers: 1,
                alone: [.init(name: "a", file: nil, result: TestAlone.failedAgain)]
            )
            outcomes[index] = tested
        }

        let picked = candidates(outcomes, suspects: ["a", "b"], limit: 6).indices

        XCTAssertEqual(picked.sorted(), [3, 4, 5])
    }

    // A resumed run's earlier sessions used some of the limit, so stopping it tests no more than running it through.
    func test_theLimit_isPerRun_soItCountsThoseEarlierSessionsTested() {
        var outcomes = Dictionary(uniqueKeysWithValues: (0 ..< 5).map { ($0, kill(naming: ["a"], at: $0)) })
        for index in 5 ..< 8 {
            var tested = kill(naming: ["a"], at: index)
            tested.rerun = Rerun(because: Rerun.onlySuspectTestsFailed, workers: 1, alone: [])
            outcomes[index] = tested
        }

        let (indices, leftOut) = candidates(outcomes, suspects: ["a"], limit: 5)

        XCTAssertEqual(indices.count, 2)
        XCTAssertEqual(leftOut, 3)
    }

    func test_evenlySpaced_spreadsOverAll() {
        XCTAssertEqual(PerformMutationTesting.evenlySpaced(Array(0 ..< 10), count: 2), [0, 5])
        XCTAssertEqual(PerformMutationTesting.evenlySpaced(Array(0 ..< 3), count: 5), [0, 1, 2])
        XCTAssertEqual(PerformMutationTesting.evenlySpaced(Array(0 ..< 3), count: 0), [])
    }
}
