import XCTest

/// Runs the built `swift-mutator` on a two-file project whose test command is a shell script, stops a run partway with
/// a real SIGINT to its process group, which holds that SwiftMutator alone, and continues it with the command its
/// summary printed, run by a shell as it would be pasted. Every process a test starts is killed however the test ends,
/// every wait is bounded, and every file a test writes is in a temporary folder.
final class ResumeAcceptanceTests: XCTestCase {
    /// Writes down the active mutant of each run, or `baseline` for a run with none. Kills the mutants in Checks.swift,
    /// printing the line Swift Testing ends a failed run with, but first hangs in each while the `hang` marker exists:
    /// it writes down its own ID, starts a `sleep` whose odd length makes one left behind easy to find, writes down
    /// that ID too, and waits. The mutants in Bounds.swift survive, and the baseline passes.
    private static let testCommand = """
        mutant=$(cat "$SWIFTMUTATOR_ACTIVE_MUTANT_FILE" 2>/dev/null)
        echo "${mutant:-baseline}" >> "$RESUME_TEST_MARKERS/ran"
        case "$mutant" in
            Checks_*)
                if [ -e "$RESUME_TEST_MARKERS/hang" ]; then
                    echo $$ > "$RESUME_TEST_MARKERS/sh.$$"
                    /bin/sleep 60.7 & echo $! > "$RESUME_TEST_MARKERS/sleep.$!"
                    wait
                fi
                echo "✘ Test run with 1 test failed after 0.001 seconds with 1 issue."
                exit 1;;
        esac
        exit 0
        """

    /// A SwiftMutator a test started, and the files its standard output and standard error go to.
    private struct Launched {
        let process: Foundation.Process
        let standardOutput: URL
        let standardError: URL
    }

    /// What an ended `swift-mutator` gave.
    private struct Ended {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    private struct RanOver: Error, CustomStringConvertible {
        let arguments: [String]
        var description: String { "\(arguments.joined(separator: " ")) ran over 120 s, so it was killed" }
    }

    private struct DidNotHang: Error, CustomStringConvertible {
        let description: String
    }

    private var swiftMutator: URL!
    private var root: URL!
    private var project: URL!
    private var markers: URL!
    private var hangMarker: URL { markers.appendingPathComponent("hang") }
    /// The JSON report each run writes, outside the project, so that it is never one of the project's files.
    private var report: URL { root.appendingPathComponent("report.json") }
    /// How the first session is started, which the command that continues it repeats.
    private var firstSessionArguments: [String] {
        ["run", "--skip-update-check", "--skip-coverage", "-f", "json", "-o", report.path]
    }

