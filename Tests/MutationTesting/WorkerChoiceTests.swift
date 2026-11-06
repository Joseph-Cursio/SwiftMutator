@testable import muterCore
import XCTest

final class WorkerChoiceTests: XCTestCase {
    func test_oneWorkerAsAskedFor_saysNothing() {
        XCTAssertNil(WorkerChoice(asked: 1, used: 1, unsupportedReason: nil, mutantsToTest: 40).sentence)
    }

    func test_severalWorkersAsAskedFor_areSaid() {
        XCTAssertEqual(
            WorkerChoice(asked: 4, used: 4, unsupportedReason: nil, mutantsToTest: 40).sentence,
            "👷 Testing 4 mutants at a time, each in a copy of the project of its own."
        )
    }

    func test_severalXcodebuildWorkersAsAskedFor_areSaidToTestOnSimulators() {
        XCTAssertEqual(
            WorkerChoice(asked: 4, used: 4, unsupportedReason: nil, mutantsToTest: 40, onSimulators: true).sentence,
            "👷 Testing 4 mutants at a time, each on a simulator of its own."
        )
    }

    func test_fewerMutantsThanWorkers_sayWhy() {
        XCTAssertEqual(
            WorkerChoice(asked: 4, used: 3, unsupportedReason: nil, mutantsToTest: 3).sentence,
            "👷 Testing 3 mutants at a time, though 4 workers were asked for: only 3 are left to test."
        )
        XCTAssertEqual(
            WorkerChoice(asked: 4, used: 1, unsupportedReason: nil, mutantsToTest: 1).sentence,
            "👷 Testing one mutant at a time, though 4 workers were asked for: only 1 is left to test."
        )
    }

    func test_anotherBuildSystem_saysWhy() {
        let other = MuterConfiguration(executable: "/usr/bin/make", arguments: ["test"], mutationTestWorkers: 4)

        XCTAssertEqual(
            WorkerChoice(other, used: 1, mutantsToTest: 40).sentence,
            "👷 Testing one mutant at a time, though 4 workers were asked for: only SwiftPM projects, and xcodebuild "
                + "projects that test on a simulator, test more than one at once."
        )
    }

    func test_aMacDestination_saysWhy() {
        let mac = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=macOS", "test"],
            mutationTestWorkers: 4
        )

