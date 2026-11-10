@testable import muterCore
import XCTest

/// `ResumeAcceptanceTests`' project, whose test command hangs in each mutant of Checks.swift while a marker exists,
/// and the processes a test starts on it, which `cleanUp()` kills however the test ended.
final class ResumeHarness {

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
    }

    struct RanOver: Error, CustomStringConvertible {
        let arguments: [String]
        var description: String { "\(arguments.joined(separator: " ")) ran over 120 s, so it was killed" }
    }

    struct DidNotHang: Error, CustomStringConvertible {
        let description: String
    }

    /// The `swift-mutator` that `swift test` builds next to the test bundle.
    private var swiftMutator: URL {
        get throws { try XCTUnwrap(BuildProducts.folder).appendingPathComponent("swift-mutator") }
    }
    /// The test's temporary folder, which holds the project and what the test writes.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ResumeAcceptanceTests-\(UUID().uuidString)", isDirectory: true)
    var project: URL { root.appendingPathComponent("project", isDirectory: true) }
    private var markers: URL { root.appendingPathComponent("markers", isDirectory: true) }
    var hangMarker: URL { markers.appendingPathComponent("hang") }
    /// The JSON report each run writes, outside the project, so that it is never one of the project's files.
    var report: URL { root.appendingPathComponent("report.json") }
    /// How the first session is started, which the command that continues it repeats.
    var firstSessionArguments: [String] {
        ["run", "--skip-update-check", "--skip-coverage", "-f", "json", "-o", report.path]
    }

    /// Every process a test started, the shell that runs a printed command among them.
    private var started: [Foundation.Process] = []
    private var processCount = 0
    /// The processes the test command wrote down, once seen. One confirmed gone is never signalled again: the
    /// system may give its ID to another process.
    private var shells: Set<Int32> = []
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
        // The comparisons are `!=`, which only RelationalOperatorReplacement mutates, in closures that use `$0` nowhere
        // else, where it gives only its swap: four mutants in all. Elsewhere it would replace each with two constants,
        // and `<` or `>` would get a RelationalBoundary mutant too. The configuration leaves out ReplaceBooleanValue,
        // which would add two for each function.
        try """
        func isSmall(_ values: [Int]) -> Bool { values.contains { $0 != 10 } }
        func isHuge(_ values: [Int]) -> Bool { values.contains { $0 != 100 } }

        """.write(to: sources.appendingPathComponent("Bounds.swift"), atomically: true, encoding: .utf8)
        try """
        func isPositive(_ values: [Int]) -> Bool { values.contains { $0 != 0 } }
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
        skipOperators: [ReplaceBooleanValue]

        """.write(to: project.appendingPathComponent("muter.conf.yml"), atomically: true, encoding: .utf8)
    }

    /// Kills every process the test started that still runs, and removes the temporary folder.
    func cleanUp() {
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
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs the first session with the test command hanging in the Checks mutants, stops it with SIGINT once it hangs
    /// in the first, and returns its results file and the command its summary printed to continue it. That command
    /// repeats how the session was started, and names the results file, in the words `wordsAShellReads` finds in it.
    func stopTheFirstSession(
        splittingWith wordsAShellReads: (String) throws -> [String],
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
        let words = try wordsAShellReads(continueCommand)
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

    func createHangMarker() throws {
        try "".write(to: hangMarker, atomically: true, encoding: .utf8)
    }

    /// Starts `swift-mutator` with `arguments` in the project's folder. Foundation.Process starts it in a process group
    /// of its own.
    func launch(_ arguments: [String]) throws -> Launched {
        try launch(executable: swiftMutator, arguments: arguments)
    }

    /// Runs `commandLine`, as a summary printed it, in a shell whose `swift-mutator` is this build: a link to it in a
    /// folder first on the shell's PATH. macOS's `/bin/sh` is bash in POSIX mode, which takes no `swift-mutator` as a
    /// function's name. The shell execs it, so that SwiftMutator keeps the shell's process, and the group
    /// Foundation.Process started it in.
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
            path: commands.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        )
    }

    func launch(executable: URL, arguments: [String], path: String? = nil) throws -> Launched {
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
    func recordMarkers() {
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
    func isGone(_ pid: Int32) -> Bool {
        if confirmedGone.contains(pid) { return true }
        guard kill(pid, 0) == -1, errno == ESRCH else { return false }
        confirmedGone.insert(pid)
        return true
    }

    /// What each run of the test command wrote down, in order: its active mutant, or `baseline`.
    func ranLines() -> [String] {
        contents(of: markers.appendingPathComponent("ran")).split(separator: "\n").map(String.init)
    }
}
