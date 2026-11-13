@testable import muterCore
import XCTest

/// What the reports say of the survivors tested again with the property tests (`PropertySurvivorRerunSummary`).
final class PropertySurvivorRerunSummaryTests: XCTestCase {
    private static let copy = URL(fileURLWithPath: "/p_mutated")

    /// How a survivor's reruns ended: with `outcome`, on `run` of `runs`.
    private struct Rerun {
        let outcome: TestSuiteOutcome
        let run: Int
        let runs: Int

        init(_ outcome: TestSuiteOutcome, _ run: Int, _ runs: Int) {
            self.outcome = outcome
            self.run = run
            self.runs = runs
        }
    }

    /// A survivor at `line` of `file`, with its property survivor reruns ended by `run` of `runs` with `outcome`, if
    /// given.
    private static func survivor(
        _ file: String,
        line: Int,
        rerun: Rerun? = nil,
        test: String = "ordered()"
    ) -> MutationTestOutcome.Mutation {
        var mutation = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .passed,
            point: .make(
                mutationOperatorId: .ror,
                filePath: "/p_mutated/\(file)",
                position: MutationPosition(utf8Offset: line * 10, line: line, column: 5)
            ),
            mutatedProjectDirectoryURL: copy
        )
        mutation.propertySurvivorRerun = rerun.map {
            let failed = $0.outcome == .failed
            return .init(
                outcome: $0.outcome,
                run: $0.run,
                runs: $0.runs,
                killingTests: failed ? .init(tests: [.init(name: test, location: nil)], count: 1, isComplete: true)
                    : nil
            )
        }
        return mutation
    }

    private static let mutations = [
        survivor("Sources/Sort.swift", line: 9, rerun: Rerun(.passed, 10, 10)),
        survivor("Sources/Sort.swift", line: 3, rerun: Rerun(.failed, 4, 10)),
        survivor("Sources/Max.swift", line: 2, rerun: Rerun(.failed, 1, 10), test: "maxIsAnElement()"),
        survivor("Sources/Max.swift", line: 7, rerun: Rerun(.timeout, 2, 10)),
        survivor("Sources/Min.swift", line: 1),
        .make(testSuiteOutcome: .failed),
    ]

    func test_isNil_whenNoSurvivorWasTestedAgain() {
        XCTAssertNil(PropertySurvivorRerunSummary(of: [Self.survivor("Sources/Min.swift", line: 1)]))
        XCTAssertNil(PropertySurvivorRerunSummary(of: []))
    }

    func test_countsWhatTheRunsCameTo_andListsTheSurvivorsAPropertyToldApart_byPlace() throws {
        let summary = try XCTUnwrap(PropertySurvivorRerunSummary(of: Self.mutations))

        XCTAssertEqual(
            [summary.survivorsTestedAgain, summary.failedOnALaterRun, summary.passedEveryRun, summary.unsettled],
            [4, 2, 1, 1]
        )
        XCTAssertEqual(summary.runs, 10)
        let toldApart = PropertySurvivorRerunSummary.toldApart(in: .make(mutations: Self.mutations))
        XCTAssertEqual(toldApart.map(\.path), ["Sources/Max.swift", "Sources/Sort.swift"])
        XCTAssertEqual(toldApart.map(\.failedOnRun), [1, 4])
        XCTAssertEqual(toldApart.map(\.test), ["maxIsAnElement()", "ordered()"])
        XCTAssertEqual(summary.sentences, [
            "The property tests ran again on their own for 4 survivors whose code ran, up to 10 times each, stopping "
                + "at the first failure (propertySurvivorReruns). A property test tries a sample of inputs, so a "
                + "survivor may only have missed the one that tells it apart.",
            "A property test failed on a later run for 2: its law holds the change, and its generator rarely reaches "
                + "an input that shows it, so a generator that tries edge cases would.",
            "Every run passed for 1: no property reaches the change, or the mutant is equivalent. Neither proves "
                + "which.",
            "1 timed out or didn't build on a run, which settles nothing.",
            "They all stay survivors in the score, --fail-under and --baseline.",
        ])
    }

    // The plain and HTML reports have the section, with the table, and the JSON report the counts alone; none of
    // them without a survivor tested again. The score is the same either way.
    func test_theReports_haveASurvivorsAndPropertiesSection_onlyWhenSurvivorsWereTestedAgain() throws {
        let tested = MutationTestOutcome.make(mutations: Self.mutations)
        let untested = MutationTestOutcome.make(
            mutations: Self.mutations.map { mutation in
                var plain = mutation
                plain.propertySurvivorRerun = nil
                return plain
            }
        )

        let text = PlainTextReporter().report(from: tested)
        XCTAssertTrue(text.contains("\n------------------------\nSurvivors and Properties\n------------------------\n"))
        let rest = try XCTUnwrap(text.components(separatedBy: "Survivors and Properties\n").last)
        let section = try XCTUnwrap(rest.components(separatedBy: "\n\n\n").first)
        let rows = section.components(separatedBy: "\n").filter { $0.hasPrefix("Sources/") || $0.hasPrefix("Place") }
        XCTAssertEqual(rows.count, 3, section)
        XCTAssertTrue(rows[0].contains("Failed On Run"), rows[0])
        XCTAssertTrue(rows[1].hasPrefix("Sources/Max.swift:2:5"), rows[1])
        XCTAssertTrue(rows[1].contains("1 of 10"), rows[1])
        XCTAssertFalse(PlainTextReporter().report(from: untested).contains("Survivors and Properties"))

        let html = HTMLReporter().report(from: tested)
        XCTAssertTrue(html.contains("<span class=\"divider-content\">Survivors and Properties</span>"))
        XCTAssertTrue(html.contains("<td class=\"right-aligned\">4 of 10</td>"))
        XCTAssertFalse(HTMLReporter().report(from: untested).contains("Survivors and Properties"))

        let json = try JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: tested).utf8))
        let counts = try XCTUnwrap((json as? [String: Any])?["propertySurvivorReruns"] as? [String: Any])
        XCTAssertEqual(
            Set(counts.keys), ["survivorsTestedAgain", "failedOnALaterRun", "passedEveryRun", "unsettled", "runs"]
        )
        XCTAssertEqual(counts["failedOnALaterRun"] as? Int, 2)
        let jsonWithout = try JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: untested).utf8))
        XCTAssertNil((jsonWithout as? [String: Any])?["propertySurvivorReruns"])

        XCTAssertEqual(
            MuterTestReport(from: tested).globalMutationScore,
            MuterTestReport(from: untested).globalMutationScore
        )
    }
}
