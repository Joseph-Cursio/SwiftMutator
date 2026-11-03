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
