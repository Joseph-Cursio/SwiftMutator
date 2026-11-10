import XCTest

/// `InterruptionAcceptanceTests`' project, whose test command hangs where a test asks, the SwiftMutator a test starts
/// on it, and the test processes that SwiftMutator starts, which `cleanUp()` kills however the test ended.
final class InterruptionHarness {

    /// The `swift-mutator` that `swift test` builds next to the test bundle.
    private var swiftMutator: URL {
        get throws { try XCTUnwrap(BuildProducts.folder).appendingPathComponent("swift-mutator") }
    }
    /// The test's temporary folder, which holds the project and what the test writes.
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("InterruptionAcceptanceTests-\(UUID().uuidString)", isDirectory: true)
    private var project: URL { root.appendingPathComponent("project", isDirectory: true) }
    private var markers: URL { root.appendingPathComponent("markers", isDirectory: true) }
    var standardOutput: URL { root.appendingPathComponent("stdout.txt") }
    var standardError: URL { root.appendingPathComponent("stderr.txt") }
    /// The SwiftMutator a test started.
    private var mutator: Foundation.Process?
    /// The processes the test command wrote down, once seen. One confirmed gone is never signalled again: the
    /// system may give its ID to another process.
    var shells: Set<Int32> = []
    var sleepers: Set<Int32> = []
    private var confirmedGone: Set<Int32> = []

    /// Writes the project and its configuration, or skips the test where there is no `swift-mutator` to run.
    func create() throws {
        guard try FileManager.default.isExecutableFile(atPath: swiftMutator.path) else {
            throw XCTSkip("No swift-mutator next to the test bundle, which `swift test` builds")
        }

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

    /// Kills every process the test started that still runs, and removes the temporary folder.
    func cleanUp() {
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
        try? FileManager.default.removeItem(at: root)
    }

    /// Starts SwiftMutator on the project, with the test command hanging in `phase`. Foundation.Process starts it in
    /// a process group of its own; `nohup` execs it, so it keeps that process and group.
    func startSwiftMutator(
        hangingIn phase: Phase,
        standardOutput output: Pipe? = nil,
        underNohup: Bool = false
    ) throws -> Foundation.Process {
        let process = Foundation.Process()
        var arguments = ["run", "--skip-update-check"] + (phase == .coverage ? [] : ["--skip-coverage"])
        if underNohup {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            try arguments.insert(swiftMutator.path, at: 0)
        } else {
            process.executableURL = try swiftMutator
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
    func waitUntilHanging(
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

    /// Sets the project's `mutationTestTimeout` to `seconds`.
    func setTimeLimit(_ seconds: Int) throws {
        let configuration = project.appendingPathComponent("muter.conf.yml")
        let text = try String(contentsOf: configuration, encoding: .utf8)
        XCTAssertTrue(text.contains("mutationTestTimeout: 600"))
        try text.replacingOccurrences(of: "mutationTestTimeout: 600", with: "mutationTestTimeout: \(seconds)")
            .write(to: configuration, atomically: true, encoding: .utf8)
    }

    /// That SwiftMutator ended within `timeout` seconds, killed by `signal`, as its default action would have, so that
    /// a shell sees it die of the signal.
    func assertDied(
        _ mutator: Foundation.Process,
        by signal: Int32,
        within timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard waitUntil(within: timeout, { !mutator.isRunning }) else {
            XCTFail("SwiftMutator was still running after \(timeout) s", file: file, line: line)
            return
        }
        XCTAssertEqual(
            describe(mutator),
            "killed by signal \(signal)",
            contents(of: standardError),
            file: file,
            line: line
        )
    }

    /// That every process the test command wrote down is gone within 2 seconds.
    func assertNoTestProcessIsLeft(file: StaticString = #filePath, line: UInt = #line) {
        recordMarkers()
        let testProcesses = shells.union(sleepers)
        XCTAssertFalse(testProcesses.isEmpty, "no test process was written down", file: file, line: line)
        _ = waitUntil(within: 2) { testProcesses.allSatisfy(self.isGone) }
        XCTAssertEqual(testProcesses.filter { !isGone($0) }.sorted(), [], "still running", file: file, line: line)
    }

    /// Reads the processes the test command wrote down. Each is named in its file's name, which is there before the
    /// file's contents are.
    private func recordMarkers() {
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

    /// The processes the test command wrote down less than `seconds` before `moment`, by their files' times.
    func testProcesses(writtenDownWithin seconds: TimeInterval, before moment: Date) -> Set<Int32> {
        recordMarkers()
        let writtenDown = { (kind: String, pid: Int32) -> Bool in
            let file = self.markers.appendingPathComponent("\(kind).\(pid)").path
            guard let time = try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date
            else { return false }
            return moment.timeIntervalSince(time) < seconds
        }
        return shells.filter { writtenDown("sh", $0) }.union(sleepers.filter { writtenDown("sleep", $0) })
    }

    /// Whether no process has this ID.
    func isGone(_ pid: Int32) -> Bool {
        if confirmedGone.contains(pid) { return true }
        guard kill(pid, 0) == -1, errno == ESRCH else { return false }
        confirmedGone.insert(pid)
        return true
    }

    /// That the run wrote one results file, whose one end line, its last, says a signal named `signal` interrupted it.
    func assertTheResultsEnd(
        interruptedBy signal: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let files = resultsFiles()
        XCTAssertEqual(files.count, 1, "\(files)", file: file, line: line)
        guard let results = files.first else { return }
        let lines = try records(in: results)
        XCTAssertEqual(lines.filter { $0["kind"] as? String == "end" }.count, 1, "\(lines)", file: file, line: line)
        XCTAssertEqual(lines.last?["kind"] as? String, "end", file: file, line: line)
        XCTAssertEqual(lines.last?["reason"] as? String, "interrupted", file: file, line: line)
        XCTAssertEqual(lines.last?["detail"] as? String, signal, file: file, line: line)
    }

    /// Each results file the run wrote, in `project_muter_logs/<run>/`.
    func resultsFiles() -> [URL] {
        let logs = root.appendingPathComponent("project_muter_logs", isDirectory: true)
        let runs = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        return runs.flatMap { run in
            ((try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("results") && $0.pathExtension == "jsonl" }
        }
    }

    /// The records of the runs that stopped before their first mutant, each the only line of its results file.
    func stoppedRecords() throws -> [[String: Any]] {
        try resultsFiles().map { file in
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(lines.count, 1, "\(file.path): \(lines)")
            let record = try JSONSerialization.jsonObject(with: Data((lines.first ?? "").utf8))
            return record as? [String: Any] ?? [:]
        }
    }

    /// The files in `project_muter_logs/<run>/running/`: the output of the test runs a stop cut short.
    func runningFiles() -> [String] {
        let logs = root.appendingPathComponent("project_muter_logs", isDirectory: true)
        let runs = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        return runs.flatMap { run in
            (try? FileManager.default.contentsOfDirectory(atPath: run.appendingPathComponent("running").path)) ?? []
        }
    }

    /// The names at the top of the mutated project that the project doesn't have, hidden ones left out.
    func visibleNamesAddedToTheCopy() -> [String] {
        let names = { (folder: URL) -> Set<String> in
            let all = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return Set(all.filter { !$0.hasPrefix(".") })
        }
        return names(root.appendingPathComponent("project_mutated.noindex")).subtracting(names(project)).sorted()
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }
}
