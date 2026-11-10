@testable import muterCore
import XCTest

/// `TestPlanAcceptanceTests`' project, whose test command hangs in each mutant of Checks.swift while a marker exists,
/// and the processes a test starts on it, which `cleanUp()` kills however the test ended.
final class TestPlanHarness {
    /// Writes down the active mutant of each run, or `baseline` for a run with none. Kills the mutants in Checks.swift,
    /// but first hangs in each while the `hang` marker exists, writing down its own ID and its `sleep`'s. The mutants
    /// in Bounds.swift survive, and the baseline passes.
    private static let testCommand = """
        mutant=$(head -n 1 "$SWIFTMUTATOR_ACTIVE_MUTANT_FILE" 2>/dev/null)
        echo "${mutant:-baseline}" >> "$PLAN_TEST_MARKERS/ran"
        case "$mutant" in
            Checks_*)
                if [ -e "$PLAN_TEST_MARKERS/hang" ]; then
                    echo $$ > "$PLAN_TEST_MARKERS/sh.$$"
                    /bin/sleep 60.9 & echo $! > "$PLAN_TEST_MARKERS/sleep.$!"
                    wait
                fi
                echo "✘ Test check() recorded an issue at ChecksTests.swift:3:5: Expectation failed"
                echo "✘ Test run with 1 test failed after 0.001 seconds with 1 issue."
                exit 1;;
        esac
        exit 0
        """

    /// A SwiftMutator a test started, and the files its standard output and standard error go to.
    struct Launched {
        let process: Foundation.Process
        let standardOutput: URL
        let standardError: URL
    }

    /// What an ended `swift-mutator` gave.
    struct Ended {
        let status: Int32
        let standardOutput: String
        let standardError: String

        /// Both, for a failure's message.
        var output: String {
            standardError + standardOutput
        }
    }

    struct DidNotHang: Error, CustomStringConvertible {
        let description: String
    }

    struct RanOver: Error, CustomStringConvertible {
        let arguments: [String]
        var description: String { "\(arguments.joined(separator: " ")) ran over 120 s, so it was killed" }
    }

    /// The `swift-mutator` that `swift test` builds next to the test bundle.
    private var swiftMutator: URL {
        get throws { try XCTUnwrap(BuildProducts.folder).appendingPathComponent("swift-mutator") }
    }
    /// The test's temporary folder, which holds the project and what the test writes.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TestPlanAcceptanceTests-\(UUID().uuidString)", isDirectory: true)
    var project: URL { root.appendingPathComponent("project", isDirectory: true) }
    private var markers: URL { root.appendingPathComponent("markers", isDirectory: true) }
    var hangMarker: URL { markers.appendingPathComponent("hang") }
    var plan: URL { project.appendingPathComponent("muter-mappings.json") }
    var copy: URL { root.appendingPathComponent("project_mutated.noindex", isDirectory: true) }
    let makePlan = ["mutate-without-running", "--skip-update-check", "--skip-coverage"]
    let testPlan = ["run-without-mutating", "--skip-update-check", "muter-mappings.json"]

    /// Every process a test started, the shell that runs a printed command among them.
    private var started: [Foundation.Process] = []
    private var processCount = 0
    /// The processes the test command wrote down.
    private var shells: Set<Int32> = []
    private var sleepers: Set<Int32> = []

    /// The project's configuration, which runs `testCommand` with `/bin/sh`.
    static var configuration: String {
        let script = testCommand
            .split(separator: "\n")
            .map { "    " + $0 }
            .joined(separator: "\n")
        return """
        executable: /bin/sh
        arguments:
          - "-c"
          - |
        \(script)
        buildSystem: swift
        mutationTestWorkers: 1
        mutationTestTimeout: 600
        skipOperators: [ReplaceBooleanValue]

        """
    }

    /// Writes the project and its configuration, or skips the test where there is no `swift-mutator` to run.
    func create() throws {
        guard try FileManager.default.isExecutableFile(atPath: swiftMutator.path) else {
            throw XCTSkip("No swift-mutator next to the test bundle, which `swift test` builds")
        }

        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        // The comparisons are `!=`, which only RelationalOperatorReplacement mutates, in closures that use `$0` nowhere
        // else, where it gives only its swap: four mutants in all. Elsewhere it would replace each with two constants,
        // and `<` or `>` would get a RelationalBoundary mutant too. The configuration leaves out ReplaceBooleanValue,
        // which would add two for each function.
        try write(
            """
            func isSmall(_ values: [Int]) -> Bool { values.contains { $0 != 10 } }
            func isHuge(_ values: [Int]) -> Bool { values.contains { $0 != 100 } }

            """,
            to: "Sources/Lib/Bounds.swift"
        )
        try write(
            """
            func isPositive(_ values: [Int]) -> Bool { values.contains { $0 != 0 } }
            func both(_ first: Bool, _ second: Bool) -> Bool { first && second }

            """,
            to: "Sources/Lib/Checks.swift"
        )
        try write(Self.configuration, to: "muter.conf.yml")
    }

