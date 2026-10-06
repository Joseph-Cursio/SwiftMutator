import XCTest

/// Runs the built `swift-mutator` on a project whose test command is a shell script that hangs where a test asks, and
/// sends real signals to that SwiftMutator alone: to its process ID, or to its process group, which holds no other
/// process, since each process SwiftMutator starts leads a group of its own. Every process a test starts is killed
/// however the test ends, every wait is bounded, and every file a test writes is in a temporary folder.
final class InterruptionAcceptanceTests: XCTestCase {
    /// Where the test command hangs: in the coverage run, in the baseline, or in each mutant's run.
    private enum Phase: String {
        case coverage
        case baseline
        case mutants
        /// In each mutant's run, as `mutants`, once worker 1 has filled its clone with files, so that removing the
        /// clone keeps a stopping SwiftMutator busy for a while.
        case mutantsWithALargeWorkerClone
    }

    /// Where the test command hangs, it writes down its own ID, starts a `sleep` whose odd length makes one left
    /// behind easy to find, writes down that ID too, and waits. A hanging run is then a tree, as `swift test` is.
    /// `$0` is the argument SwiftMutator adds, `--enable-code-coverage` in the coverage run. The active mutant's file
    /// is in the folder of the worker running the test command.
    private static let testCommand = """
        hang() {
            echo $$ > "$INTERRUPT_TEST_MARKERS/sh.$$"
            /bin/sleep 60.7 & echo $! > "$INTERRUPT_TEST_MARKERS/sleep.$!"
            wait
        }
        fill() { mkdir "$1" && cd "$1" && /usr/bin/seq -f "file%g" 2000 | /usr/bin/xargs /usr/bin/touch; }
        worker="${SWIFTMUTATOR_ACTIVE_MUTANT_FILE%/*}"
        case "$INTERRUPT_TEST_PHASE:$0" in
            coverage:--enable-code-coverage) hang;;
            baseline:*) [ -s "$SWIFTMUTATOR_ACTIVE_MUTANT_FILE" ] || hang;;
            mutantsWithALargeWorkerClone:*)
                case "$worker" in *_worker1) [ -d "$worker/files" ] || (fill "$worker/files");; esac;;
        esac
        [ -s "$SWIFTMUTATOR_ACTIVE_MUTANT_FILE" ] && hang
        exit 0
        """

