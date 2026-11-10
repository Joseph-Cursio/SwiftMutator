@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingSuspectRerunTests {
    // MARK: What a run says of a test

    private func alone(
        _ outcome: TestSuiteOutcome,
        _ log: String,
        ending: TestRun.Ending = .exited,
        activated: MutantActivation = .ran,
        sessionShowsActivation: Bool = false
    ) -> String? {
        PerformMutationTesting.testsAlone(
            [.init(name: "timing()", location: "TimingTests.swift:9:5")],
            in: TestRun(outcome: outcome, testLog: log, ending: ending, activated: activated),
            sessionShowsActivation: sessionShowsActivation
        ).first?.result
    }

    func test_aTestThatFailsAgain_failedAgain() {
        XCTAssertEqual(alone(.failed, timing), TestAlone.failedAgain)
        XCTAssertEqual(alone(.failed, timing, activated: .unknown), TestAlone.failedAgain)
    }

    func test_aTestThatFails_withItsMutantsCodeNotRunning_doesntFailForTheMutant() {
        XCTAssertEqual(alone(.failed, timing, activated: .didNotRun), TestAlone.failedWithItsCodeNotRunning)
        // Once a session's runs show they can say, one that says nothing didn't reach mutated code.
        XCTAssertEqual(
            alone(.failed, timing, activated: .unknown, sessionShowsActivation: true),
            TestAlone.failedWithItsCodeNotRunning
        )
    }

    // `swift test --quiet` prints no line for a test that passes, so a run that reached its end says it by leaving it
    // out.
    func test_aTestARunThatRanEveryTestDoesntShowFailing_passed() {
        XCTAssertEqual(alone(.failed, sum), TestAlone.passed)
        XCTAssertEqual(alone(.passed, allPassed), TestAlone.passed)
    }

    // A run a crash or its time limit ended may never have run this one, however complete its list looks.
    func test_aRunThatMayNotHaveRunTheTest_saysNothingOfIt() {
        XCTAssertNil(alone(.runtimeError, "signal 11"))
        XCTAssertNil(alone(.failed, sum + "\nerror: Exited with unexpected signal code 11"))
        XCTAssertNil(alone(.failed, sum, ending: .timedOut))
        XCTAssertNil(alone(.passed, allPassed, ending: .timedOut))
        // A failed run that names nothing failing may be one whose lines this can't read.
        XCTAssertNil(alone(.failed, ""))
    }

    func test_aFailureByAnotherTestOfTheSameName_saysNothing() {
        let other = "✘ Test timing() recorded an issue at OtherTests.swift:2:5: Expectation failed: 1 == 2"
        XCTAssertNil(alone(.failed, other))
    }

    func test_aFailureOnlyALookalikeShows_saysNothing() {
        let run = TestRun(outcome: .failed, testLog: sum, ending: .exited, activated: .ran)
        let lookalike = FailedTestLine.TestIdentity(name: "sum()", file: "SumTests.swift")

        let results = PerformMutationTesting.testsAlone(
            [.init(name: "timing()", location: "TimingTests.swift:9:5")], in: run, ignoring: [lookalike]
        )

        XCTAssertNil(results.first?.result)
    }
}