    /// Kills every process the test started that still runs, and removes the temporary folder.
    func cleanUp() {
        for process in started where process.isRunning {
            let pid = process.processIdentifier
            if pid > 1 { kill(-pid, SIGKILL) } // its own group, which holds that SwiftMutator alone
            _ = waitUntil(within: 5) { !process.isRunning }
        }
        recordMarkers()
        // Each shell leads the process group SwiftMutator started it in, which holds its `sleep` too.
        for shell in shells where shell > 1 {
            kill(-shell, SIGKILL)
        }
        for sleeper in sleepers where sleeper > 1 {
            kill(sleeper, SIGKILL)
        }
        try? FileManager.default.removeItem(at: root)
    }

    func makeThePlan(file: StaticString = #filePath, line: UInt = #line) throws {
        let made = try waitForEnd(of: launch(makePlan))
        XCTAssertEqual(made.status, 0, made.output, file: file, line: line)
    }

    /// Adds a comment to the end of `path` in the plan's copy, as a fix by hand might, and returns the file's new
    /// SHA-256.
    @discardableResult
    func fixByHand(_ path: String) throws -> String {
        let file = copy.appendingPathComponent(path)
        let fixed = contents(of: file) + "// fixed by hand\n"
        try fixed.write(to: file, atomically: true, encoding: .utf8)
        return FileDigest.sha256(of: Data(fixed.utf8))
    }

    func write(_ text: String, to path: String) throws {
        let file = project.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Starts `swift-mutator` with `arguments` in `folder`, by default the project's. Foundation.Process starts it in a
    /// process group of its own.
    func launch(_ arguments: [String], in folder: URL? = nil) throws -> Launched {
        try launch(executable: swiftMutator, arguments: arguments, in: folder ?? project)
    }

    /// Runs `commandLine`, as a summary printed it, in a shell whose `swift-mutator` is this build: a link to it in a
    /// folder first on the shell's PATH. The shell execs it, so that SwiftMutator keeps the shell's process, and the
    /// group Foundation.Process started it in.
    func launch(commandLine: String) throws -> Launched {
        let commands = root.appendingPathComponent("bin", isDirectory: true)
        let link = commands.appendingPathComponent("swift-mutator")
        if !FileManager.default.fileExists(atPath: link.path) {
            try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: swiftMutator)
        }
        return try launch(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec " + commandLine],
            in: project,
            path: commands.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        )
    }

    func launch(executable: URL, arguments: [String], in folder: URL, path: String? = nil) throws -> Launched {
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
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PLAN_TEST_MARKERS"] = markers.path
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

    /// Waits up to 120 seconds for `launched` to end. One still running then is killed, with its process group, and the
    /// test fails.
    func waitForEnd(of launched: Launched) throws -> Ended {
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
    func waitUntilHanging(_ launched: Launched) throws {
        let process = launched.process
        _ = waitUntil(within: 60) {
            self.recordMarkers()
            return !self.sleepers.isEmpty || !process.isRunning
        }
        guard process.isRunning, !sleepers.isEmpty else {
            throw DidNotHang(description: "The test command didn't hang: \(contents(of: launched.standardError))")
        }
    }

    /// Reads the processes the test command wrote down, each named in its file's name.
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

    /// What each run of the test command wrote down, in order: its active mutant, or `baseline`.
    func ranLines() -> [String] {
        contents(of: markers.appendingPathComponent("ran")).split(separator: "\n").map(String.init)
    }

    /// The run's results file, in `project_muter_logs/<run>/`, which a test expects to be the only one.
    func onlyResultsFile(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let logs = root.appendingPathComponent("project_muter_logs", isDirectory: true)
        let runs = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        let files = runs.flatMap { run in
            ((try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("results") && $0.pathExtension == "jsonl" }
        }
        XCTAssertEqual(files.count, 1, "\(files)", file: file, line: line)
        return try XCTUnwrap(files.first, file: file, line: line)
    }

    func records(in file: URL) throws -> [[String: Any]] {
        try contents(of: file)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    func kinds(in file: URL) throws -> [String?] {
        try records(in: file).map { $0["kind"] as? String }
    }

    func contents(of file: URL) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    /// Polls `condition` until it holds or `timeout` seconds pass, and returns whether it held.
    func waitUntil(within timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}
