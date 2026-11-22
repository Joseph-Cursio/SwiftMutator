@testable import muterCore
import TestingExtensions
import XCTest

/// An xcodebuild project's workers on a Mac whose tests run in Xcode's `xctest` agent: all on the Mac, with no
/// simulator, each from its own `.xctestrun` and derived data.
extension PerformMutationTestingXcodeWorkersTests {
    // Each worker tests in the mutated project, from the baseline's build, on the test command's own destination, one
    // test at a time; no simulator is made, and the run says where the workers test and what their tests share.
    func test_macWorkers_testOnThisMac_eachFromItsOwnTestRunAndDerivedData() async throws {
        testOnAMac(workers: 2)
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let choices = sentChoices()
        let notices = sentNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        let workers = ioDelegate.configurations.compactMap(\.xcodeWorker)
        XCTAssertEqual(workers.count, 4)
        XCTAssertTrue(workers.allSatisfy { [macWorker(0), macWorker(1)].contains($0) }, "\(workers)")
        XCTAssertTrue(ioDelegate.configurationsWithoutBuilding.compactMap(\.xcodeWorker).contains(macWorker(1)))
        XCTAssertTrue(ioDelegate.configurations.allSatisfy { configuration in
            configuration.testWithoutBuildArguments(with: "muter.xctestrun").contains("platform=macOS")
        })
        XCTAssertEqual(Set(ioDelegate.workingDirectories), [state.mutatedProjectDirectoryURL])
        let mutantFiles = zip(ioDelegate.schematas, ioDelegate.testRunFileNames).filter { $0.0 != .null }.map(\.1)
        XCTAssertEqual(mutantFiles.count, 4, "each mutant switched on once")
        XCTAssertEqual(Set(mutantFiles), ["muter.xctestrun", "muter-worker1.xctestrun"])
        XCTAssertEqual(
            Set(checkRuns),
            ["/logs/running/no-mutant run worker 0", "/logs/running/no-mutant run worker 1"]
        )
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
        XCTAssertEqual(
            try resultsFiles.records(ResultsHeader.self).map(\.workersOnOwnSimulators), [.testCommandsDestination]
        )
        XCTAssertEqual(choices().map(\.sentence), ["👷 Testing 2 mutants at a time on this Mac."])
        XCTAssertEqual(notices(), [.workersChosen, .macWorkersShareUserDefaults])
        // Nothing measured stopping a run on a Mac at its first failed test.
        XCTAssertTrue(ioDelegate.configurations.allSatisfy { !$0.stopsAtFirstFailure })
    }

