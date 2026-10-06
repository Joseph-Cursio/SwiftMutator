import XCTest

/// Runs the built `swift-mutator` on a two-file project whose test command is a shell script, in each report format,
/// then `swift-mutator report` on the run's log folder, and checks that the report rebuilt from the results file is
/// the run's own, but for what only the moment of making it can give: the HTML footer's time, the order a parallel
/// run's Xcode warnings came in, and JSON's key order. Every wait is bounded, a SwiftMutator still running when its
/// wait or its test ends is killed, and every file a test writes is in a temporary folder.
final class ReportCommandAcceptanceTests: XCTestCase {
    /// Kills the mutants in Checks.swift, printing the line Swift Testing shows an issue of `check()` with, then the
    /// line it ends a failed run with; those in Bounds.swift survive. The baseline, which has no active mutant, passes.
    /// The issue's line can stop a run there, as `buildSystem: swift` stops runs at their first failed test, so whether
    /// a run exits by itself depends on timing; the run and the report read the same results line either way.
    private static let testCommand = """
        mutant=$(cat "$SWIFTMUTATOR_ACTIVE_MUTANT_FILE" 2>/dev/null)
        case "$mutant" in
            Checks_*)
                echo "✘ Test check() recorded an issue at ChecksTests.swift:3:5: Expectation failed"
                echo "✘ Test run with 1 test failed after 0.001 seconds with 1 issue."
                exit 1;;
        esac
        exit 0
        """

    /// What an ended `swift-mutator` gave.
    private struct Ended {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    private struct RanOver: Error, CustomStringConvertible {
        let arguments: [String]
        var description: String { "swift-mutator \(arguments.joined(separator: " ")) ran over 120 s, so it was killed" }
    }

