@testable import muterCore
import XCTest

/// The time limits of the runs with no mutant on: the baselines', from `buildTimeout`, and the others', as given.
final class MutationTestingDelegateTimeLimitTests: MuterTestCase {
    private let sut = MutationTestingDelegate()

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Test logs are written to the current directory; keep them in the folder removed afterwards.
        fileManager.currentDirectoryPathToReturn = try makeTemporaryDirectory()
    }

    func test_runningTestsWithoutBuilding_stopsAtTheTimeLimitItIsGiven() async throws {
        let configuration = MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: 5)
        testingTimeOutExecutor.shouldSucceed = false

        let run = await sut.runTestsWithoutBuilding(
            using: configuration, timeLimit: 42, savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(testingTimeOutExecutor.timeLimitPassed, 42)
        XCTAssertEqual(run.ending, .timedOut)
        XCTAssertTrue(process.terminateTreeCalled)
    }

    // A mutant's limit is never a baseline's: without a buildTimeout, the project's baseline has none.
    func test_aBaselineWithoutABuildTimeout_hasNoLimit_whateverTheMutantsLimit() async throws {
        let configuration = MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: 5)

        _ = await sut.benchmarkTests(using: configuration, savingResultsIntoFileNamed: "logFileName")

        XCTAssertFalse(testingTimeOutExecutor.withTimeLimitCalled)
    }

    // The baselines, the project's and a clone's, build, so they run under buildTimeout, never a mutant's limit, and
    // say when it stopped them.
    func test_aBaseline_runsUnderTheBuildTimeout() async throws {
        let configuration = MuterConfiguration(
            executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: 5, buildTimeout: 600
        )
        testingTimeOutExecutor.shouldSucceed = false
        for workingDirectory in [nil, URL(fileURLWithPath: "/project_mutated_worker1")] {
            let run = if let workingDirectory {
                await sut.benchmarkTests(
                    using: configuration, savingResultsIntoFileNamed: "logFileName", workingDirectory: workingDirectory
                )
            } else {
                await sut.benchmarkTests(using: configuration, savingResultsIntoFileNamed: "logFileName")
            }

            XCTAssertEqual(testingTimeOutExecutor.timeLimitPassed, 600, "\(String(describing: workingDirectory))")
            XCTAssertEqual(run.ending, .timedOut, "\(String(describing: workingDirectory))")
        }
    }
}
