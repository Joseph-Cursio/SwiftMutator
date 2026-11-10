@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingActivationTests {
    // MARK: - Runs that show nothing

    // A test host that can't write its marker has real kills. They keep their verdicts, and aren't tested again.
    func test_aRunThatNeverShowsAnything_keepsItsVerdicts_andSaysSo() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantActivations = [nil, nil]
        let sent = recordEvents(named: [.activationNotShown, .unprovenRunsRerunStarted])

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .passed])
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 2)
        XCTAssertEqual(sent().map(\.name), [.activationNotShown])
        XCTAssertEqual(sent().first?.object as? Int, 2)
    }

    // A wrapper that drops the variable: no mutant is switched on, though coverage says the tests reach them.
    func test_fiveSwiftTestRunsWithCoverageThatShowNothing_stopTheRun() async throws {
        givenFiveMutantsThatShowNothing()
        state.projectCoverage = .make(percent: 78)

        do {
            _ = try await sut.run(with: state)
            XCTFail("Expected the run to stop")
        } catch let MuterError.mutationTestingAborted(reason) {
            XCTAssertEqual(reason, .noMutantCodeShownRunning(runs: 5))
        }
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.detail), ["noMutantCodeShownRunning"])
    }

    func test_oneRunThatShowsSomething_keepsTheRunGoing() async throws {
        givenFiveMutantsThatShowNothing()
        state.projectCoverage = .make(percent: 78)
        ioDelegate.mutantActivations = [false, nil, nil, nil, nil, nil]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.count, 6)
    }

    // Without coverage the tests may reach no mutant at all.
    func test_withoutCoverage_theyOnlySaySo() async throws {
        givenFiveMutantsThatShowNothing()
        state.projectCoverage = .null
        let sent = recordEvents(named: [.activationNotShown])

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.count, 6)
        XCTAssertEqual(sent().first?.object as? Int, 6)
    }

    // A test host may be unable to write.
    func test_underXcodebuild_theyOnlySaySo() async throws {
        givenFiveMutantsThatShowNothing()
        state.projectCoverage = .make(percent: 78)
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild", arguments: ["test"], testSuiteTimeOut: 42, mutationTestWorkers: 1
        )

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.count, 6)
    }

    // A test plan's code may be an older SwiftMutator's, which writes no marker.
    func test_underATestPlan_theyOnlySaySo() async throws {
        givenFiveMutantsThatShowNothing()
        state.projectCoverage = .make(percent: 78)
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json"))

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.count, 6)
    }

    // Build errors tested nothing, so they say nothing of whether runs can show it.
    func test_buildErrors_dontCountTowardTheStop() async throws {
        state.mutationMapping = try [makeMapping(lines: Array(1...3))]
        state.projectCoverage = .make(percent: 78)
        ioDelegate.testSuiteOutcomes = [.passed, .buildError, .buildError, .buildError]
        ioDelegate.mutantActivations = [nil, nil, nil]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.count, 3)
    }
}
