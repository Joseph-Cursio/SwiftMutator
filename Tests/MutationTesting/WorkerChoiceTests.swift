@testable import muterCore
import XCTest

final class WorkerChoiceTests: XCTestCase {
    func test_oneWorkerAsAskedFor_saysNothing() {
        XCTAssertNil(WorkerChoice(asked: 1, used: 1, isSwiftPM: true, mutantsToTest: 40).sentence)
    }

    func test_severalWorkersAsAskedFor_areSaid() {
        XCTAssertEqual(
            WorkerChoice(asked: 4, used: 4, isSwiftPM: true, mutantsToTest: 40).sentence,
            "👷 Testing 4 mutants at a time, each in a copy of the project of its own."
        )
    }

    func test_fewerMutantsThanWorkers_sayWhy() {
        XCTAssertEqual(
            WorkerChoice(asked: 4, used: 3, isSwiftPM: true, mutantsToTest: 3).sentence,
            "👷 Testing 3 mutants at a time, though 4 workers were asked for: only 3 are left to test."
        )
        XCTAssertEqual(
            WorkerChoice(asked: 4, used: 1, isSwiftPM: true, mutantsToTest: 1).sentence,
            "👷 Testing one mutant at a time, though 4 workers were asked for: only 1 is left to test."
        )
    }

    func test_anotherBuildSystem_saysWhy() {
        XCTAssertEqual(
            WorkerChoice(asked: 4, used: 1, isSwiftPM: false, mutantsToTest: 40).sentence,
            "👷 Testing one mutant at a time, though 4 workers were asked for: only SwiftPM projects test more than "
                + "one at once."
        )
    }

    // What the configuration asks for, with --workers in place of the key.
    func test_theAskedCount_isTheConfigurations() {
        let xcode = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"], mutationTestWorkers: 3)
        let choice = WorkerChoice(xcode.overriding(workers: 5, timeout: nil), used: xcode.workerCount, mutantsToTest: 9)

        XCTAssertEqual(choice, WorkerChoice(asked: 5, used: 1, isSwiftPM: false, mutantsToTest: 9))
        XCTAssertEqual(WorkerChoice(MuterConfiguration(), used: 1, mutantsToTest: 9).asked, 1)
    }
}