    private var swiftMutator: URL!
    private var root: URL!
    private var project: URL!
    private var logs: URL { root.appendingPathComponent("project_muter_logs", isDirectory: true) }
    /// The SwiftMutator a test is waiting for.
    private var running: Foundation.Process?
    private var processCount = 0

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
            .appendingPathComponent("ReportCommandAcceptanceTests-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        let sources = project.appendingPathComponent("Sources/Lib", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        func isPositive(_ value: Int) -> Bool { value > 0 }
        func both(_ first: Bool, _ second: Bool) -> Bool { first && second }

        """.write(to: sources.appendingPathComponent("Checks.swift"), atomically: true, encoding: .utf8)
        try """
        func isSmall(_ value: Int) -> Bool { value < 10 }
        func isHuge(_ value: Int) -> Bool { value > 100 }

        """.write(to: sources.appendingPathComponent("Bounds.swift"), atomically: true, encoding: .utf8)
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
        mutationTestTimeout: 60

        """.write(to: project.appendingPathComponent("muter.conf.yml"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let running, running.isRunning {
            stop(running)
        }
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Tests

    func test_report_rebuildsTheRunsOwnReport_inEachFormat() throws {
        for format in ["plain", "json", "html", "xcode"] {
            // One results file in the log folder, which a second run in the same minute would add to.
            try? FileManager.default.removeItem(at: logs)
            let runReport = root.appendingPathComponent("run.\(format)")
            let rebuiltReport = root.appendingPathComponent("rebuilt.\(format)")

            let run = try runSwiftMutator(
                ["run", "--skip-update-check", "--skip-coverage", "-f", format, "-o", runReport.path]
            )
            XCTAssertEqual(run.status, 0, "\(format) run: \(run.standardError)")
            let folder = try onlyLogFolder()
            let report = try runSwiftMutator(["report", folder.path, "-f", format, "-o", rebuiltReport.path])

            XCTAssertEqual(report.status, 0, "\(format) report: \(report.standardError)")
            XCTAssertTrue(report.standardError.contains("the run finished"), report.standardError)
            XCTAssertTrue(report.standardError.contains("Report saved to \(rebuiltReport.path)"), report.standardError)
            switch format {
            case "json":
                XCTAssertEqual(try parsedJSON(at: runReport), try parsedJSON(at: rebuiltReport))
                XCTAssertEqual(try outcomes(inJSONReportAt: runReport), ["failed", "failed", "passed", "passed"])
                XCTAssertEqual(
                    try killingTestNames(inJSONReportAt: runReport),
                    ["Checks.swift": [["check()"], ["check()"]], "Bounds.swift": [nil, nil]]
                )
            case "html":
                XCTAssertEqual(try withoutFooter(contents(of: runReport)), try withoutFooter(contents(of: rebuiltReport)))
            default:
                XCTAssertEqual(try contents(of: runReport), try contents(of: rebuiltReport), format)
            }
            if format == "xcode" {
                // A parallel run warns in the order its mutants finish; the report, in the order they were tested.
                let reportWarnings = warnings(in: report.standardOutput)
                XCTAssertEqual(reportWarnings.count, 2, report.standardOutput)
                XCTAssertEqual(Set(reportWarnings), Set(warnings(in: run.standardOutput)), run.standardOutput)
                XCTAssertEqual(report.standardOutput, reportWarnings.map { $0 + "\n" }.joined())
            } else {
                XCTAssertEqual(report.standardOutput, "", format)
            }
        }
    }

    func test_report_withoutOutputPath_printsOnlyTheReport() throws {
        let runReport = root.appendingPathComponent("run.json")
        let run = try runSwiftMutator(["run", "--skip-update-check", "--skip-coverage", "-f", "json", "-o", runReport.path])
        XCTAssertEqual(run.status, 0, run.standardError)

        let folder = try onlyLogFolder()
        let report = try runSwiftMutator(["report", folder.path, "-f", "json"])

        XCTAssertEqual(report.status, 0, report.standardError)
        let printed = try JSONSerialization.jsonObject(with: Data(report.standardOutput.utf8)) as? NSDictionary
        XCTAssertEqual(printed, try parsedJSON(at: runReport))
        XCTAssertTrue(report.standardError.contains("Report of 4 of 4 mutants"), report.standardError)
        XCTAssertFalse(report.standardError.contains("Report saved"), report.standardError)
    }

    func test_report_onAFileThatIsNotAResultsFile_exitsWithStatus1_sayingWhy() throws {
        let notes = root.appendingPathComponent("notes.jsonl")
        try "{\"kind\":\"mutant\"}\n".write(to: notes, atomically: true, encoding: .utf8)

        let report = try runSwiftMutator(["report", notes.path])

        XCTAssertEqual(report.status, 1, report.standardError)
        XCTAssertTrue(report.standardError.contains("isn't a SwiftMutator results file"), report.standardError)
        XCTAssertEqual(report.standardOutput, "")
    }

    // MARK: - Helpers

    /// Runs `swift-mutator` with `arguments` in the project's folder, and waits up to 120 seconds for it to end; one
    /// still running then is killed, and the test fails.
    private func runSwiftMutator(_ arguments: [String]) throws -> Ended {
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
        process.executableURL = swiftMutator
        process.arguments = arguments
        process.currentDirectoryURL = project
        process.standardOutput = outputFile
        process.standardError = errorFile
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        running = process
        defer { running = nil }
        guard ended.wait(timeout: .now() + 120) == .success else {
            stop(process)
            throw RanOver(arguments: arguments)
        }
        return Ended(
            status: process.terminationStatus,
            standardOutput: try contents(of: outputPath),
            standardError: try contents(of: errorPath)
        )
    }

    /// Kills a SwiftMutator that is still running, and the process group Foundation.Process started it in, which holds
    /// it alone.
    private func stop(_ process: Foundation.Process) {
        let pid = process.processIdentifier
        guard pid > 1 else { return }
        Darwin.kill(-pid, SIGKILL)
        Darwin.kill(pid, SIGKILL)
        process.waitUntilExit()
    }

    /// The run's log folder, `project_muter_logs/<run>/`, which a test expects to be the only one.
    private func onlyLogFolder() throws -> URL {
        let folders = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.count, 1, "\(folders)")
        return try XCTUnwrap(folders.first)
    }

    private func contents(of file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
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

    /// The names of the tests each mutant's `killingTests` lists in a JSON report, by file, or nil for a mutant without
    /// them.
    private func killingTestNames(inJSONReportAt file: URL) throws -> [String: [[String]?]] {
        let fileReports = try XCTUnwrap(parsedJSON(at: file)["fileReports"] as? [[String: Any]])
        var names: [String: [[String]?]] = [:]
        for fileReport in fileReports {
            let fileName = try XCTUnwrap(fileReport["fileName"] as? String)
            names[fileName] = ((fileReport["appliedOperators"] as? [[String: Any]]) ?? []).map { appliedOperator in
                ((appliedOperator["killingTests"] as? [String: Any])?["tests"] as? [[String: Any]])
                    .map { tests in tests.compactMap { $0["name"] as? String } }
            }
        }
        return names
    }

    /// The HTML report with its footer, the time it was made, left empty.
    private func withoutFooter(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"<footer class="footer">[^<]*</footer>"#,
            with: #"<footer class="footer"></footer>"#,
            options: .regularExpression
        )
    }

    /// The Xcode format's warnings in `output`, in the order printed, without the escape codes of the progress bar
    /// that a run's standard output also holds.
    private func warnings(in output: String) -> [String] {
        let pattern = #"/[^\u001B\n]*: warning: Your test suite did not kill this mutant: [^\u001B\n]*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("The warning pattern doesn't compile")
            return []
        }
        return expression
            .matches(in: output, range: NSRange(output.startIndex..., in: output))
            .compactMap { Range($0.range, in: output).map { String(output[$0]) } }
    }
}