    // As SwiftPM's: half the processors, at most 4, and only the mutants limit them, as they need no simulator.
    func test_macWorkersByDefault_goByTheProcessors_andSayHowToChooseAnotherCount() async throws {
        current.processorCount = 18
        testOnAMac(workers: nil)
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [4])
        XCTAssertEqual(
            Set(checkRuns),
            Set((0...3).map { "/logs/running/no-mutant run worker \($0)" })
        )
        XCTAssertEqual(choices().map(\.sentence), [
            "👷 Testing 4 mutants at a time on this Mac, by default: `--workers` or `mutationTestWorkers` sets another "
                + "count.",
        ])
        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
    }

    // The workers' files go at the end of the run, as a simulator worker's do: only worker 0's `.xctestrun` stays.
    func test_macWorkersFiles_areRemovedAtTheEnd() async throws {
        testOnAMac(workers: 2)
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            fileManager.paths.filter { $0.hasSuffix(".DerivedData.noindex") || $0.hasSuffix(".xctestrun") }.sorted(),
            [
                "/project_mutated.DerivedData.noindex",
                "/project_mutated/muter-worker1.xctestrun",
                "/project_mutated_worker1.DerivedData.noindex",
            ]
        )
    }

    // The workers' runs with no mutant on go at once, as their mutants' would; one that fails, as tests that share
    // the Mac's `UserDefaults` or files could, leaves one worker on the destination, which says why, in a Mac's words.
    func test_aMacWorkersFailedCheckRun_fallsBackToOneWorker_sayingSoInAMacsWords() async throws {
        testOnAMac(workers: 2)
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 1"] = (.failed, "Test Case failed")
        let choices = sentChoices()
        let notices = sentNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(choices().map(\.unsupportedReason), [
            "worker 1's run with no mutant on, on this Mac, didn't pass (its log is no-mutant run worker 1.log); the "
                + "workers' runs share this Mac's `UserDefaults` and your home folder, where tests can fail each "
                + "other's",
        ])
        XCTAssertEqual(choices().map(\.used), [1])
        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(notices(), [.workersChosen])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [1])
        assertTestedOnOneWorker()
    }

    // Each worker's tests have a temporary folder of their own, as a SwiftPM worker's do, named in the `.xctestrun`
    // each of its runs tests from, its check run's and its mutants' alike.
    func test_macWorkers_eachHaveATemporaryFolderOfTheirOwn_inTheirTestRunsEnvironment() async throws {
        testOnAMac(workers: 2)
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)

        _ = try await sut.run(with: state)

        let (first, second) = (macWorker(0).environment, macWorker(1).environment)
        XCTAssertEqual(Set(first.keys), ["TMPDIR", "DIRHELPER_USER_DIR_SUFFIX"])
        XCTAssertNotEqual(first["DIRHELPER_USER_DIR_SUFFIX"], second["DIRHELPER_USER_DIR_SUFFIX"])
        let expected = [
            "muter.xctestrun": XCTestRun.unhostedFixture.adding(environment: first),
            "muter-worker1.xctestrun": XCTestRun.unhostedFixture.adding(environment: second),
        ]
        XCTAssertEqual(Set(ioDelegate.testRunFileNames), Set(expected.keys))
        for (testRun, fileName) in zip(ioDelegate.testRuns, ioDelegate.testRunFileNames) {
            XCTAssertEqual(testRun, expected[fileName], fileName)
        }
    }

    // A check run that never started, as its `.xctestrun` couldn't be written, blames nothing the workers share: its
    // log says why.
    func test_aMacWorkersCheckRunThatNeverStarted_blamesNothingTheWorkersShare() async throws {
        testOnAMac(workers: 2)
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        ioDelegate.switchOnFails = { $0 == .null }
        ioDelegate.whileRunningBaseline = { [ioDelegate] _ in
            ioDelegate.switchOnError = CocoaError(.fileWriteNoPermission)
        }
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        let reasons = choices().compactMap(\.unsupportedReason)
        XCTAssertEqual(reasons.count, 1)
        let reason = reasons.first ?? ""
        XCTAssertTrue(reason.hasPrefix("worker 0's run with no mutant on, on this Mac, didn't pass"), reason)
        XCTAssertFalse(reason.contains("UserDefaults"), reason)
    }

    // `oneWorkerSimulator: true` is about one worker on a simulator: a Mac's default count of workers still tests on
    // the Mac, and no simulator is made.
    func test_macWorkersByDefault_withOneWorkerSimulatorOn_stillTestOnThisMac() async throws {
        current.processorCount = 18
        testOnAMac(workers: nil, oneWorkerSimulator: .enabled)
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [4])
        XCTAssertEqual(choices().map(\.used), [4])
        XCTAssertEqual(choices().compactMap(\.unsupportedReason), [])
        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
    }

    // A Mac app's hosted tests share its container, so they still test one mutant at a time, with no check run.
    func test_aMacAppsHostedTests_stayOnOneWorker() async throws {
        testOnAMac(workers: 2)
        state.projectXCTestRun = .withTestTargets([
            "AppTests": ["TestHostPath": muterCore.XCTestRun.macAppPath, "IsAppHostedTestBundle": true],
        ])
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(checkRuns, [])
        XCTAssertEqual(choices().map(\.used), [1])
        XCTAssertEqual(
            choices().first?.sentence,
            "👷 Testing one mutant at a time, though 2 workers were asked for: a Mac app's test runs share its "
                + "UserDefaults, saved state and container, so workers would see each other's."
        )
        assertTestedOnOneWorker()
    }

    /// Tests on a Mac, with `workers` asked for, whose one test target runs in Xcode's `xctest` agent.
    private func testOnAMac(workers: Int?, oneWorkerSimulator: ConfigurationSwitch = .unset) {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", "platform=macOS", "test"],
            mutationTestWorkers: workers,
            oneWorkerSimulator: oneWorkerSimulator
        )
        state.projectXCTestRun = .unhostedFixture
    }

    /// Worker `number` on the Mac: no simulator, one test at a time, with a temporary folder of its own.
    private func macWorker(_ number: Int) -> MuterConfiguration.XcodeWorker {
        let derivedData = MuterConfiguration.XcodeWorker.derivedData(
            ofWorker: number, in: state.mutatedProjectDirectoryURL
        )
        return MuterConfiguration.XcodeWorker(
            testRunFile: MutationTestingDelegate.testRunFileName(ofWorker: number),
            derivedData: derivedData,
            testDiagnosticsOff: true,
            parallelTestingOff: true,
            environment: SimulatorWorkerSetup.temporaryFolder(ofWorkerWith: derivedData).environment
        )
    }

    /// The worker choices and Mac notices sent from now on, by name, in order, until the test ends.
    private func sentNotices() -> () -> [RunEvent.Name] {
        let names = Locked<[RunEvent.Name]>([])
        for name in [RunEvent.Name.workersChosen, .macWorkersShareUserDefaults, .workersShareUserDefaults] {
            whenSent(name) { _ in names.change { $0.append(name) } }
        }
        return { names.value }
    }
}
