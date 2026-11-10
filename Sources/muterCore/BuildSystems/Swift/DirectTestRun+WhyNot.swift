import Foundation

extension DirectTestRun {
    /// Why a mutant's tests can't run directly after a baseline that printed `baselineLog`, given a run that did with
    /// no mutant on, which ended as `outcome` and printed `log`; nil if they can.
    static func whyNot(baselineLog: String, outcome: TestSuiteOutcome, log: String) -> String? {
        let expected = swiftTestingCounts(in: baselineLog).sorted()
        let ran = swiftTestingCounts(in: log).sorted()
        guard outcome == .passed else {
            return "running the test bundles directly, with no mutant on, didn't pass, as `swift test` did"
        }
        guard !expected.isEmpty, expected.reduce(0, +) > 0 else {
            return "the baseline ran no Swift Testing test"
        }
        guard ran == expected else {
            let counts = { (counts: [Int]) in counts.map(String.init).joined(separator: ", ") }
            return "running the test bundles directly ran \(counts(ran)) Swift Testing tests, "
                + "where `swift test` ran \(counts(expected))"
        }
        return nil
    }

    /// Whether `log`, a `swift test` run's, shows an XCTest test run: XCTest's `Executed 3 tests, with …` line. A
    /// bundle with none still prints one, for 0 tests.
    static func ranXCTestTests(in log: String) -> Bool {
        counts(of: #"Executed ([0-9]+) tests?, with "#, in: log).contains { $0 > 0 }
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
