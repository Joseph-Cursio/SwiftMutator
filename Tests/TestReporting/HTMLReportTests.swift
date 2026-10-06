@testable import muterCore
import TestingExtensions
import XCTest

final class HTMLReportTests: MuterTestCase {
    private let mutations: [MutationTestOutcome.Mutation] = (0 ... 50).map {
        MutationTestOutcome.Mutation.make(
            testSuiteOutcome: nextMutationTestOutcome($0),
            point: .make(
                mutationOperatorId: nextMutationOperator($0),
                filePath: "/root/file\($0).swift",
                position: .init(integerLiteral: $0)
            ),
            snapshot: .make(before: "before", after: "after"),
            originalProjectDirectoryUrl: URL(fileURLWithPath: "/root/")
        )
    }

    private lazy var sut = HTMLReporter()

    func test_reportWhenOutcomeHasCoverage() {
        let outcome = MutationTestOutcome.make(
            mutations: mutations,
            coverage: .make(percent: 78)
        )
        let actual = sut.report(from: outcome)

        AssertSnapshot(actual)
    }

    func test_reportWhenOutcomeDoesntHaveCoverage() {
        let outcome = MutationTestOutcome.make(
            mutations: mutations.exclude { $0.testSuiteOutcome == .noCoverage },
            coverage: .null
        )
        let actual = sut.report(from: outcome)

        AssertSnapshot(actual)
    }

    func test_killedByColumn_namesTestsInTextOnly() {
        // A Swift Testing display name, quotes and all, with characters HTML must escape.
        let awkward = FailedTestLine.FailedTest(name: #""sum <of> a & b""#, location: "SumTests.swift:3:5")
        let total = FailedTestLine.FailedTest(name: "total()", location: nil)
        let outcome = MutationTestOutcome.make(mutations: [
            .make(
                testSuiteOutcome: .failed,
                point: .make(filePath: "/root/Sum.swift", position: 3),
                killingTests: .init(tests: [awkward], count: 1, isComplete: true)
            ),
            .make(
                testSuiteOutcome: .failed,
                point: .make(filePath: "/root/Total.swift", position: 4),
                killingTests: .init(tests: [awkward, total], count: 2, isComplete: true)
            ),
            .make(testSuiteOutcome: .passed, point: .make(filePath: "/root/Total.swift", position: 8)),
        ])

        let html = sut.report(from: outcome)

        let escaped = #""sum &lt;of&gt; a &amp; b""#
        XCTAssertTrue(html.contains("<th>Mutation Test Result</th><th>Killed By</th>"))
        XCTAssertTrue(html.contains("<td class=\"left-aligned\">\(escaped)</td>"))
        XCTAssertTrue(html.contains(
            "<td class=\"left-aligned\"><details><summary>\(escaped) (+1)</summary>"
                + "<ul><li>\(escaped) — SumTests.swift:3:5</li><li>total()</li></ul></details></td>"
        ))
        XCTAssertTrue(html.contains("<td class=\"left-aligned\">-</td>"))
        XCTAssertEqual(html.components(separatedBy: "<details>").count - 1, 1)
        // Plot doesn't escape attribute values: the name is never in one, only ever starting a text node.
        XCTAssertFalse(html.contains("<of>"))
        var occurrences = 0
        var searchStart = html.startIndex
        while let found = html.range(of: escaped, range: searchStart ..< html.endIndex) {
            XCTAssertEqual(html[html.index(before: found.lowerBound)], ">")
            occurrences += 1
            searchStart = found.upperBound
        }
        // Three in the Killed By column, one in the Killing Tests table.
        XCTAssertEqual(occurrences, 4)
    }

    func test_reportWithKillingTests() {
        let html = sut.report(from: .withKillingTests)

        XCTAssertTrue(html.contains("<span class=\"divider-content\">Killing Tests</span>"))
        AssertSnapshot(html)
    }

    func test_reportWithoutKillingTests_hasNoKillingTestsSection() {
        let html = sut.report(from: .make(mutations: mutations))

        XCTAssertFalse(html.contains("Killing Tests"))
    }
}
