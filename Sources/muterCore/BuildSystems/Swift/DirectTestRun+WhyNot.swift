import Foundation

extension DirectTestRun {
    /// Why a mutant's tests can't run directly after a baseline that printed `baselineLog`, given a run that did with
    /// no mutant on, which ended as `outcome` and printed `log`; nil if they can. That run must pass, and run as many
    /// XCTest tests in each bundle as the baseline did, and as many Swift Testing tests in each Swift Testing run.
    static func whyNot(baselineLog: String, outcome: TestSuiteOutcome, log: String) -> String? {
        let expected = swiftTestingCounts(in: baselineLog).sorted()
        let ran = swiftTestingCounts(in: log).sorted()
        let expectedXCTest = xctestCounts(in: baselineLog).filter { $0.tests > 0 }.sorted()
        let ranXCTest = xctestCounts(in: log).filter { $0.tests > 0 }.sorted()
        guard outcome == .passed else {
            return "running the test bundles directly, with no mutant on, didn't pass, as `swift test` did"
        }
        // Else the run, which starts XCTest runs only for the bundles the log names, would leave out its XCTest tests.
        guard !expectedXCTest.isEmpty || !ranXCTestTests(in: baselineLog) else {
            return "the baseline's log doesn't say which bundles ran its XCTest tests"
        }
        guard expected.reduce(0, +) > 0 || !expectedXCTest.isEmpty else {
            return "the baseline ran no XCTest or Swift Testing test"
        }
        guard ranXCTest == expectedXCTest else {
            let counts = { (counts: [XCTestCount]) in
                counts.isEmpty ? "none" : counts.map { "\($0.tests) in \($0.suite).xctest" }.joined(separator: ", ")
            }
            return "running the test bundles directly ran XCTest tests as \(counts(ranXCTest)), "
                + "where `swift test` ran \(counts(expectedXCTest))"
        }
        guard ran == expected else {
            let counts = { (counts: [Int]) in counts.map(String.init).joined(separator: ", ") }
            return "running the test bundles directly ran \(counts(ran)) Swift Testing tests, "
                + "where `swift test` ran \(counts(expected))"
        }
        return nil
    }

    /// Why this run, after a baseline that ran XCTest tests, goes through `swift test` instead, before any check run;
    /// nil if it can be checked. XCTest tests run directly only by `xctest` on macOS, which needs finding, without a
    /// test filter or an option that changes how `swift test` runs them, which a direct run would ignore, and only in
    /// the bundles the baseline's log names. A run of Swift Testing tests alone passes on its arguments, as `swift
    /// test` does.
    var whyXCTestTestsNeedSwiftTest: String? {
        guard runsXCTest || baselineRanXCTest else { return nil }
        if case .macOS(_, _, nil) = platform {
            return "the baseline ran XCTest tests, and `xcrun --find xctest` didn't say where `xctest` is"
        }
        if arguments.contains(where: { Self.isOption($0, among: ["--filter", "--skip"]) }) {
            return "the test command filters tests, and only `swift test` turns a filter into XCTest's test names"
        }
        let given = { (option: String) in arguments.contains { Self.isOption($0, option) } }
        if let option = Self.xctestOptions.first(where: given) {
            return "the test command has \(option), which changes how `swift test` runs XCTest tests"
        }
        // Else the check run, which starts XCTest runs only for the bundles the log names, would leave them out.
        guard runsXCTest else { return "the baseline's log doesn't say which bundles ran its XCTest tests" }
        return nil
    }

    /// The options of `swift test` that change how it runs XCTest tests, which a direct run doesn't do: one `xctest`
    /// for each test, a report file, coverage.
    static let xctestOptions = [
        "--parallel",
        "--num-workers",
        "--xunit-output",
        "--enable-code-coverage",
        "--experimental-xunit-message-failure",
    ]

    /// Whether `argument` is `option`, alone or with its value after `=`.
    private static func isOption(_ argument: String, _ option: String) -> Bool {
        argument == option || argument.hasPrefix(option + "=")
    }

    private static func isOption(_ argument: String, among options: [String]) -> Bool {
        options.contains { isOption(argument, $0) }
    }

    /// This run with `xctestBundles` the bundles whose XCTest tests a baseline that printed `baselineLog` ran, and
    /// `baselineRanXCTest` whether it ran any.
    func withXCTestBundles(ranIn baselineLog: String) -> Self {
        var copy = self
        copy.xctestBundles = Set(Self.xctestCounts(in: baselineLog).filter { $0.tests > 0 }.map(\.suite))
        copy.baselineRanXCTest = Self.ranXCTestTests(in: baselineLog)
        return copy
    }

    /// Whether `log`, a `swift test` run's, shows an XCTest test run: XCTest's `Executed 3 tests, with …` line, which a
    /// bundle with none prints too, for 0 tests, or under `--parallel`, which prints no such line, a `[1/4] Testing
    /// CoreTests.ParserTests/testEmpty` line for each XCTest test.
    static func ranXCTestTests(in log: String) -> Bool {
        counts(of: #"Executed ([0-9]+) tests?, with "#, in: log).contains { $0 > 0 }
            || NSRegularExpression.regexWithPattern(#"^\[[0-9]+/[0-9]+\] Testing "#, .anchorsMatchLines)
            .firstMatch(in: log, range: NSRange(log.startIndex..., in: log)) != nil
    }

    /// The tests an XCTest run of a bundle ran, as its suite's summary says.
    struct XCTestCount: Comparable {
        /// The bundle's suite's name without `.xctest`: on macOS the bundle's, on Linux the products folder's.
        let suite: String
        let tests: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.suite, lhs.tests) < (rhs.suite, rhs.tests)
        }
    }

    /// The tests each XCTest run in `log` ran, in order, from its bundle's suite's summary: `Test Suite
    /// 'CoreTests.xctest' passed at …`, then `Executed 85 tests, with …`. Each process names one such suite, which
    /// counts its tests whatever else wraps it, `All tests` or `Selected tests`, except a filtered run on Linux, whose
    /// root is `Selected tests` with no such suite, and a run under `--parallel`, which prints no summary.
    static func xctestCounts(in log: String) -> [XCTestCount] {
        let regex = NSRegularExpression.regexWithPattern(
            #"Test Suite '([^'\n]+)\.xctest' (?:passed|failed) at [^\n]*\n[ \t]*Executed ([0-9]+) tests?"#
        )
        return regex.matches(in: log, range: NSRange(log.startIndex..., in: log)).compactMap { match in
            guard let suite = Range(match.range(at: 1), in: log),
                  let tests = Range(match.range(at: 2), in: log).flatMap({ Int(log[$0]) })
            else { return nil }
            return XCTestCount(suite: String(log[suite]), tests: tests)
        }
    }

    /// The tests each Swift Testing run in `log` ran, in order, from its `Test run with 12 tests in 3 suites …` line.
    static func swiftTestingCounts(in log: String) -> [Int] {
        counts(of: #"Test run with ([0-9]+) tests? "#, in: log)
    }

    private static func counts(of pattern: String, in log: String) -> [Int] {
        let regex = NSRegularExpression.regexWithPattern(pattern)
        return regex.matches(in: log, range: NSRange(log.startIndex..., in: log)).compactMap { match in
            Range(match.range(at: 1), in: log).flatMap { Int(log[$0]) }
        }
    }
}
