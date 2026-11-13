import XCTest

/// Runs the built `swift-mutator` on a project whose test command is a shell script that hangs where a test asks, and
/// sends real signals to that SwiftMutator alone: to its process ID, or to its process group, which holds no other
/// process, since each process SwiftMutator starts leads a group of its own. Every process a test starts is killed
/// however the test ends, every wait is bounded, and every file a test writes is in a temporary folder.
final class InterruptionAcceptanceTests: XCTestCase {
    /// The project, and the processes a test starts on it.
    private let harness = InterruptionHarness()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try harness.create()
    }

    override func tearDownWithError() throws {
        harness.cleanUp()
        try super.tearDownWithError()
    }

    // Standard output is a pipe nobody reads, as when the same Ctrl-C ends the `| tee` that SwiftMutator writes to:
    // writing to it must not end SwiftMutator partway through stopping (SIGPIPE).
    func test_ctrlC_whileMutantsRun_stopsEveryTestProcess_keepsWhatItHas_andDiesBySIGINT() throws {
        let output = Pipe()
        let running = try harness.startSwiftMutator(hangingIn: .mutants, standardOutput: output)
        try output.fileHandleForReading.close()
        guard harness.waitUntilHanging(runs: 2, in: running) else { return }

        harness.signalGroup(of: running, SIGINT)

        harness.assertDied(running, by: SIGINT)
        harness.assertNoTestProcessIsLeft()
        let files = harness.resultsFiles()
        XCTAssertEqual(files.count, 1, "\(files)")
        if let file = files.first {
            let lines = try harness.records(in: file)
            XCTAssertEqual(lines.map { $0["kind"] as? String }, ["header", "end"])
            XCTAssertEqual(lines.last?["reason"] as? String, "interrupted")
            XCTAssertEqual(lines.last?["detail"] as? String, "SIGINT")
        }
        XCTAssertFalse(harness.exists("project_mutated_worker1.noindex"), "the worker clone is removed")
        XCTAssertTrue(
            harness.exists("project_mutated.noindex"),
            "the mutated project is kept, for the next run to remove"
        )
        XCTAssertFalse(
            harness.exists("project_mutated.active-mutant"),
            "the mutated project's active-mutant file is removed"
        )
        XCTAssertFalse(
            harness.exists("project_mutated_worker1.active-mutant"),
            "the worker's active-mutant file is removed"
        )
        // What the two runs under way wrote is kept in the log folder, and none of SwiftMutator's files is in the copy.
        XCTAssertEqual(harness.runningFiles().count, 2, "\(harness.runningFiles())")
        XCTAssertEqual(harness.visibleNamesAddedToTheCopy(), [])
        let errors = harness.contents(of: harness.standardError)
        XCTAssertTrue(errors.contains("Stopping (SIGINT)"), errors)
        XCTAssertTrue(errors.contains("Stopped by SIGINT"), errors)
    }

    func test_ctrlC_duringTheBaseline_stopsWithoutCallingItAFailure() throws {
        let running = try harness.startSwiftMutator(hangingIn: .baseline)
        guard harness.waitUntilHanging(runs: 1, in: running) else { return }

        harness.signalGroup(of: running, SIGINT)

        harness.assertDied(running, by: SIGINT)
        harness.assertNoTestProcessIsLeft()
        let output = harness.contents(of: harness.standardOutput)
        XCTAssertFalse(output.contains("initially failed"), output)
        // The results start once the baseline has passed: before, the file says only why the run stopped.
        let stopped = try harness.stoppedRecords()
        XCTAssertEqual(stopped.map { $0["kind"] as? String }, ["stopped"])
        XCTAssertEqual(stopped.map { $0["step"] as? String }, ["baseline"])
        XCTAssertEqual(stopped.map { $0["detail"] as? String }, ["SIGINT"])
        XCTAssertEqual(stopped.map { $0["log"] as? String }, ["running/baseline run"])
    }

    // Stopping the run doesn't stop the coverage run, which no cancellation reaches: killing it does.
    func test_ctrlC_duringCoverage_killsTheCoverageRun() throws {
        let running = try harness.startSwiftMutator(hangingIn: .coverage)
        guard harness.waitUntilHanging(runs: 1, in: running) else { return }

        harness.signalGroup(of: running, SIGINT)

        harness.assertDied(running, by: SIGINT, within: 10)
        harness.assertNoTestProcessIsLeft()
        let output = harness.contents(of: harness.standardOutput)
        XCTAssertFalse(output.contains("Gathering coverage failed"), output)
        XCTAssertEqual(try harness.stoppedRecords().map { $0["step"] as? String }, ["coverageRun"])
    }

    // The second signal comes once SwiftMutator has said it is stopping, so that the signals' order is certain, while
    // it removes a large worker clone, as when a second Ctrl-C comes in a large project. It comes while SwiftMutator is
    // held with SIGSTOP and the clone is still there, so that it is handled before the stop ends: sent once the stop
    // had ended, it would race SwiftMutator's own exit by SIGTERM, which says nothing, as it did on CI. Continued,
    // SwiftMutator hears the waiting signal at once, well before it can finish removing the clone.
    func test_aSecondSignal_exitsByTheFirst_leavingNoTestProcess() throws {
        let running = try harness.startSwiftMutator(hangingIn: .mutantsWithALargeWorkerClone)
        guard harness.waitUntilHanging(runs: 2, in: running) else { return }

        harness.signalProcess(running, SIGTERM)
        let stopping = harness.waitUntil(within: 5) {
            self.harness.contents(of: self.harness.standardError).contains("Stopping (SIGTERM)") || !running.isRunning
        }
        XCTAssertTrue(stopping, "SwiftMutator didn't say it was stopping")
        if running.isRunning { harness.signalProcess(running, SIGSTOP) }
        let held = harness.waitUntil(within: 5) {
            self.harness.isStopped(running.processIdentifier) || !running.isRunning
        }
        XCTAssertTrue(held, "SwiftMutator wasn't held")
        guard running.isRunning, harness.exists("project_mutated_worker1.noindex") else {
            if running.isRunning { harness.signalProcess(running, SIGCONT) }
            harness.assertDied(running, by: SIGTERM)
            harness.assertNoTestProcessIsLeft()
            throw XCTSkip("SwiftMutator had removed the worker clone before a second signal could reach it")
        }
        harness.signalProcess(running, SIGINT)
        harness.signalProcess(running, SIGCONT)

        harness.assertDied(running, by: SIGTERM)
        harness.assertNoTestProcessIsLeft()
        let errors = harness.contents(of: harness.standardError)
        XCTAssertTrue(errors.contains("Stopping at once"), errors)
    }

    // The run goes to its end, with nothing to stop it: each mutant's run is what stops itself.
    func test_aRunKilledAtAFailedTest_leavesNoProcessANewListingWouldMiss() throws {
        let running = try harness.startSwiftMutator(hangingIn: .mutantsWithAnUnlistedProcess)

        guard harness.waitUntil(within: 60, { !running.isRunning }) else {
            XCTFail("SwiftMutator was still running after 60 s")
            return
        }

        let errors = harness.contents(of: harness.standardError)
        XCTAssertFalse(errors.contains("Stopping"), errors)
        harness.assertNoTestProcessIsLeft()
    }

    // Both signals come at once, so the second most likely stops SwiftMutator before mutation testing has ended: the
    // end line is then written as it stops at once.
    func test_aSecondSignalAtOnce_stillEndsTheResults_withTheFirstSignal() throws {
        let running = try harness.startSwiftMutator(hangingIn: .mutants)
        guard harness.waitUntilHanging(runs: 2, in: running) else { return }

        harness.signalProcess(running, SIGTERM)
        harness.signalProcess(running, SIGINT)

        guard harness.waitUntil(within: 15, { !running.isRunning }) else {
            XCTFail("SwiftMutator was still running after 15 s")
            return
        }
        harness.assertNoTestProcessIsLeft()
        let signal = running.terminationReason == .uncaughtSignal ? running.terminationStatus : 0
        XCTAssertTrue([SIGTERM, SIGINT].contains(signal), harness.describe(running))
        try harness.assertTheResultsEnd(interruptedBy: signal == SIGTERM ? "SIGTERM" : "SIGINT")
        let errors = harness.contents(of: harness.standardError)
        XCTAssertTrue(errors.contains("Stopping at once"), errors)
    }

    // Ctrl-\ sends SIGQUIT to the terminal's foreground process group, which holds SwiftMutator alone.
    func test_ctrlBackslash_stopsAtOnce_leavingNoTestProcess_andEndsTheResults() throws {
        let running = try harness.startSwiftMutator(hangingIn: .mutants)
        guard harness.waitUntilHanging(runs: 2, in: running) else { return }

        harness.signalGroup(of: running, SIGQUIT)

        harness.assertDied(running, by: SIGQUIT)
        harness.assertNoTestProcessIsLeft()
        try harness.assertTheResultsEnd(interruptedBy: "SIGQUIT")
        let errors = harness.contents(of: harness.standardError)
        XCTAssertTrue(errors.contains("Stopping at once"), errors)
        XCTAssertFalse(errors.contains("Stopping (SIGQUIT)"), errors)
    }

    // When its terminal closes, zsh sends the job SIGHUP twice, about a millisecond apart. The second comes here once
    // SwiftMutator has said it is stopping, so that it is handled on its own, while a large worker clone is removed.
    func test_aRepeatedHangup_stillStopsCleanly_andDiesBySIGHUP() throws {
        let running = try harness.startSwiftMutator(hangingIn: .mutantsWithALargeWorkerClone)
        guard harness.waitUntilHanging(runs: 2, in: running) else { return }

        harness.signalGroup(of: running, SIGHUP)
        let stopping = harness.waitUntil(within: 5) {
            self.harness.contents(of: self.harness.standardError).contains("Stopping (SIGHUP)") || !running.isRunning
        }
        XCTAssertTrue(stopping, "SwiftMutator didn't say it was stopping")
        let repeated = running.isRunning
        if repeated { harness.signalGroup(of: running, SIGHUP) }

        harness.assertDied(running, by: SIGHUP)
        harness.assertNoTestProcessIsLeft()
        let errors = harness.contents(of: harness.standardError)
        XCTAssertFalse(errors.contains("Stopping at once"), errors)
        let files = harness.resultsFiles()
        XCTAssertEqual(files.count, 1, "\(files)")
        if let file = files.first {
            let lines = try harness.records(in: file)
            XCTAssertEqual(lines.last?["kind"] as? String, "end")
            XCTAssertEqual(lines.last?["reason"] as? String, "interrupted")
            XCTAssertEqual(lines.last?["detail"] as? String, "SIGHUP")
        }
        XCTAssertFalse(harness.exists("project_mutated_worker1.noindex"), "the worker clone is removed")
        guard repeated else { throw XCTSkip("SwiftMutator stopped before a second SIGHUP could reach it") }
    }

    // Ctrl-Z sends SIGTSTP to the terminal's foreground process group, which holds SwiftMutator alone, and `fg` sends
    // it SIGCONT. Its tests are suspended with it, so they don't end meanwhile, and their time limit doesn't count the
    // time: SwiftMutator suspended alone, a test that had ended could be recorded as a timeout once it continued.
    func test_ctrlZ_suspendsTheTestsToo_andTheirTimeLimitDoesntCountTheTime() throws {
        try harness.setTimeLimit(5)
        let running = try harness.startSwiftMutator(hangingIn: .slowMutants)
        guard harness.waitUntilHanging(runs: 2, in: running) else { return }

        harness.signalGroup(of: running, SIGTSTP)

        let suspended = harness.waitUntil(within: 5) { self.harness.isStopped(running.processIdentifier) }
        XCTAssertTrue(suspended, "SwiftMutator wasn't suspended")
        // Each run's processes last 3 s from when they write themselves down, so those written down less than 2.9 s
        // before SwiftMutator was seen suspended were running when it stopped them. An older one may have ended just
        // before, as when the second worker's first run started 3 s after the first's, and an ended process isn't
        // stopped.
        let testProcesses = harness.testProcesses(writtenDownWithin: 2.9, before: Date())
        XCTAssertFalse(testProcesses.isEmpty, "no test was under way")
        let stoppedTogether = harness.waitUntil(within: 2) { testProcesses.allSatisfy(self.harness.isStopped) }
        XCTAssertTrue(stoppedTogether, "its tests run on")
        Thread.sleep(forTimeInterval: 6) // past the time limit, and past the end of the tests, had they run on
        XCTAssertEqual(testProcesses.filter { !self.harness.isStopped($0) }.sorted(), [], "its tests ran on")

        harness.signalGroup(of: running, SIGCONT)

        guard harness.waitUntil(within: 30, { !running.isRunning }) else {
            XCTFail("SwiftMutator was still running after 30 s: \(harness.contents(of: harness.standardError))")
            return
        }
        XCTAssertEqual(running.terminationReason, .exit, harness.describe(running))
        harness.assertNoTestProcessIsLeft()
        let files = harness.resultsFiles()
        XCTAssertEqual(files.count, 1, "\(files)")
        let mutants = try files.flatMap(harness.records(in:)).filter { $0["kind"] as? String == "mutant" }
        XCTAssertGreaterThanOrEqual(mutants.count, 2)
        for mutant in mutants {
            XCTAssertEqual(mutant["outcome"] as? String, "passed", "\(mutant)")
            let seconds = try XCTUnwrap(mutant["durationSeconds"] as? Double)
            XCTAssertLessThan(seconds, 5, "the time suspended counted: \(mutant)")
        }
    }

    // `kill %1` sends a suspended job SIGTERM, then SIGCONT, without which it couldn't stop.
    func test_aSuspendedRun_stopsCleanly_onceContinued() throws {
        let running = try harness.startSwiftMutator(hangingIn: .mutants)
        guard harness.waitUntilHanging(runs: 2, in: running) else { return }
        harness.signalGroup(of: running, SIGTSTP)
        let suspended = harness.waitUntil(within: 5) { self.harness.isStopped(running.processIdentifier) }
        XCTAssertTrue(suspended, "SwiftMutator wasn't suspended")

        harness.signalGroup(of: running, SIGTERM)
        harness.signalGroup(of: running, SIGCONT)

        harness.assertDied(running, by: SIGTERM)
        harness.assertNoTestProcessIsLeft()
        let files = harness.resultsFiles()
        XCTAssertEqual(files.count, 1, "\(files)")
        if let file = files.first {
            XCTAssertEqual(try harness.records(in: file).last?["detail"] as? String, "SIGTERM")
        }
    }

    // `nohup` starts SwiftMutator with SIGHUP ignored, so that a run outlives the terminal it started in.
    func test_aHangupIgnoredAtStart_staysIgnored_andSIGTERMStillStops() throws {
        let running = try harness.startSwiftMutator(hangingIn: .mutants, underNohup: true)
        guard harness.waitUntilHanging(runs: 2, in: running) else { return }

        harness.signalGroup(of: running, SIGHUP)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(running.isRunning, "SIGHUP stopped a run started under nohup")
        let testProcesses = harness.shells.union(harness.sleepers)
        XCTAssertEqual(testProcesses.filter(harness.isGone).sorted(), [], "test processes ended by SIGHUP")
        harness.signalProcess(running, SIGTERM)

        harness.assertDied(running, by: SIGTERM)
        harness.assertNoTestProcessIsLeft()
    }
}
