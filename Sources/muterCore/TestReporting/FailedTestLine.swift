import Foundation

/// The output line that shows a test failed. Any failed test kills a mutant, so its run can stop there
/// (`stopAtFirstFailure`) without changing its outcome.
enum FailedTestLine {
    /// Whether `line` (one line, without its line break) shows a failed test:
    /// - Swift Testing's line for an issue, printed when the issue is recorded:
    ///   `✘ Test sum() recorded an issue at SumTests.swift:12:5: …`. "an issue" is exactly a failing
    ///   one: a known issue reads "a known issue" (━), a warning "a warning" (⚠︎).
    /// - XCTest's line for a test that ended failed: `Test Case '-[Module.Class test]' failed (0.01 seconds).`
    ///
    /// Anchored at the start of the line, so failure text a test prints, or a parameterized test's
    /// argument quoted inside another line, doesn't match.
    static func matches(_ line: some StringProtocol) -> Bool {
        // Each check rules out almost every line before any regex runs.
        if line.contains("recorded an issue"), firstMatch(swiftTestingIssueRegEx, in: withoutColours(line)) {
            return true
        }
        return line.hasPrefix("Test Case '") && firstMatch(xctestFailureRegEx, in: String(line))
    }

    /// The first line of `log` that shows a failed test, without colour codes.
    static func first(inLog log: String) -> String? {
        // "\r\n" is a single Character, so a log with those line breaks isn't split at "\n" alone.
        log.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .first(where: matches)
            .map(withoutColours)
    }

    /// `line` without its ANSI colour codes.
    static func withoutColours(_ line: some StringProtocol) -> String {
        let text = String(line)
        guard text.contains("\u{1B}") else { return text }
        return ansiEscapeRegEx.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }

    /// The symbol is ✘, or SF Symbols' xmark.diamond.fill (U+100884) when /Library/Fonts/SF-Pro.ttf is
    /// installed, which gets an extra space when ANSI codes are on. Tag colour dots (●) may follow it.
    /// Captures `Test` or `Suite`, the name, and what follows "recorded an issue".
    private static var swiftTestingIssueRegEx: NSRegularExpression {
        NSRegularExpression.regexWithPattern(
            #"^[\x{2718}\x{100884}] +(?:\x{25CF}+ +)?(Test|Suite) (.+?) recorded an issue( at | with [0-9]+ arguments? |: )"#
        )
    }