    private var swiftMutator: URL!
    private var root: URL!
    private var project: URL!
    private var markers: URL!
    private var standardOutput: URL { root.appendingPathComponent("stdout.txt") }
    private var standardError: URL { root.appendingPathComponent("stderr.txt") }
    /// The SwiftMutator a test started.
    private var mutator: Foundation.Process?
    /// The processes the test command wrote down, once seen. One confirmed gone is never signalled again: the
    /// system may give its ID to another process.
    private var shells: Set<Int32> = []
    private var sleepers: Set<Int32> = []
    private var confirmedGone: Set<Int32> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let products = try XCTUnwrap(Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") })
            .bundleURL
            .deletingLastPathComponent()
        swiftMutator = products.appendingPathComponent("swift-mutator")
        guard FileManager.default.isExecutableFile(atPath: swiftMutator.path) else {
            throw XCTSkip("No swift-mutator next to the test bundle, which `swift test` builds")
        }

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterruptionAcceptanceTests-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        markers = root.appendingPathComponent("markers", isDirectory: true)
        let sources = project.appendingPathComponent("Sources/Lib", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        try """
        func isPositive(_ value: Int) -> Bool { value > 0 }
        func isSmall(_ value: Int) -> Bool { value < 10 }

        """.write(to: sources.appendingPathComponent("Lib.swift"), atomically: true, encoding: .utf8)
        let script = Self.testCommand
            .split(separator: "\n")
            .map { "    " + $0 }
            .joined(separator: "\n")
        try """
        executable: /bin/sh
        arguments:
          - "-c"
          - |
        \(script)
        buildSystem: swift
        mutationTestWorkers: 2
        mutationTestTimeout: 600

        """.write(to: project.appendingPathComponent("muter.conf.yml"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let mutator, mutator.isRunning {
            let pid = mutator.processIdentifier
            if pid > 1 { kill(-pid, SIGKILL) } // its own group, which holds SwiftMutator alone
            _ = waitUntil(within: 5) { !mutator.isRunning }
            // A test command it was starting as it was killed can write itself down a moment later.
            Thread.sleep(forTimeInterval: 0.3)
        }
        recordMarkers()
        // Each shell leads the process group SwiftMutator started it in, and its `sleep` is in that group too, even
        // one started after the shell was last seen. A group found empty is never signalled again.
        var groups = shells.subtracting(confirmedGone).filter { $0 > 1 } // kill(-1) signals everything
        _ = waitUntil(within: 5) {
            groups = groups.filter { kill(-$0, SIGKILL) == 0 || errno != ESRCH }
            return groups.isEmpty
        }
        for pid in sleepers.subtracting(confirmedGone) where pid > 1 && !isGone(pid) {
            kill(pid, SIGKILL)
        }
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Tests

    // Standard output is a pipe nobody reads, as when the same Ctrl-C ends the `| tee` that SwiftMutator writes to:
    // writing to it must not end SwiftMutator partway through stopping (SIGPIPE).
    func test_ctrlC_whileMutantsRun_stopsEveryTestProcess_keepsWhatItHas_andDiesBySIGINT() throws {
        let output = Pipe()
        let mutator = try startSwiftMutator(hangingIn: .mutants, standardOutput: output)
        try output.fileHandleForReading.close()
        guard waitUntilHanging(runs: 2, in: mutator) else { return }

        signalGroup(of: mutator, SIGINT)

        assertDied(mutator, by: SIGINT)
        assertNoTestProcessIsLeft()
        let files = resultsFiles()
        XCTAssertEqual(files.count, 1, "\(files)")
        if let file = files.first {
            let lines = try records(in: file)
            XCTAssertEqual(lines.map { $0["kind"] as? String }, ["header", "end"])
            XCTAssertEqual(lines.last?["reason"] as? String, "interrupted")
            XCTAssertEqual(lines.last?["detail"] as? String, "SIGINT")
        }
        XCTAssertFalse(exists("project_mutated_worker1"), "the worker clone is removed")
        XCTAssertTrue(exists("project_mutated"), "the mutated project is kept, for the next run to remove")
        let errors = contents(of: standardError)
        XCTAssertTrue(errors.contains("Stopping (SIGINT)"), errors)
        XCTAssertTrue(errors.contains("Stopped by SIGINT"), errors)
    }

    func test_ctrlC_duringTheBaseline_stopsWithoutCallingItAFailure() throws {
        let mutator = try startSwiftMutator(hangingIn: .baseline)
        guard waitUntilHanging(runs: 1, in: mutator) else { return }

        signalGroup(of: mutator, SIGINT)

        assertDied(mutator, by: SIGINT)
        assertNoTestProcessIsLeft()
        let output = contents(of: standardOutput)
        XCTAssertFalse(output.contains("initially failed"), output)
        XCTAssertEqual(resultsFiles(), [], "the results file starts once the baseline has passed")
    }

    // Stopping the run doesn't stop the coverage run, which no cancellation reaches: killing it does.
    func test_ctrlC_duringCoverage_killsTheCoverageRun() throws {
        let mutator = try startSwiftMutator(hangingIn: .coverage)
        guard waitUntilHanging(runs: 1, in: mutator) else { return }

        signalGroup(of: mutator, SIGINT)

        assertDied(mutator, by: SIGINT, within: 10)
        assertNoTestProcessIsLeft()
        let output = contents(of: standardOutput)
        XCTAssertFalse(output.contains("Gathering coverage failed"), output)
    }

    // The second signal comes once SwiftMutator has said it is stopping, so that the signals' order is certain, while
    // it removes a large worker clone, as when a second Ctrl-C comes in a large project.
    func test_aSecondSignal_exitsByTheFirst_leavingNoTestProcess() throws {
        let mutator = try startSwiftMutator(hangingIn: .mutantsWithALargeWorkerClone)
        guard waitUntilHanging(runs: 2, in: mutator) else { return }

        signalProcess(mutator, SIGTERM)
        let stopping = waitUntil(within: 5) {
            self.contents(of: self.standardError).contains("Stopping (SIGTERM)") || !mutator.isRunning
        }
        XCTAssertTrue(stopping, "SwiftMutator didn't say it was stopping")
        guard mutator.isRunning else {
            assertDied(mutator, by: SIGTERM)
            assertNoTestProcessIsLeft()
            throw XCTSkip("SwiftMutator stopped before a second signal could reach it")
        }
        signalProcess(mutator, SIGINT)

        assertDied(mutator, by: SIGTERM)
        assertNoTestProcessIsLeft()
        let errors = contents(of: standardError)
        XCTAssertTrue(errors.contains("Stopping at once"), errors)
    }

    // When its terminal closes, zsh sends the job SIGHUP twice, about a millisecond apart. The second comes here once
    // SwiftMutator has said it is stopping, so that it is handled on its own, while a large worker clone is removed.
    func test_aRepeatedHangup_stillStopsCleanly_andDiesBySIGHUP() throws {
        let mutator = try startSwiftMutator(hangingIn: .mutantsWithALargeWorkerClone)
        guard waitUntilHanging(runs: 2, in: mutator) else { return }

        signalGroup(of: mutator, SIGHUP)
        let stopping = waitUntil(within: 5) {
            self.contents(of: self.standardError).contains("Stopping (SIGHUP)") || !mutator.isRunning
        }
        XCTAssertTrue(stopping, "SwiftMutator didn't say it was stopping")
        let repeated = mutator.isRunning
        if repeated { signalGroup(of: mutator, SIGHUP) }

        assertDied(mutator, by: SIGHUP)
        assertNoTestProcessIsLeft()
        let errors = contents(of: standardError)
        XCTAssertFalse(errors.contains("Stopping at once"), errors)
        let files = resultsFiles()
        XCTAssertEqual(files.count, 1, "\(files)")
        if let file = files.first {
            let lines = try records(in: file)
            XCTAssertEqual(lines.last?["kind"] as? String, "end")
            XCTAssertEqual(lines.last?["reason"] as? String, "interrupted")
            XCTAssertEqual(lines.last?["detail"] as? String, "SIGHUP")
        }
        XCTAssertFalse(exists("project_mutated_worker1"), "the worker clone is removed")
        guard repeated else { throw XCTSkip("SwiftMutator stopped before a second SIGHUP could reach it") }
    }

    // `nohup` starts SwiftMutator with SIGHUP ignored, so that a run outlives the terminal it started in.
    func test_aHangupIgnoredAtStart_staysIgnored_andSIGTERMStillStops() throws {
        let mutator = try startSwiftMutator(hangingIn: .mutants, underNohup: true)
        guard waitUntilHanging(runs: 2, in: mutator) else { return }

        signalGroup(of: mutator, SIGHUP)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(mutator.isRunning, "SIGHUP stopped a run started under nohup")
        let testProcesses = shells.union(sleepers)
        XCTAssertEqual(testProcesses.filter(isGone).sorted(), [], "test processes ended by SIGHUP")
        signalProcess(mutator, SIGTERM)

        assertDied(mutator, by: SIGTERM)
        assertNoTestProcessIsLeft()
    }

    // MARK: - Helpers

    /// Starts SwiftMutator on the project, with the test command hanging in `phase`. Foundation.Process starts it in
    /// a process group of its own; `nohup` execs it, so it keeps that process and group.
    private func startSwiftMutator(
        hangingIn phase: Phase,
        standardOutput output: Pipe? = nil,
        underNohup: Bool = false
    ) throws -> Foundation.Process {
        let process = Foundation.Process()
        var arguments = ["run", "--skip-update-check"] + (phase == .coverage ? [] : ["--skip-coverage"])
        if underNohup {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            arguments.insert(swiftMutator.path, at: 0)
        } else {
            process.executableURL = swiftMutator
        }
        process.arguments = arguments
        process.currentDirectoryURL = project
        var environment = ProcessInfo.processInfo.environment
        environment["INTERRUPT_TEST_MARKERS"] = markers.path
        environment["INTERRUPT_TEST_PHASE"] = phase.rawValue
        process.environment = environment

        FileManager.default.createFile(atPath: standardOutput.path, contents: nil)
        FileManager.default.createFile(atPath: standardError.path, contents: nil)
        let outputFile = try FileHandle(forWritingTo: standardOutput)
        let errorFile = try FileHandle(forWritingTo: standardError)
        defer {
            try? outputFile.close()
            try? errorFile.close()
        }
        process.standardOutput = output ?? outputFile
        process.standardError = errorFile
        try process.run()
        mutator = process
        return process
    }

    /// Waits until the test command hangs in `runs` places, each with its `sleep` started, and SwiftMutator still
    /// runs.
    private func waitUntilHanging(
        runs: Int,
        in mutator: Foundation.Process,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let hanging = waitUntil(within: 30) {
            self.recordMarkers()
            return self.sleepers.count >= runs || !mutator.isRunning
        }
        guard hanging, mutator.isRunning, sleepers.count >= runs else {
            XCTFail(
                """
                The test command didn't hang in \(runs) runs: \(sleepers.count) hung, SwiftMutator \
                \(mutator.isRunning ? "is still running" : "ended (\(describe(mutator)))").
                Standard error: \(contents(of: standardError))
                """,
                file: file,
                line: line
            )
            return false
        }
        return true
    }

    /// As a terminal's Ctrl-C, or a hangup a shell forwards: the group holds SwiftMutator alone, since each process
    /// SwiftMutator starts leads a group of its own.
    private func signalGroup(of mutator: Foundation.Process, _ signal: Int32) {
        let pid = mutator.processIdentifier
        guard pid > 1, mutator.isRunning else { return XCTFail("SwiftMutator isn't running") }
        kill(-pid, signal)
    }

    private func signalProcess(_ mutator: Foundation.Process, _ signal: Int32) {
        let pid = mutator.processIdentifier
        guard pid > 1, mutator.isRunning else { return XCTFail("SwiftMutator isn't running") }
        kill(pid, signal)
    }

    /// That SwiftMutator ended within `timeout` seconds, killed by `signal`, as its default action would have, so that
    /// a shell sees it die of the signal.
    private func assertDied(
        _ mutator: Foundation.Process,
        by signal: Int32,
        within timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard waitUntil(within: timeout, { !mutator.isRunning }) else {
            return XCTFail("SwiftMutator was still running after \(timeout) s", file: file, line: line)
        }
        XCTAssertEqual(
            describe(mutator),
            "killed by signal \(signal)",
            contents(of: standardError),
            file: file,
            line: line
        )
    }

    private func describe(_ ended: Foundation.Process) -> String {
        ended.terminationReason == .uncaughtSignal
            ? "killed by signal \(ended.terminationStatus)"
            : "exited with \(ended.terminationStatus)"
    }

    /// That every process the test command wrote down is gone within 2 seconds.
    private func assertNoTestProcessIsLeft(file: StaticString = #filePath, line: UInt = #line) {
        recordMarkers()
        let testProcesses = shells.union(sleepers)
        XCTAssertFalse(testProcesses.isEmpty, "no test process was written down", file: file, line: line)
        _ = waitUntil(within: 2) { testProcesses.allSatisfy(self.isGone) }
        XCTAssertEqual(testProcesses.filter { !isGone($0) }.sorted(), [], "still running", file: file, line: line)
    }

    /// Reads the processes the test command wrote down. Each is named in its file's name, which is there before the
    /// file's contents are.
    private func recordMarkers() {
        guard let markers else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: markers.path)) ?? []
        for name in names {
            let parts = name.split(separator: ".")
            guard parts.count == 2, let pid = Int32(parts[1]), pid > 1 else { continue }
            if parts[0] == "sh" {
                shells.insert(pid)
            } else if parts[0] == "sleep" {
                sleepers.insert(pid)
            }
        }
    }

    /// Whether no process has this ID.
    private func isGone(_ pid: Int32) -> Bool {
        if confirmedGone.contains(pid) { return true }
        guard kill(pid, 0) == -1, errno == ESRCH else { return false }
        confirmedGone.insert(pid)
        return true
    }

    /// Each results file the run wrote, in `project_muter_logs/<run>/`.
    private func resultsFiles() -> [URL] {
        let logs = root.appendingPathComponent("project_muter_logs", isDirectory: true)
        let runs = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        return runs.flatMap { run in
            ((try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("results") && $0.pathExtension == "jsonl" }
        }
    }

    private func records(in file: URL) throws -> [[String: Any]] {
        try contents(of: file)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    private func contents(of file: URL) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    /// Polls `condition` until it holds or `timeout` seconds pass, and returns whether it held.
    private func waitUntil(within timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}
