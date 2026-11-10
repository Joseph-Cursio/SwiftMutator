@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingLoneWorkerTests {
    // Without parallel testing, the destination's runs already test one at a time on the user's simulator, with no
    // clone to pay for.
    func test_oneWorker_aProjectWhoseTestsDoNotParallelize_makesNoSimulator() async throws {
        state.apply([.projectXCTestRun(muterCore.XCTestRun())])
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices().compactMap(\.sentence), [])
        assertTestedOnTheDestination()
    }

    func test_oneWorker_aProjectWhoseTestsDoNotParallelize_getsOne_whenOneWorkerSimulatorIsTrue() async throws {
        configure(oneWorkerSimulator: .enabled)
        state.apply([.projectXCTestRun(muterCore.XCTestRun())])

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls.dropFirst().first, "prepare 1 like \(destination) for /project_mutated")
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 6))
    }

    func test_oneWorker_fewerThanSixMutants_makesNoSimulator_unlessOneWorkerSimulatorIsTrue() async throws {
        state.mutationMapping = try (1...5).map(makeSchemataMapping(line:))
        _ = try await sut.run(with: state)
        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])

        configure(oneWorkerSimulator: .enabled)
        state.mutationMapping = try (1...2).map(makeSchemataMapping(line:))
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        _ = try await sut.run(with: state)
        XCTAssertEqual(workerSimulators.calls, [
            "sweep /project_mutated",
            "sweep /project_mutated",
            "prepare 1 like \(destination) for /project_mutated",
            "boot SIM-0",
        ])
    }

    // One mutant needs no simulator of its own, whatever the key says, and nor does `--mutant`'s.
    func test_oneMutant_makesNoSimulator_withOneWorker() async throws {
        configure(oneWorkerSimulator: .enabled)
        state.mutationMapping = try [makeSchemataMapping(line: 1)]
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices().compactMap(\.sentence), [])
    }

    func test_aSelectedMutant_makesNoSimulator_withOneWorker() async throws {
        configure(oneWorkerSimulator: .enabled)
        let key = MutantKey(path: "file1.swift", mutationOperatorId: .ror, line: 1, column: 0, occurrence: 0)
        state.apply([.mutantSelected(key)])
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices().compactMap(\.sentence), [])
    }

    func test_oneWorkerSimulatorFalse_makesNone() async throws {
        configure(oneWorkerSimulator: .disabled)
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices().compactMap(\.sentence), [])
        assertTestedOnTheDestination()
    }

    // They reach a mutant's run on the destination as they reach the baseline, which then shows how such a run tests:
    // here spread over clones, so the simulator is deleted before its check run. On the destination, a mutant's run
    // tests with them (#123).
    func test_oneWorker_argumentsThatTuneParallelTesting_areCheckedAgainstTheBaseline() async throws {
        let tunings = [
            ["-parallel-testing-enabled", "YES"],
            ["-parallel-testing-worker-count", "3"],
            ["-maximum-parallel-testing-workers", "2"],
            ["-parallelize-tests-among-destinations"],
        ]
        let choices = sentChoices()
        for arguments in tunings {
            configure(arguments: arguments)
            ioDelegate.baselineTestLog = spreadBaseline
            ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 6)

            _ = try await sut.run(with: state)

            XCTAssertEqual(workerSimulators.calls.last, "removeAll", "\(arguments)")
            let mutantRuns = ioDelegate.configurations.suffix(6).map { configuration in
                configuration.testWithoutBuildArguments(with: "muter.xctestrun").dropFirst(5).first
            }
            XCTAssertEqual(Set(mutantRuns), [arguments.first], "\(arguments)")
        }

        XCTAssertEqual(choices().map(\.sentence), Array(repeating: """
        👷 Testing one mutant at a time on the test command's destination: the baseline's parallel testing spread \
        12.0 s of tests over 2 clones, which one at a time on one simulator could make slower; \
        `oneWorkerSimulator: true` tests on one anyway.
        """, count: tunings.count))
    }

    // A mutant's run on the destination tests one test at a time too, as the baseline does, so it clones nothing.
    func test_oneWorker_parallelTestingOffInTheArguments_keepsTheDestination() async throws {
        configure(arguments: ["-parallel-testing-enabled", "NO"])
        ioDelegate.baselineTestLog = "Test Case 'SumTests.sum()' passed (0.01 seconds).\n** TEST SUCCEEDED **"
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices().compactMap(\.sentence), [])
        assertTestedOnTheDestination()
        XCTAssertTrue(ioDelegate.configurations.allSatisfy { configuration in
            configuration.testWithoutBuildArguments(with: "muter.xctestrun")
                .joined(separator: " ")
                .contains("-parallel-testing-enabled NO")
        })
    }

    func test_oneWorker_aBaselineSpreadOverClones_deletesTheSimulatorBeforeItsCheckRun() async throws {
        ioDelegate.baselineTestLog = spreadBaseline
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, [
            "sweep /project_mutated",
            "prepare 1 like \(destination) for /project_mutated",
            "boot SIM-0",
            "removeAll",
        ])
        XCTAssertEqual(checkRuns, [])
        XCTAssertEqual(choices().map(\.sentence), [
            "👷 Testing one mutant at a time on the test command's destination: the baseline's parallel testing spread "
                + "12.0 s of tests over 2 clones, which one at a time on one simulator could make slower; "
                + "`oneWorkerSimulator: true` tests on one anyway.",
        ])
        assertTestedOnTheDestination()
    }

    func test_oneWorker_aShortSuiteSpreadOverClones_keepsTheSimulator() async throws {
        ioDelegate.baselineTestLog = """
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (123)' (1.000 seconds)
        Test case 'ParserTests.parse()' passed on 'Clone 2 of iPhone 17 Pro - App (124)' (2.000 seconds)
        """

        _ = try await sut.run(with: state)

        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 6))
    }

    // The baseline tests on every `-destination`, each with clones of its own, but a mutant's run only on the first:
    // its 8 s of tests over 2 clones keep the simulator, whatever the second's add up to.
    func test_oneWorker_aBaselineOnSeveralDestinations_isJudgedOnTheFirst() async throws {
        configure(arguments: ["-destination", "platform=iOS Simulator,name=iPad Air"])
        ioDelegate.baselineTestLog = """
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPad Air - App (201)' (4.000 seconds)
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (101)' (4.000 seconds)
        Test case 'ParserTests.parse()' passed on 'Clone 2 of iPhone 17 Pro - App (102)' (4.000 seconds)
        Test case 'ParserTests.parse()' passed on 'Clone 2 of iPad Air - App (202)' (4.000 seconds)
        """

        _ = try await sut.run(with: state)

        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 6))
    }

    func test_oneWorker_aBaselineWithoutCloneLines_deletesTheSimulator_andSaysWhy() async throws {
        ioDelegate.baselineTestLog = "** TEST SUCCEEDED **"
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
        XCTAssertEqual(checkRuns, [])
        XCTAssertEqual(choices().map(\.sentence), [
            "👷 Testing one mutant at a time on the test command's destination: the baseline printed no parallel "
                + "testing line to tell how many clones its tests ran on; `oneWorkerSimulator: true` tests on a "
                + "simulator of its own anyway.",
        ])
        assertTestedOnTheDestination()
    }

    func test_oneWorker_aBaselineSpreadOverClones_keepsTheSimulator_whenOneWorkerSimulatorIsTrue() async throws {
        configure(oneWorkerSimulator: .enabled)
        ioDelegate.baselineTestLog = spreadBaseline

        _ = try await sut.run(with: state)

        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        XCTAssertEqual(checkRuns, ["/logs/running/no-mutant run worker 0"])
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 6))
    }
}
