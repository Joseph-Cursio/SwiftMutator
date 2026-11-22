@testable import muterCore
import XCTest

/// What an xcodebuild run says of its workers on a Mac whose tests run in Xcode's `xctest` agent.
extension WorkerChoiceTests {
    func test_severalMacWorkers_sayTheyTestOnThisMac() {
        current.processorCount = 18
        let byDefault = macWithUnhostedTests()
        let asked = macWithUnhostedTests(workers: 3)

        let defaultChoice = WorkerChoice(byDefault, used: 4, mutantsToTest: 120, ownSimulator: false)
        XCTAssertTrue(defaultChoice.onThisMac)
        XCTAssertFalse(defaultChoice.onSimulators)
        XCTAssertTrue(defaultChoice.isDefaultCount)
        XCTAssertEqual(
            defaultChoice.sentence,
            "👷 Testing 4 mutants at a time on this Mac, by default: `--workers` or `mutationTestWorkers` sets another "
                + "count."
        )
        XCTAssertEqual(
            WorkerChoice(asked, used: 3, mutantsToTest: 120).sentence,
            "👷 Testing 3 mutants at a time on this Mac."
        )
    }

    // With no simulator to pay for, a default count isn't cut to the mutants that pay one back, only to the mutants.
    func test_aDefaultCountOfMacWorkers_forFewMutants_isStillSeveral() {
        current.processorCount = 18
        let choice = WorkerChoice(macWithUnhostedTests(), used: 2, mutantsToTest: 2)

        XCTAssertEqual(choice.asked, 2)
        XCTAssertEqual(
            choice.sentence,
            "👷 Testing 2 mutants at a time on this Mac, by default: `--workers` or `mutationTestWorkers` sets another "
                + "count."
        )
        XCTAssertEqual(
            WorkerChoice(macWithUnhostedTests(workers: 4), used: 2, mutantsToTest: 2).sentence,
            "👷 Testing 2 mutants at a time, though 4 workers were asked for: only 2 are left to test."
        )
    }

    // A failed check run leaves one worker on the test command's destination, the Mac, as a SwiftPM run's failed
    // clones leave one worker.
    func test_macWorkersThatFellBack_sayWhy() {
        current.processorCount = 18

        XCTAssertEqual(
            WorkerChoice(macWithUnhostedTests(), used: 1, mutantsToTest: 120, unsupportedReason: "the reason")
                .sentence,
            "👷 Testing one mutant at a time instead: the reason."
        )
        XCTAssertEqual(
            WorkerChoice(macWithUnhostedTests(workers: 4), used: 1, mutantsToTest: 120, unsupportedReason: "the reason")
                .sentence,
            "👷 Testing one mutant at a time, though 4 workers were asked for: the reason."
        )
    }

    /// An xcodebuild test command on a Mac whose one test target runs in Xcode's `xctest` agent.
    private func macWithUnhostedTests(workers: Int? = nil) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "Sum", "-destination", "platform=macOS", "test"],
            mutationTestWorkers: workers
        ).withMacWorkerFact(given: .unhostedFixture)
    }
}
