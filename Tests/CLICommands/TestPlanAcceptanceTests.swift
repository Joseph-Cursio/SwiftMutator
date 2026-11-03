@testable import muterCore
import XCTest

/// Runs the built `swift-mutator` on a two-file project whose test command is a shell script, as
/// `ResumeAcceptanceTests` does: makes a test plan with `mutate-without-running`, and tests it with
/// `run-without-mutating`, after changes to the project or to the plan's copy, from another folder, and across a stop
/// with a real SIGINT and the command its summary printed, run by a shell as it would be pasted. Every process a test
/// starts is killed however the test ends, every wait is bounded, and every file a test writes is in a temporary
/// folder.
final class TestPlanAcceptanceTests: XCTestCase {
    /// Writes down the active mutant of each run, or `baseline` for a run with none. Kills the mutants in Checks.swift,
    /// but first hangs in each while the `hang` marker exists, writing down its own ID and its `sleep`'s. The mutants
    /// in Bounds.swift survive, and the baseline passes.
    private static let testCommand = """
        mutant=$(cat "$SWIFTMUTATOR_ACTIVE_MUTANT_FILE" 2>/dev/null)
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

        /// Both, for a failure's message.
        var output: String {
            standardError + standardOutput
        }
    }

    private struct DidNotHang: Error, CustomStringConvertible {
        let description: String
    }

    private struct RanOver: Error, CustomStringConvertible {
        let arguments: [String]
        var description: String { "\(arguments.joined(separator: " ")) ran over 120 s, so it was killed" }
    }

    private var swiftMutator: URL!
    private var root: URL!
    private var project: URL!
    private var markers: URL!
    private var hangMarker: URL { markers.appendingPathComponent("hang") }
    private var plan: URL { project.appendingPathComponent("muter-mappings.json") }
    private var copy: URL { root.appendingPathComponent("project_mutated", isDirectory: true) }
    private let makePlan = ["mutate-without-running", "--skip-update-check", "--skip-coverage"]
    private let testPlan = ["run-without-mutating", "--skip-update-check", "muter-mappings.json"]

    /// Every process a test started, the shell that runs a printed command among them.
    private var started: [Foundation.Process] = []
    private var processCount = 0
    /// The processes the test command wrote down.
    private var shells: Set<Int32> = []
    private var sleepers: Set<Int32> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let products = try XCTUnwrap(BuildProducts.folder)
        swiftMutator = products.appendingPathComponent("swift-mutator")
        guard FileManager.default.isExecutableFile(atPath: swiftMutator.path) else {
            throw XCTSkip("No swift-mutator next to the test bundle, which `swift test` builds")
        }

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestPlanAcceptanceTests-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        markers = root.appendingPathComponent("markers", isDirectory: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        try write(
            """
            func isSmall(_ value: Int) -> Bool { value < 10 }
            func isHuge(_ value: Int) -> Bool { value > 100 }

            """,
            to: "Sources/Lib/Bounds.swift"
        )
        try write(
            """
            func isPositive(_ value: Int) -> Bool { value > 0 }
            func both(_ first: Bool, _ second: Bool) -> Bool { first && second }

