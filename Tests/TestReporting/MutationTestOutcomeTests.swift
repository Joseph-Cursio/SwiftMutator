@testable import muterCore
import XCTest

final class MutationTestOutcomeTests: MuterTestCase {
    func test_pathMappingWhenPathsAreDeeplyNested() {
        let mutationPoint = MutationPoint(
            mutationOperatorId: .logicalOperator,
            filePath: "/var/tmp/nonsense/ProjectDirectory/Subdirectory/file.swift",
            position: .firstPosition
        )

        let outcome = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .failed,
            point: mutationPoint,
            snapshot: .null,
            originalProjectDirectoryUrl: URL(fileURLWithPath: "/Users/user0/Code/ProjectDirectory"),
            mutatedProjectDirectoryURL: URL(fileURLWithPath: "/var/tmp/nonsense/ProjectDirectory")
        )

        XCTAssertEqual(outcome.originalProjectPath, "/Users/user0/Code/ProjectDirectory/Subdirectory/file.swift")
    }

    func test_pathMappingWhenPathsAreShallowlyNested() {
        let mutationPoint = MutationPoint(
            mutationOperatorId: .logicalOperator,
            filePath: "/tmp/ProjectDirectory/file.swift",
            position: .firstPosition
        )

        let outcome = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .failed,
            point: mutationPoint,
            snapshot: .null,
            originalProjectDirectoryUrl: URL(fileURLWithPath: "/Users/user0/Code/ProjectDirectory"),
            mutatedProjectDirectoryURL: URL(fileURLWithPath: "/var/tmp/nonsense/ProjectDirectory")
        )

        XCTAssertEqual(outcome.originalProjectPath, "/Users/user0/Code/ProjectDirectory/file.swift")
    }

    func test_pathMappingWhenPathHasSpaces() {
        let mutationPoint = MutationPoint(
            mutationOperatorId: .logicalOperator,
            filePath: "/tmp/Project Directory/file.swift",
            position: .firstPosition
        )

        let outcome = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .failed,
            point: mutationPoint,
            snapshot: .null,
            originalProjectDirectoryUrl: URL(fileURLWithPath: "/Users/user0/Project Directory"),
            mutatedProjectDirectoryURL: URL(fileURLWithPath: "/var/tmp/nonsense/Project Directory")
        )

        XCTAssertEqual(outcome.originalProjectPath, "/Users/user0/Project Directory/file.swift")
    }

    func test_pathMappingWhenThePathOfAFileContainsFoldersWithTheSameName() {
        let mutationPoint = MutationPoint(
            mutationOperatorId: .logicalOperator,
            filePath: "/var/tmp/nonsense/ProjectDirectory/ProjectDirectory/file.swift",
            position: .firstPosition
        )

        let outcome = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .failed,
            point: mutationPoint,
            snapshot: .null,
            originalProjectDirectoryUrl: URL(fileURLWithPath: "/Users/user0/Code/ProjectDirectory"),
            mutatedProjectDirectoryURL: URL(fileURLWithPath: "/var/tmp/nonsense/ProjectDirectory")
        )

        XCTAssertEqual(outcome.originalProjectPath, "/Users/user0/Code/ProjectDirectory/ProjectDirectory/file.swift")
    }

    // A run stopped at its first failed test, or one that named more tests than its line holds, may not name them all.
    func test_killingTests_areCompleteOnlyWhenTheRunExitedNamingEveryFailedTest() {
        typealias KillingTests = MutationTestOutcome.KillingTests
        let sum = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:3:5")

        XCTAssertNil(KillingTests(killedBy: nil, failedTestCount: nil, endedBy: .exited))
        XCTAssertNil(KillingTests(nil, endedBy: .exited))
        XCTAssertEqual(
            KillingTests(killedBy: [sum], failedTestCount: 1, endedBy: .exited),
            KillingTests(tests: [sum], count: 1, isComplete: true)
        )
        XCTAssertEqual(
            KillingTests(killedBy: [sum], failedTestCount: 3, endedBy: .exited),
            KillingTests(tests: [sum], count: 3, isComplete: false)
        )
        XCTAssertEqual(
            KillingTests(killedBy: [sum], failedTestCount: 1, endedBy: .stoppedAtFailedTest),
            KillingTests(tests: [sum], count: 1, isComplete: false)
        )
        XCTAssertEqual(
            KillingTests(killedBy: [], failedTestCount: 0, endedBy: .timedOut),
            KillingTests(tests: [], count: 0, isComplete: false)
        )
        XCTAssertEqual(KillingTests(killedBy: [], failedTestCount: 0, endedBy: .exited), .noneNamed)
        XCTAssertEqual(
            KillingTests(killedBy: [sum], failedTestCount: nil, endedBy: .exited),
            KillingTests(tests: [sum], count: 1, isComplete: true),
            "a missing count is the list's length"
        )
        let log = "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed"
        XCTAssertEqual(
            KillingTests(FailedTestLine.failedTests(inLog: log), endedBy: .exited),
            KillingTests(tests: [sum], count: 1, isComplete: true)
        )
    }
}