    /// Every process a test started, the shell that runs a printed command among them.
    private var started: [Foundation.Process] = []
    private var processCount = 0
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
            .appendingPathComponent("ResumeAcceptanceTests-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        markers = root.appendingPathComponent("markers", isDirectory: true)
        let sources = project.appendingPathComponent("Sources/Lib", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        try """
        func isSmall(_ value: Int) -> Bool { value < 10 }
        func isHuge(_ value: Int) -> Bool { value > 100 }

        """.write(to: sources.appendingPathComponent("Bounds.swift"), atomically: true, encoding: .utf8)
        try """
        func isPositive(_ value: Int) -> Bool { value > 0 }
        func both(_ first: Bool, _ second: Bool) -> Bool { first && second }

        """.write(to: sources.appendingPathComponent("Checks.swift"), atomically: true, encoding: .utf8)
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
        mutationTestWorkers: 1
        mutationTestTimeout: 600

        """.write(to: project.appendingPathComponent("muter.conf.yml"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        var killedOne = false
        for process in started where process.isRunning {
            let pid = process.processIdentifier
            if pid > 1 { kill(-pid, SIGKILL) } // its own group, which holds that SwiftMutator alone
            _ = waitUntil(within: 5) { !process.isRunning }
            killedOne = true
        }
        if killedOne {
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

    func test_aStoppedRun_resumes_testingOnlyWhatIsLeft_andReportsLikeAFullRun() throws {
        let (resultsFile, continueCommand) = try stopTheFirstSession()
        let ranBefore = ranLines()
        try FileManager.default.removeItem(at: hangMarker)

        let resumed = try waitForEnd(of: launch(commandLine: continueCommand))

        XCTAssertEqual(resumed.status, 0, resumed.standardError + resumed.standardOutput)
        let lines = try records(in: resultsFile)
        XCTAssertEqual(
            lines.map { $0["kind"] as? String },
            ["header", "mutant", "mutant", "end", "header", "mutant", "mutant", "end"]
        )
        let header = try XCTUnwrap(lines.dropFirst(4).first)
        XCTAssertEqual(header["session"] as? Int, 2)
        XCTAssertEqual(header["formatVersion"] as? Int, 2)
        XCTAssertEqual(header["mutantsReused"] as? Int, 2)
        XCTAssertEqual(header["mutantsToTest"] as? Int, 2)
        XCTAssertEqual(header["mutantsDiscovered"] as? Int, 4)
        // Only the Checks mutants, which the first session never finished, ran again, after a baseline of their own.
        let tested = lines.dropFirst(4)
            .filter { $0["kind"] as? String == "mutant" }
            .compactMap { $0["switchID"] as? String }
        XCTAssertEqual(tested.count, 2, "\(tested)")
        XCTAssertEqual(Set(tested).count, tested.count, "\(tested)")
        XCTAssertTrue(tested.allSatisfy { $0.hasPrefix("Checks_") }, "\(tested)")
        XCTAssertEqual(Array(ranLines().dropFirst(ranBefore.count)), ["baseline"] + tested)
        XCTAssertEqual(ranBefore.last, tested.first, "the first session hung in the first Checks mutant")

        XCTAssertEqual(try outcomes(inJSONReportAt: report), ["failed", "failed", "passed", "passed"])
        let rebuilt = try waitForEnd(of: launch(["report", resultsFile.path, "-f", "json"]))
        XCTAssertEqual(rebuilt.status, 0, rebuilt.standardError)
        let rebuiltReport = try JSONSerialization.jsonObject(with: Data(rebuilt.standardOutput.utf8)) as? NSDictionary
        XCTAssertEqual(rebuiltReport, try parsedJSON(at: report))
        XCTAssertEqual(workerClones(), [], "no worker clone is left")
    }

    func test_aResumeOfAFileInUse_isRefused_beforeTheLiveRunsCopyIsTouched() throws {
        try createHangMarker()
        let first = try launch(firstSessionArguments)
        try waitUntilHanging(first)
        let resultsFile = try onlyResultsFile()

        let refused = try waitForEnd(of: launch(firstSessionArguments + ["--resume", resultsFile.path]))

        XCTAssertEqual(refused.status, 255, refused.standardError + refused.standardOutput)
        XCTAssertTrue(refused.standardOutput.contains("holds its lock"), refused.standardOutput)
        XCTAssertTrue(
            refused.standardOutput.contains("by process \(first.process.processIdentifier) "),
            refused.standardOutput
        )
        XCTAssertTrue(first.process.isRunning, "the refused resume stopped the run it found holding the file")
        recordMarkers()
        XCTAssertEqual(sleepers.filter(isGone).sorted(), [], "the hanging test process ended")
        XCTAssertTrue(exists("project_mutated/.swiftmutator-active-mutant"), "the live run's copy was touched")

        signalGroup(of: first, SIGINT)

        assertDied(first, by: SIGINT)
        assertNoTestProcessIsLeft()
    }

    func test_aChangedProjectFile_refusesBeforeTheCopy_andResumeIgnoringLetsItThrough() throws {
        let (resultsFile, continueCommand) = try stopTheFirstSession()
        try FileManager.default.removeItem(at: hangMarker)
        try "Not read by any test.\n".write(
            to: project.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )
        let copyMarker = root.appendingPathComponent("project_mutated/left-by-the-test")
        try "".write(to: copyMarker, atomically: true, encoding: .utf8)

        let refused = try waitForEnd(of: launch(commandLine: continueCommand))

        XCTAssertEqual(refused.status, 255, refused.standardError + refused.standardOutput)
        XCTAssertTrue(refused.standardOutput.contains("notes.txt (added)"), refused.standardOutput)
        XCTAssertTrue(refused.standardOutput.contains("--resume-ignoring 'notes.txt'"), refused.standardOutput)
        XCTAssertTrue(refused.standardOutput.contains("Nothing was copied or removed."), refused.standardOutput)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyMarker.path), "the last run's copy was touched")
        XCTAssertEqual(try kinds(in: resultsFile), ["header", "mutant", "mutant", "end"], "the refusal wrote a line")

        let waived = try waitForEnd(of: launch(commandLine: continueCommand + " --resume-ignoring notes.txt"))

        XCTAssertEqual(waived.status, 0, waived.standardError + waived.standardOutput)
        let lines = try records(in: resultsFile)
        XCTAssertEqual(
            lines.map { $0["kind"] as? String },
            ["header", "mutant", "mutant", "end", "header", "mutant", "mutant", "end"]
        )
        let header = try XCTUnwrap(lines.dropFirst(4).first)
        XCTAssertEqual(header["waived"] as? [String], ["notes.txt"])
        XCTAssertEqual(header["mutantsReused"] as? Int, 2)
    }

    func test_aFinishedRun_resumes_asANoOp_withoutABaseline() throws {
        let first = try waitForEnd(of: launch(firstSessionArguments))
        XCTAssertEqual(first.status, 0, first.standardError + first.standardOutput)
        let resultsFile = try onlyResultsFile()
        let ranBefore = ranLines()
        XCTAssertEqual(ranBefore.count, 5, "the baseline and 4 mutants: \(ranBefore)")
        // The resume writes the report to the same path, so only one it wrote itself can be checked.
        try FileManager.default.removeItem(at: report)

        let resumed = try waitForEnd(of: launch(firstSessionArguments + ["--resume", resultsFile.path]))

        XCTAssertEqual(resumed.status, 0, resumed.standardError + resumed.standardOutput)
        XCTAssertTrue(resumed.standardOutput.contains("nothing is left to test"), resumed.standardOutput)
        XCTAssertEqual(ranLines(), ranBefore, "neither a baseline nor a mutant ran")
        let lines = try records(in: resultsFile)
        XCTAssertEqual(
            lines.map { $0["kind"] as? String },
            ["header", "mutant", "mutant", "mutant", "mutant", "end", "header", "end"]
        )
        let header = try XCTUnwrap(lines.dropFirst(6).first)
        XCTAssertEqual(header["session"] as? Int, 2)
        XCTAssertEqual(header["mutantsToTest"] as? Int, 0)
        XCTAssertEqual(header["mutantsReused"] as? Int, 4)
        XCTAssertEqual(header["workers"] as? Int, 0)
        XCTAssertEqual(lines.last?["reason"] as? String, "finished")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path), "the resume wrote no report")
        XCTAssertEqual(try outcomes(inJSONReportAt: report), ["failed", "failed", "passed", "passed"])
    }

    // MARK: - Helpers

    /// Runs the first session with the test command hanging in the Checks mutants, stops it with SIGINT once it hangs
    /// in the first, and returns its results file and the command its summary printed to continue it. That command
    /// repeats how the session was started, and names the results file.
    private func stopTheFirstSession(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (resultsFile: URL, continueCommand: String) {
        try createHangMarker()
        let first = try launch(firstSessionArguments)
        try waitUntilHanging(first, file: file, line: line)

        signalGroup(of: first, SIGINT)

        assertDied(first, by: SIGINT, file: file, line: line)
        assertNoTestProcessIsLeft(file: file, line: line)
        let resultsFile = try onlyResultsFile()
        XCTAssertEqual(try kinds(in: resultsFile), ["header", "mutant", "mutant", "end"], file: file, line: line)
        let errors = contents(of: first.standardError)
        let printed = errors.components(separatedBy: "\n").compactMap { errorLine in
            errorLine.range(of: "▶️ Continue: ").map { String(errorLine[$0.upperBound...]) }
        }
        XCTAssertEqual(printed.count, 1, errors, file: file, line: line)
        let continueCommand = try XCTUnwrap(printed.first, errors, file: file, line: line)
        let words = try wordsAShellReads(in: continueCommand)
        XCTAssertEqual(
            Array(words.dropLast()),
            ["swift-mutator"] + firstSessionArguments + ["--resume"],
            continueCommand,
            file: file,
            line: line
        )
        XCTAssertEqual(
            words.last.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            resultsFile.resolvingSymlinksInPath().path,
            continueCommand,
            file: file,
            line: line
        )
        return (resultsFile, continueCommand)
    }

    private func createHangMarker() throws {
        try "".write(to: hangMarker, atomically: true, encoding: .utf8)
    }

    /// Starts `swift-mutator` with `arguments` in the project's folder. Foundation.Process starts it in a process group
    /// of its own.
    private func launch(_ arguments: [String]) throws -> Launched {
        try launch(executable: swiftMutator, arguments: arguments)
    }

    /// Runs `commandLine`, as a summary printed it, in a shell whose `swift-mutator` is this build: a link to it in a
    /// folder first on the shell's PATH. macOS's `/bin/sh` is bash in POSIX mode, which takes no `swift-mutator` as a
    /// function's name. The shell execs it, so that SwiftMutator keeps the shell's process, and the group
    /// Foundation.Process started it in.
    private func launch(commandLine: String) throws -> Launched {
        let commands = root.appendingPathComponent("bin", isDirectory: true)
        let link = commands.appendingPathComponent("swift-mutator")
        if !FileManager.default.fileExists(atPath: link.path) {
            try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: swiftMutator)
        }
        return try launch(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec " + commandLine],
            path: commands.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        )
    }

    private func launch(executable: URL, arguments: [String], path: String? = nil) throws -> Launched {
        processCount += 1
        let outputPath = root.appendingPathComponent("stdout-\(processCount).txt")
        let errorPath = root.appendingPathComponent("stderr-\(processCount).txt")
        FileManager.default.createFile(atPath: outputPath.path, contents: nil)
        FileManager.default.createFile(atPath: errorPath.path, contents: nil)
        let outputFile = try FileHandle(forWritingTo: outputPath)
        let errorFile = try FileHandle(forWritingTo: errorPath)
        defer {
            try? outputFile.close()
            try? errorFile.close()
        }

        let process = Foundation.Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = project
        var environment = ProcessInfo.processInfo.environment
        environment["RESUME_TEST_MARKERS"] = markers.path
        if let path {
            environment["PATH"] = path
        }
        process.environment = environment
        process.standardOutput = outputFile
        process.standardError = errorFile
        try process.run()
        started.append(process)
        return Launched(process: process, standardOutput: outputPath, standardError: errorPath)
    }

    /// Waits up to 120 seconds for `launched` to end. One still running then is killed, with the process group
    /// Foundation.Process started it in, which holds it alone, and the test fails.
    private func waitForEnd(of launched: Launched) throws -> Ended {
        let process = launched.process
        guard waitUntil(within: 120, { !process.isRunning }) else {
            let pid = process.processIdentifier
            if pid > 1 { kill(-pid, SIGKILL) }
            throw RanOver(arguments: process.arguments ?? [])
        }
        process.waitUntilExit()
        return Ended(
            status: process.terminationStatus,
            standardOutput: contents(of: launched.standardOutput),
            standardError: contents(of: launched.standardError)
        )
    }

    /// Waits until the test command hangs, with its `sleep` started, and SwiftMutator still runs.
    private func waitUntilHanging(
        _ launched: Launched,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let process = launched.process
        let hanging = waitUntil(within: 60) {
            self.recordMarkers()
            return !self.sleepers.isEmpty || !process.isRunning
        }
        guard hanging, process.isRunning, !sleepers.isEmpty else {
            let error = DidNotHang(description: """
            The test command didn't hang: SwiftMutator \
            \(process.isRunning ? "is still running" : "ended (\(describe(process)))").
            Standard error: \(contents(of: launched.standardError))
            """)
            XCTFail(error.description, file: file, line: line)
            throw error
        }
    }

    /// As a terminal's Ctrl-C: the group holds SwiftMutator alone, since each process SwiftMutator starts leads a
    /// group of its own.
    private func signalGroup(of launched: Launched, _ signal: Int32) {
        let pid = launched.process.processIdentifier
        guard pid > 1, launched.process.isRunning else { return XCTFail("SwiftMutator isn't running") }
        kill(-pid, signal)
    }

    /// That SwiftMutator ended within 15 seconds, killed by `signal`, as its default action would have, so that a
    /// shell sees it die of the signal.
    private func assertDied(
        _ launched: Launched,
        by signal: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let process = launched.process
        guard waitUntil(within: 15, { !process.isRunning }) else {
            return XCTFail("SwiftMutator was still running after 15 s", file: file, line: line)
        }
        XCTAssertEqual(
            describe(process),
            "killed by signal \(signal)",
            contents(of: launched.standardError),
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

    /// What each run of the test command wrote down, in order: its active mutant, or `baseline`.
    private func ranLines() -> [String] {
        contents(of: markers.appendingPathComponent("ran")).split(separator: "\n").map(String.init)
    }

    /// The run's results file, in `project_muter_logs/<run>/`, which a test expects to be the only one: a resumed
    /// session adds to its file, in whichever log folder it is.
    private func onlyResultsFile(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let logs = root.appendingPathComponent("project_muter_logs", isDirectory: true)
        let runs = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        let files = runs.flatMap { run in
            ((try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("results") && $0.pathExtension == "jsonl" }
        }
        XCTAssertEqual(files.count, 1, "\(files)", file: file, line: line)
        return try XCTUnwrap(files.first, file: file, line: line)
    }

    private func records(in file: URL) throws -> [[String: Any]] {
        try contents(of: file)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    private func kinds(in file: URL) throws -> [String?] {
        try records(in: file).map { $0["kind"] as? String }
    }

    /// The worker clones, `project_mutated_worker<n>`, beside the project.
    private func workerClones() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix("project_mutated_worker") }
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    private func contents(of file: URL) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    /// JSON compared as parsed: JSONEncoder promises no key order.
    private func parsedJSON(at file: URL) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary)
    }

    /// Each mutant's outcome in a JSON report, sorted.
    private func outcomes(inJSONReportAt file: URL) throws -> [String] {
        let fileReports = try XCTUnwrap(parsedJSON(at: file)["fileReports"] as? [[String: Any]])
        return fileReports
            .flatMap { ($0["appliedOperators"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["testSuiteOutcome"] as? String }
            .sorted()
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