            """,
            to: "Sources/Lib/Checks.swift"
        )
        try write(Self.configuration, to: "muter.conf.yml")
    }

    override func tearDownWithError() throws {
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
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Tests

    func test_aPlanMadeTwice_hasTheSameBytes_andItsRunTestsEveryMutant() throws {
        let first = try waitForEnd(of: launch(makePlan))
        XCTAssertEqual(first.status, 0, first.output)
        let firstPlan = try Data(contentsOf: plan)

        let second = try waitForEnd(of: launch(makePlan))

        XCTAssertEqual(second.status, 0, second.output)
        XCTAssertEqual(try Data(contentsOf: plan), firstPlan, "the second plan's bytes differ")

        let tested = try waitForEnd(of: launch(testPlan))

        XCTAssertEqual(tested.status, 0, tested.output)
        XCTAssertEqual(ranLines().filter { $0 != "baseline" }.count, 4, "\(ranLines())")
        let lines = try records(in: onlyResultsFile())
        XCTAssertEqual(lines.map { $0["kind"] as? String }, ["header", "mutant", "mutant", "mutant", "mutant", "end"])
        XCTAssertEqual(lines.first?["usingTestPlan"] as? Bool, true)
        XCTAssertNotNil(lines.first?["testPlan"], "the header records the plan")
    }

    func test_aChangedMutatedSource_isRefusedWith7_andPlanIgnoringLetsItThrough() throws {
        try makeThePlan()
        try write("func isSmall(_ value: Int) -> Bool { value < 12 }\n", to: "Sources/Lib/Bounds.swift")

        let refused = try waitForEnd(of: launch(testPlan))

        XCTAssertEqual(refused.status, 7, refused.output)
        XCTAssertTrue(refused.output.contains("--plan-ignoring 'Sources/Lib/Bounds.swift'"), refused.output)
        XCTAssertTrue(refused.output.contains("Nothing was tested."), refused.output)
        XCTAssertEqual(ranLines(), [], "something was tested")

        let waived = try waitForEnd(of: launch(testPlan + ["--plan-ignoring", "Sources/Lib/Bounds.swift"]))

        XCTAssertEqual(waived.status, 0, waived.output)
        XCTAssertEqual(ranLines().filter { $0 != "baseline" }.count, 4, "\(ranLines())")
    }

    func test_aFixByHandInTheCopy_isSaid_andTestedAsItIs() throws {
        try makeThePlan()
        let fixed = try fixByHand("Sources/Lib/Bounds.swift")

        let tested = try waitForEnd(of: launch(testPlan))

        XCTAssertEqual(tested.status, 0, tested.output)
        XCTAssertTrue(
            tested.output.contains(
                "✏️ 1 file of the plan's copy differs from what `swift-mutator mutate-without-running` wrote, and is "
                    + "tested as it is now: Sources/Lib/Bounds.swift"
            ),
            tested.output
        )
        let lines = try records(in: onlyResultsFile())
        let project = try XCTUnwrap(lines.first?["project"] as? [String: Any])
        XCTAssertEqual((project["files"] as? [String: String])?["Sources/Lib/Bounds.swift"], fixed)
        let boundsHashes = lines
            .filter { ($0["path"] as? String) == "Sources/Lib/Bounds.swift" }
            .compactMap { $0["fileSHA256"] as? String }
        XCTAssertEqual(boundsHashes, [fixed, fixed])
    }

    func test_aStoppedRun_isContinuedByTheCommandItsSummaryPrinted() throws {
        try makeThePlan()
        try "".write(to: hangMarker, atomically: true, encoding: .utf8)
        let first = try launch(testPlan)
        try waitUntilHanging(first)
        kill(-first.process.processIdentifier, SIGINT)
        XCTAssertTrue(waitUntil(within: 15) { !first.process.isRunning }, "SwiftMutator didn't stop")
        let resultsFile = try onlyResultsFile()
        XCTAssertEqual(try kinds(in: resultsFile), ["header", "mutant", "mutant", "end"])
        let errors = contents(of: first.standardError)
        let printed = errors.components(separatedBy: "\n").compactMap { line in
            line.range(of: "▶️ Continue: ").map { String(line[$0.upperBound...]) }
        }
        XCTAssertEqual(printed.count, 1, errors)
        let continueCommand = try XCTUnwrap(printed.first, errors)
        let words = try wordsAShellReads(in: continueCommand)
        XCTAssertEqual(Array(words.dropLast()), ["swift-mutator"] + testPlan + ["--resume"], continueCommand)
        let ranBefore = ranLines()
        try FileManager.default.removeItem(at: hangMarker)

        let resumed = try waitForEnd(of: launch(commandLine: continueCommand))

        XCTAssertEqual(resumed.status, 0, resumed.output)
        let lines = try records(in: resultsFile)
        XCTAssertEqual(
            lines.map { $0["kind"] as? String },
            ["header", "mutant", "mutant", "end", "header", "mutant", "mutant", "end"]
        )
        XCTAssertEqual(lines[4]["mutantsReused"] as? Int, 2)
        let tested = Array(ranLines().dropFirst(ranBefore.count))
        XCTAssertEqual(tested.first, "baseline")
        XCTAssertEqual(tested.count, 3, "\(tested)")
        XCTAssertTrue(tested.dropFirst().allSatisfy { $0.hasPrefix("Checks_") }, "\(tested)")
    }

    func test_aCopyEditedBetweenSessions_refusesTheResumeWith5_andResumeIgnoringRetestsOnlyThatFile() throws {
        try makeThePlan()
        let first = try waitForEnd(of: launch(testPlan))
        XCTAssertEqual(first.status, 0, first.output)
        let resultsFile = try onlyResultsFile()
        try fixByHand("Sources/Lib/Bounds.swift")
        let resume = testPlan + ["--resume", resultsFile.path]

        let refused = try waitForEnd(of: launch(resume))

        XCTAssertEqual(refused.status, 5, refused.output)
        XCTAssertTrue(
            refused.output.contains(
                // Named by its path from the folder the command ran in, which may differ by a symbolic link.
                "/project_mutated, changed since the run's last session"
            ),
            refused.output
        )
        XCTAssertTrue(refused.output.contains("--resume-ignoring 'Sources/Lib/Bounds.swift'"), refused.output)
        XCTAssertEqual(try kinds(in: resultsFile).count, 6, "the refusal wrote a line")
        let ranBefore = ranLines()

        let waived = try waitForEnd(of: launch(resume + ["--resume-ignoring", "Sources/Lib/Bounds.swift"]))

        XCTAssertEqual(waived.status, 0, waived.output)
        let tested = Array(ranLines().dropFirst(ranBefore.count))
        XCTAssertEqual(tested.count, 3, "\(tested)")
        XCTAssertTrue(tested.dropFirst().allSatisfy { $0.hasPrefix("Bounds_") }, "\(tested)")
        let header = try XCTUnwrap(records(in: resultsFile).dropFirst(6).first)
        XCTAssertEqual(header["mutantsReused"] as? Int, 2)
        XCTAssertEqual(header["waived"] as? [String], ["Sources/Lib/Bounds.swift"])
    }

    func test_aRunFromAnotherFolder_isRefusedWith7() throws {
        try makeThePlan()
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Self.configuration.write(
            to: elsewhere.appendingPathComponent("muter.conf.yml"),
            atomically: true,
            encoding: .utf8
        )

        let refused = try waitForEnd(
            of: launch(["run-without-mutating", "--skip-update-check", plan.path], in: elsewhere)
        )

        XCTAssertEqual(refused.status, 7, refused.output)
        XCTAssertTrue(refused.output.contains("none of the 2 files it mutates"), refused.output)
        XCTAssertEqual(ranLines(), [], "something was tested")
    }

    // MARK: - Helpers

    private static var configuration: String {
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

        """
    }

    private func makeThePlan(file: StaticString = #filePath, line: UInt = #line) throws {
        let made = try waitForEnd(of: launch(makePlan))
        XCTAssertEqual(made.status, 0, made.output, file: file, line: line)
    }

    /// Adds a comment to the end of `path` in the plan's copy, as a fix by hand might, and returns the file's new
    /// SHA-256.
    @discardableResult
    private func fixByHand(_ path: String) throws -> String {
        let file = copy.appendingPathComponent(path)
        let fixed = contents(of: file) + "// fixed by hand\n"
        try fixed.write(to: file, atomically: true, encoding: .utf8)
        return FileDigest.sha256(of: Data(fixed.utf8))
    }

    private func write(_ text: String, to path: String) throws {
        let file = project.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Starts `swift-mutator` with `arguments` in `folder`, by default the project's. Foundation.Process starts it in a
    /// process group of its own.
    private func launch(_ arguments: [String], in folder: URL? = nil) throws -> Launched {
        try launch(executable: swiftMutator, arguments: arguments, in: folder ?? project)
    }

    /// Runs `commandLine`, as a summary printed it, in a shell whose `swift-mutator` is this build: a link to it in a
    /// folder first on the shell's PATH. The shell execs it, so that SwiftMutator keeps the shell's process, and the
    /// group Foundation.Process started it in.
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
            in: project,
            path: commands.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        )
    }

    private func launch(executable: URL, arguments: [String], in folder: URL, path: String? = nil) throws -> Launched {
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
    private func waitUntilHanging(_ launched: Launched) throws {
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

    /// What each run of the test command wrote down, in order: its active mutant, or `baseline`.
    private func ranLines() -> [String] {
        contents(of: markers.appendingPathComponent("ran")).split(separator: "\n").map(String.init)
    }

    /// The run's results file, in `project_muter_logs/<run>/`, which a test expects to be the only one.
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
