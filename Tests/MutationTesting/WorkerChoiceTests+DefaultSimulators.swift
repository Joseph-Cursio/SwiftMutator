@testable import muterCore
import XCTest

/// What an xcodebuild run on a simulator says of a default count of workers, which neither `mutationTestWorkers` nor
/// `--workers` gave.
extension WorkerChoiceTests {
    func test_severalXcodebuildWorkersByDefault_sayTheyTestOnSimulators_andHowToChooseAnotherCount() {
        XCTAssertEqual(
            WorkerChoice(
                asked: 2, used: 2, unsupportedReason: nil, mutantsToTest: 363, onSimulators: true, isDefaultCount: true
            ).sentence,
            "👷 Testing 2 mutants at a time, each on a simulator of its own, by default: `--workers` or "
                + "`mutationTestWorkers` sets another count."
        )
    }

    // Too few mutants to pay for a second simulator leave one worker, which is the lone worker's choice, whatever the
    // machine: said on a simulator of its own, and otherwise only when it fell back, without "instead".
    func test_oneXcodebuildWorkerByDefault_forFewMutants_saysWhatALoneWorkerSays() {
        current.processorCount = 18
        current.physicalMemory = 64 << 30
        let iOS = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "test"]
        )
        let onItsOwn = WorkerChoice(iOS, used: 1, mutantsToTest: 49, ownSimulator: true)
        let onTheDestination = WorkerChoice(iOS, used: 1, mutantsToTest: 49)
        let fellBack = WorkerChoice(iOS, used: 1, mutantsToTest: 49, unsupportedReason: "the reason")

        XCTAssertFalse(onItsOwn.isDefaultCount)
        XCTAssertEqual(onItsOwn.asked, 1)
        XCTAssertEqual(onItsOwn.sentence, "👷 Testing one mutant at a time, on a simulator of its own.")
        XCTAssertNil(onTheDestination.sentence)
        XCTAssertEqual(
            fellBack.sentence, "👷 Testing one mutant at a time on the test command's destination: the reason."
        )
        XCTAssertTrue(WorkerChoice(iOS, used: 1, mutantsToTest: 50, unsupportedReason: "the reason").isDefaultCount)
    }

    // No line said its simulators, so the fallback says where it tests instead.
    func test_aDefaultXcodebuildRunThatFellBack_saysItTestsOnTheDestinationInstead() {
        let choice = WorkerChoice(
            asked: 2,
            used: 1,
            unsupportedReason: "the reason",
            mutantsToTest: 363,
            onSimulators: true,
            fellBack: true,
            isDefaultCount: true
        )

        XCTAssertEqual(
            choice.sentence,
            "👷 Testing one mutant at a time on the test command's destination instead: the reason."
        )
    }

    // On a Mac with enough processors and memory, an xcodebuild run on a simulator chooses 2.
    func test_theDefaultCount_ofAnXcodebuildRunOnASimulator_goesByTheMachine() {
        current.processorCount = 18
        current.physicalMemory = 64 << 30
        let iOS = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "test"]
        )

        let byDefault = WorkerChoice(iOS, used: 2, mutantsToTest: 363, ownSimulator: true)

        XCTAssertTrue(byDefault.isDefaultCount)
        XCTAssertEqual(byDefault.asked, 2)
        XCTAssertEqual(
            byDefault.sentence,
            "👷 Testing 2 mutants at a time, each on a simulator of its own, by default: `--workers` or "
                + "`mutationTestWorkers` sets another count."
        )
        let asked = WorkerChoice(iOS.overriding(workers: 2, timeout: nil), used: 2, mutantsToTest: 363)
        XCTAssertFalse(asked.isDefaultCount)
        current.physicalMemory = 16 << 30
        XCTAssertFalse(WorkerChoice(iOS, used: 1, mutantsToTest: 363).isDefaultCount)
    }
}
