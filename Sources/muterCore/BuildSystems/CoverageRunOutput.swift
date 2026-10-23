import Foundation

/// What a coverage run printed, read the same way for SwiftPM and xcodebuild.
extension BuildSystemCoverage {
    /// What a command printed: its standard output, then its standard error from a new line.
    static func log(of result: CommandResult) -> String {
        guard !result.output.isEmpty, !result.output.hasSuffix("\n"), !result.errors.isEmpty else {
            return result.output + result.errors
        }
        return result.output + "\n" + result.errors
    }

    static func firstLine(of text: String) -> String {
        text.split(separator: "\n").first.map { String($0).trimmed } ?? ""
    }

    /// The first line of `log` that reports an error, without colour codes: one that starts with `error: `, as SwiftPM's
    /// and llvm-cov's do, or says `: error: `, as the compiler's `File.swift:3:9: error: …` and `xcodebuild: error: …`
    /// do, or `fatal error: ` in their place, as clang's can. SwiftPM prints build errors to standard error under
    /// either build system, but a line in standard output counts too. Other lines can say `error:` without reporting
    /// one, as xcodebuild's log of a method named `…ForDeveloperDir:error:` does on a Mac whose simulators are out of
    /// date.
    static func firstError(in log: String) -> String? {
        log.split(whereSeparator: \.isNewline)
            .lazy
            .map { FailedTestLine.withoutColours($0).trimmed }
            .first { $0.firstMatchOf(#"(?:^|: )(?:fatal )?error: "#) != nil }
            .map { String($0.prefix(FailedTestLine.lineLengthLimit)) }
    }

    /// The test process that stopped before its tests finished, in a run whose output is `log`. SwiftPM prints no line
    /// for one ended by SIGKILL, SIGTERM or SIGINT, as the system's memory killer ends one, and xcodebuild none for a
    /// Swift Testing process that crashed. Its XCTest suites, or its Swift Testing run, started and never ended. Named
    /// by its test bundle and the test it was running, as XCTest's lines give them, or else by its test library and the
    /// first Swift Testing test that started and never ended. nil when every one finished.
    static func unfinishedTestProcess(inLog log: String) -> String? {
        var suites = StartedAndEnded()
        var testCases = StartedAndEnded()
        var swiftTestingRuns = StartedAndEnded()
        var swiftTestingTests = StartedAndEnded()
        // Each check rules out almost every line before any regex runs.
        for line in log.split(whereSeparator: \.isNewline).map(FailedTestLine.withoutColours) {
            if line.hasPrefix("Test Suite '") {
                suites.read(
                    line,
                    started: #"^Test Suite '([^']*)' started at "#,
                    ended: #"^Test Suite '([^']*)' (?:passed|failed) at "#
                )
            } else if line.hasPrefix("Test Case '") {
                // macOS's line says `started.`, Linux's `started at` and the time.
                testCases.read(
                    line,
                    started: #"^Test Case '([^']*)' started"#,
                    ended: #"^Test Case '([^']*)' (?:passed|failed|skipped) \("#
                )
            } else if line.contains("Test run ") {
                // After Swift Testing's symbol: ◇ as a run starts, ✔ or ✘ as it ends, or SF Symbols' own.
                swiftTestingRuns.read(
                    line,
                    started: #"^\S+ +(Test run) started\."#,
                    ended: #"^\S+ +(Test run) with .* (?:passed|failed) after "#
                )
            } else if line.contains(" Test ") {
                // A test's lines, as its run's: a parameterized one ends `with 3 test cases passed after`.
                swiftTestingTests.read(
                    line,
                    started: #"^\S+ +Test (.+) started\.$"#,
                    ended: #"^\S+ +Test (.+?)(?: with \d+ test cases?)? (?:passed|failed) after "#
                )
            }
        }
        if !suites.unfinished.isEmpty || !testCases.unfinished.isEmpty {
            let bundle = suites.unfinished.first { $0.hasSuffix(".xctest") }
            let test = testCases.unfinished.first.map { "during \($0)" }
            return [bundle ?? "XCTest", test].compactMap { $0 }.joined(separator: ", ")
        }
        guard !swiftTestingRuns.unfinished.isEmpty else {
            return nil
        }
        let test = swiftTestingTests.unfinished.first.map { "during \($0)" }
        return ["Swift Testing", test].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The suites, tests or runs a run's output shows starting, by name, and how many more times each started than it
/// ended: several test processes print the same suite names, such as `All tests`.
private struct StartedAndEnded {
    private var running: [String: Int] = [:]
    private var order: [String] = []

    /// Those that started more times than they ended, in the order they first started.
    var unfinished: [String] {
        order.filter { running[$0, default: 0] > 0 }
    }

    /// Counts `line` as a start or an end when `started` or `ended`, each of which captures a name, matches it.
    mutating func read(_ line: String, started: String, ended: String) {
        if let name = line.firstCaptureOf(started) {
            if running[name] == nil { order.append(name) }
            running[name, default: 0] += 1
        } else if let name = line.firstCaptureOf(ended) {
            running[name, default: 0] -= 1
        }
    }
}