    /// Captures the test's name.
    private static var xctestFailureRegEx: NSRegularExpression {
        NSRegularExpression.regexWithPattern(#"^Test Case '([^']*)' failed \("#)
    }

    /// Where Swift Testing recorded an issue, `SumTests.swift:12:5`, which its description follows. The file name
    /// can't contain " at ", so an argument such as `"meet at noon"` before the location isn't taken for its start.
    private static var issueLocationRegEx: NSRegularExpression {
        NSRegularExpression.regexWithPattern(#" at ((?:(?! at )[^:])+:[0-9]+:[0-9]+)(?=: |$)"#)
    }

    private static var ansiEscapeRegEx: NSRegularExpression {
        NSRegularExpression.regexWithPattern(#"\x{1B}\[[0-9;]*m"#)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> Bool {
        match(regex, in: text) != nil
    }

    private static func match(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}

extension FailedTestLine {
    /// A failed test as its line names it: Swift Testing's `sum()`, `"Adds two numbers"`, `add(_:_:)`, or
    /// `Suite "Parsing"` for a suite's own issue, with the issue's location (`SumTests.swift:12:5`); XCTest's
    /// `-[Module.Class testA]`, without one. Swift Testing's names can repeat across suites; the location's file
    /// tells them apart.
    struct FailedTest: Codable, Equatable {
        let name: String
        let location: String?
    }

    /// The tests a log shows failing.
    struct FailedTests: Equatable {
        /// Each failed test once, in the order it first failed, at most the limit.
        let tests: [FailedTest]
        /// How many distinct tests the log shows failing, uncapped.
        let count: Int
        /// The first line that shows one, without colour codes, at most `lineLengthLimit` characters.
        let firstLine: String?
    }

    /// How many failed tests a mutant's results line names.
    static let killedByLimit = 20
    static let nameLengthLimit = 200
    static let lineLengthLimit = 500

    /// The test `line` shows failing, its name capped at `nameLengthLimit` characters. nil unless `matches(line)`:
    /// the same anchored check that stops a run, so `[SwiftMutator]` notes, known issues and warnings never name a
    /// test. A parameterized test's arguments can go on past their line, and its location with them, which only
    /// `failedTests(inLog:)` finds.
    static func failedTest(in line: some StringProtocol) -> FailedTest? {
        failure(in: line)?.test
    }

    /// The tests `log` shows failing. For a run stopped at its first failed test, the first is the line that
    /// stopped it: the note SwiftMutator appends to its log doesn't match.
    static func failedTests(inLog log: String, limit: Int = killedByLimit) -> FailedTests {
        var seen = Set<TestIdentity>()
        var tests: [FailedTest] = []
        var firstLine: String?
        // "\r\n" is a single Character, so a log with those line breaks isn't split at "\n" alone.
        let lines = log.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        for (index, line) in lines.enumerated() {
            guard let found = failure(in: line) else { continue }
            let test = found.locationMayFollow
                ? FailedTest(name: found.test.name, location: locationAfterArguments(onLines: lines[(index + 1)...]))
                : found.test
            if firstLine == nil {
                firstLine = String(withoutColours(line).prefix(lineLengthLimit))
            }
            if seen.insert(TestIdentity(test)).inserted, tests.count < limit {
                tests.append(test)
            }
        }
        return FailedTests(tests: tests, count: seen.count, firstLine: firstLine)
    }

    /// A failed test as one line shows it.
    private struct Failure {
        let test: FailedTest
        /// Whether its location may be on a later line: a parameterized test's arguments, which the location
        /// follows, can span lines, as a multi-line string does.
        let locationMayFollow: Bool
    }

    /// Which test a failed test is. Its name alone would merge same-named tests in different suites, and its
    /// location would split a test whose several issues were recorded at different lines; the location's file
    /// does neither, as a test's issues are recorded in its own file. Ordered by name, then by file, none first.
    struct TestIdentity: Hashable, Comparable {
        let name: String
        let file: String?

        init(name: String, file: String?) {
            self.name = name
            self.file = file
        }

        init(_ test: FailedTest) {
            // The file name can't contain ":", so it is everything before the line and column.
            self.init(name: test.name, file: test.location.map { location in String(location.prefix { $0 != ":" }) })
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            guard lhs.name == rhs.name else { return lhs.name < rhs.name }
            switch (lhs.file, rhs.file) {
            case let (left?, right?): return left < right
            case (nil, _?): return true
            case (_?, nil), (nil, nil): return false
            }
        }
    }

    private static func failure(in line: some StringProtocol) -> Failure? {
        if line.contains("recorded an issue") {
            let text = withoutColours(line)
            if let issue = match(swiftTestingIssueRegEx, in: text) {
                return swiftTestingFailure(issue, in: text)
            }
        }
        guard line.hasPrefix("Test Case '") else { return nil }
        let text = String(line)
        guard let testCase = match(xctestFailureRegEx, in: text),
              let name = Range(testCase.range(at: 1), in: text)
        else { return nil }
        return Failure(test: FailedTest(name: capped(text[name]), location: nil), locationMayFollow: false)
    }

    private static func swiftTestingFailure(_ issue: NSTextCheckingResult, in text: String) -> Failure? {
        guard let kind = Range(issue.range(at: 1), in: text),
              let name = Range(issue.range(at: 2), in: text),
              let separator = Range(issue.range(at: 3), in: text)
        else { return nil }
        let qualifiedName = text[kind] == "Suite" ? "Suite " + text[name] : String(text[name])
        let location = location(in: text, after: separator)
        return Failure(
            test: FailedTest(name: capped(qualifiedName), location: location),
            locationMayFollow: location == nil && text[separator].hasPrefix(" with ")
        )
    }

    /// The location after a parameterized test's arguments that went on past their first line, on the line where
    /// they end. Every Swift Testing message starts with its symbol (◇, ✘, ↳ …), so the search ends at the first
    /// line that doesn't start with ASCII, and never takes a later message's location for this one's; an argument
    /// line that starts that way ends it too, leaving the location unknown.
    private static func locationAfterArguments(onLines lines: ArraySlice<Substring>) -> String? {
        for line in lines {
            let text = withoutColours(line)
            guard text.unicodeScalars.first?.isASCII ?? true else { return nil }
            if let found = match(issueLocationRegEx, in: text), let location = Range(found.range(at: 1), in: text) {
                return String(text[location])
            }
        }
        return nil
    }

    /// The location Swift Testing prints after "recorded an issue", or after a parameterized test's arguments, and
    /// before ": " and the issue's description. None when "recorded an issue: " says the issue has none.
    private static func location(in text: String, after separator: Range<String.Index>) -> String? {
        let options: NSRegularExpression.MatchingOptions
        let start: String.Index
        switch text[separator] {
        case ": ":
            return nil
        case " at ":
            // Right there, so a location the issue's description mentions is never taken for it.
            (options, start) = (.anchored, separator.lowerBound)
        default:
            // " with 2 arguments ": the location follows the arguments.
            (options, start) = ([], separator.upperBound)
        }
        guard let found = issueLocationRegEx.firstMatch(in: text, options: options, range: NSRange(start..., in: text)),
              let location = Range(found.range(at: 1), in: text)
        else { return nil }
        return String(text[location])
    }

    private static func capped(_ name: some StringProtocol) -> String {
        String(name.prefix(nameLengthLimit))
    }
}