        XCTAssertEqual(
            WorkerChoice(mac, used: mac.workerCount, mutantsToTest: 40).sentence,
            "👷 Testing one mutant at a time, though 4 workers were asked for: a Mac app's test runs share its "
                + "UserDefaults, saved state and container, so workers would see each other's."
        )
    }

    // A simulator destination that no one simulator matches is found out once the run starts.
    func test_anUnresolvedDestination_saysWhy() {
        let iOS = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 99", "test"],
            mutationTestWorkers: 4
        )
        let reason = "no available simulator matches `-destination platform=iOS Simulator,name=iPhone 99`, or more "
            + "than one does"

        XCTAssertEqual(
            WorkerChoice(iOS, used: 1, mutantsToTest: 40, unsupportedReason: reason).sentence,
            "👷 Testing one mutant at a time, though 4 workers were asked for: \(reason)."
        )
    }

    func test_aFailedCheckRun_saysWhy() {
        let iOS = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "test"],
            mutationTestWorkers: 2
        )
        let reason = "worker 1's run with no mutant on, on its simulator, didn't pass (its log is no-mutant run "
            + "worker 1.log)"

        XCTAssertEqual(
            WorkerChoice(iOS, used: 1, mutantsToTest: 40, unsupportedReason: reason).sentence,
            "👷 Testing one mutant at a time, though 2 workers were asked for: worker 1's run with no mutant on, on "
                + "its simulator, didn't pass (its log is no-mutant run worker 1.log)."
        )
    }

    func test_oneWorkerOnASimulatorOfItsOwn_isSaid() {
        let iOS = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "test"]
        )

        XCTAssertEqual(
            WorkerChoice(iOS, used: 1, mutantsToTest: 40, ownSimulator: true).sentence,
            "👷 Testing one mutant at a time, on a simulator of its own."
        )
    }

    // A lone worker that was to have a simulator of its own says why it tests on the destination instead.
    func test_oneWorkerThatFellBack_saysWhy() {
        let iOS = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "test"]
        )
        let reason = "worker 0's run with no mutant on, on its simulator, didn't pass (its log is no-mutant run "
            + "worker 0.log)"

        let choice = WorkerChoice(iOS, used: 1, mutantsToTest: 40, unsupportedReason: reason)

        XCTAssertTrue(choice.fellBack)
        XCTAssertEqual(
            choice.sentence,
            "👷 Testing one mutant at a time on the test command's destination: worker 0's run with no mutant on, on "
                + "its simulator, didn't pass (its log is no-mutant run worker 0.log)."
        )
    }

    // A test command that can't test on more than one says nothing for one worker, as it was asked for.
    func test_oneWorkerAsAskedFor_onAMac_saysNothing() {
        let mac = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["-destination", "platform=macOS"])
        let choice = WorkerChoice(mac, used: 1, mutantsToTest: 40)

        XCTAssertFalse(choice.fellBack)
        XCTAssertNotNil(choice.unsupportedReason)
        XCTAssertNil(choice.sentence)
    }

    func test_severalWorkersByDefault_sayHowToChooseAnotherCount() {
        XCTAssertEqual(
            WorkerChoice(asked: 4, used: 3, unsupportedReason: nil, mutantsToTest: 120, isDefaultCount: true).sentence,
            "👷 Testing 3 mutants at a time, each in a copy of the project of its own, by default: `--workers` or "
                + "`mutationTestWorkers` sets another count."
        )
    }

    // Fewer than the most by default is no surprise, and asked for nothing.
    func test_oneWorkerByDefault_forFewMutants_saysNothing() {
        XCTAssertNil(
            WorkerChoice(asked: 4, used: 1, unsupportedReason: nil, mutantsToTest: 10, isDefaultCount: true).sentence
        )
    }

    func test_aDefaultRunThatFellBack_saysWhy() {
        let choice = WorkerChoice(
            asked: 4, used: 1, unsupportedReason: "the reason", mutantsToTest: 90, fellBack: true, isDefaultCount: true
        )

        XCTAssertEqual(choice.sentence, "👷 Testing one mutant at a time instead: the reason.")
    }

    func test_theDefaultCount_isOnlyThatOfASwiftPMRunWithoutOne() {
        current.processorCount = 18
        let swift = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        let xcode = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])

        let byDefault = WorkerChoice(swift, used: 4, mutantsToTest: 500)
        let asked = WorkerChoice(swift.overriding(workers: 4, timeout: nil), used: 4, mutantsToTest: 500)

        XCTAssertTrue(byDefault.isDefaultCount)
        XCTAssertEqual(byDefault.asked, 4)
        XCTAssertFalse(asked.isDefaultCount)
        XCTAssertFalse(WorkerChoice(xcode, used: 1, mutantsToTest: 500).isDefaultCount)
    }

    func test_workersThatShareABuild_sayWhy() {
        XCTAssertEqual(
            WorkerChoice(asked: 4, used: 4, unsupportedReason: nil, mutantsToTest: 40, sharesBuild: true).sentence,
            "👷 Testing 4 mutants at a time, from one build, as your tests wrote nothing in the project."
        )
    }

    func test_workersThatShareABuildByDefault_sayHowToChooseAnotherCount() {
        XCTAssertEqual(
            WorkerChoice(
                asked: 4, used: 3, unsupportedReason: nil, mutantsToTest: 120, isDefaultCount: true, sharesBuild: true
            ).sentence,
            "👷 Testing 3 mutants at a time by default, from one build, as your tests wrote nothing in the project: "
                + "`--workers` or `mutationTestWorkers` sets another count."
        )
    }

    func test_fewerWorkersThatShareABuild_sayWhy() {
        XCTAssertEqual(
            WorkerChoice(asked: 4, used: 3, unsupportedReason: nil, mutantsToTest: 3, sharesBuild: true).sentence,
            "👷 Testing 3 mutants at a time, from one build, as your tests wrote nothing in the project, though 4 "
                + "workers were asked for: only 3 are left to test."
        )
    }

    // What the configuration asks for, with --workers in place of the key.
    func test_theAskedCount_isTheConfigurations() {
        let xcode = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"], mutationTestWorkers: 3)
        let choice = WorkerChoice(xcode.overriding(workers: 5, timeout: nil), used: xcode.workerCount, mutantsToTest: 9)

        XCTAssertEqual(
            choice,
            WorkerChoice(
                asked: 5,
                used: 1,
                unsupportedReason: xcode.parallelWorkersUnsupportedReason,
                mutantsToTest: 9,
                onSimulators: true
            )
        )
        XCTAssertEqual(WorkerChoice(MuterConfiguration(), used: 1, mutantsToTest: 9).asked, 1)
    }
}
