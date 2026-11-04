@testable import muterCore
import XCTest

/// The Examples and Properties split (`PropertyKillSummary`) and the globs that pick out property tests
/// (`PropertyTestPattern`).
final class PropertyKillSummaryTests: XCTestCase {
    // MARK: - Globs

    func test_aGlob_matchesATestsWholeName_orTheWholeFileItsIssueWasRecordedIn() {
        let sortProperty = identity("ordered()", in: "SortProperties.swift")
        let xctestProperty = identity("-[AppTests.ParseProperties testRoundTrip]", in: nil)
        let example = identity("sum()", in: "SumTests.swift")

        let properties = PropertyTestPattern("*Properties*")
        XCTAssertTrue(properties.matches(sortProperty), "by its file")
        XCTAssertTrue(properties.matches(xctestProperty), "by its name, as XCTest's lines name no file")
        XCTAssertFalse(properties.matches(example))

        XCTAssertTrue(PropertyTestPattern("SortProperties.swift").matches(sortProperty), "a file, whole")
        XCTAssertTrue(PropertyTestPattern("ordered()").matches(sortProperty), "a name, whole")
        XCTAssertFalse(PropertyTestPattern("Properties").matches(sortProperty), "not a part of either")
        XCTAssertFalse(PropertyTestPattern("*properties*").matches(sortProperty), "case included")
        XCTAssertTrue(PropertyTestPattern("*").matches(example))
    }

    func test_aStar_standsForAnyCharacters_andAQuestionMarkForOne() {
        let matches = { (glob: String, name: String) in
            PropertyTestPattern(glob).matches(self.identity(name, in: nil))
        }

        XCTAssertTrue(matches("a*b*c", "aXbYbZc"), "a star takes more characters when the rest doesn't match")
        XCTAssertTrue(matches("a*c", "ac"), "a star can take none")
        XCTAssertFalse(matches("a*c", "acb"))
        XCTAssertTrue(matches("t?st()", "test()"))
        XCTAssertFalse(matches("t?st()", "tst()"), "a question mark takes one character, never none")
        XCTAssertTrue(matches("??()", "🧪é()"), "one character each, an emoji or an accented letter")
        XCTAssertTrue(matches("\"*\"", #""sorting keeps every element""#), "a display name, quotes and all")
    }

    func test_anEmptyGlob_isAProblem() {
        XCTAssertNil(PropertyTestPattern.problem(with: ["*Properties*"]))
        XCTAssertNil(PropertyTestPattern.problem(with: []))
        XCTAssertEqual(
            PropertyTestPattern.problem(with: ["*Properties*", ""]),
            "a glob can't be empty, as it would match no test"
        )
    }

    // MARK: - The split

    func test_isNil_withoutGlobs() {
        XCTAssertNil(PropertyKillSummary(of: Self.mutations, globs: []))
    }

    // The kills add up to the headline's killed count, and every count is of the headline's mutants.
    func test_splitsEachKill_byTheKindsOfTestRecordedFailing() throws {
        let summary = try XCTUnwrap(PropertyKillSummary(of: Self.mutations, globs: ["*Properties*"]))

        XCTAssertEqual(summary.globs, ["*Properties*"])
        XCTAssertEqual(summary.scoredMutants, 9, "every mutant but the build error, the timeout and survivor too")
        XCTAssertEqual(summary.killedMutants, 7, "the failures and the crash")
        XCTAssertEqual(summary.killedOnlyByExamples, 2)
        XCTAssertEqual(summary.killedOnlyByProperties, 2)
        XCTAssertEqual(summary.killedByBoth, 1)
        XCTAssertEqual(summary.killedNamingNoTest, 2, "the crash, and the kill whose log names no test")
        XCTAssertEqual(
            summary.killedOnlyByExamples + summary.killedOnlyByProperties + summary.killedByBoth
                + summary.killedNamingNoTest,
            summary.killedMutants
        )
        let report = MuterTestReport(from: .make(mutations: Self.mutations))
        XCTAssertEqual(summary.killedMutants, report.numberOfKilledMutants)
        XCTAssertEqual(summary.incompleteExampleOnlyKills, 1, "the run that stopped at its first failed test")
        XCTAssertEqual(summary.incompletePropertyOnlyKills, 0)
        XCTAssertTrue(summary.countsAreBounds)
    }

    func test_eachProperty_countsItsKills_andThoseItWasTheOnlyTestRecordedFailingFor() throws {
        let summary = try XCTUnwrap(PropertyKillSummary(of: Self.mutations, globs: ["*Properties*"]))

        XCTAssertEqual(summary.distinctProperties, 2)
        XCTAssertEqual(summary.properties, [
            .init(name: "ordered()", file: "SortProperties.swift", mutants: 2, onlyRecordedKillerOf: 1),
            .init(name: "-[AppTests.ParseProperties testRoundTrip]", file: nil, mutants: 1, onlyRecordedKillerOf: 1),
        ])
    }

    // The list's count, not its length: a run that recorded one test of three it saw failing isn't that test's alone.
    func test_aPropertyRecordedAloneInAListCutShort_isNotTheOnlyKiller() throws {
        let ordered = failedTest("ordered()", in: "SortProperties.swift")
        let summary = try XCTUnwrap(PropertyKillSummary(
            of: [kill(naming: [ordered], count: 3, isComplete: false)],
            globs: ["*Properties*"]
        ))

        XCTAssertEqual(summary.properties.map(\.onlyRecordedKillerOf), [0])
        XCTAssertEqual(summary.incompletePropertyOnlyKills, 1)
    }

    func test_listsTheTenPropertiesThatKilledTheMost_thenByNameAndFile() throws {
        let mutations = (1 ... 12).flatMap { index in
            // Property 12 kills 12 mutants, property 1 kills 1.
            (1 ... index).map { _ in kill(naming: [failedTest("p\(index)()", in: "Properties.swift")]) }
        } + [
            kill(naming: [failedTest("tie()", in: "BProperties.swift")]),
            kill(naming: [failedTest("tie()", in: "AProperties.swift")]),
        ]

        let summary = try XCTUnwrap(PropertyKillSummary(of: mutations, globs: ["*Properties*"]))

        XCTAssertEqual(summary.distinctProperties, 14)
        XCTAssertEqual(summary.properties.map(\.name), (3 ... 12).reversed().map { "p\($0)()" })
        let ties = try XCTUnwrap(PropertyKillSummary(of: Array(mutations.suffix(2)), globs: ["*Properties*"]))
        XCTAssertEqual(ties.properties.map(\.file), ["AProperties.swift", "BProperties.swift"])
    }

    // A property rerun settles a kill of examples alone: a property that failed makes it one by both, and every
    // property passing makes it one by examples alone, however its list was cut short.
    func test_aPropertyRerun_settlesAKillOfExamplesAlone() throws {
        let sum = failedTest("sum()", in: "SumTests.swift")
        let ordered = failedTest("ordered()", in: "SortProperties.swift")
        var killedToo = kill(naming: [sum], count: 1, isComplete: false)
        let orderedFailed = MutationTestOutcome.KillingTests(tests: [ordered], count: 1, isComplete: true)
        killedToo.propertyRerun = .init(outcome: .failed, killingTests: orderedFailed)
        var passed = kill(naming: [sum], count: 1, isComplete: false)
        passed.propertyRerun = .init(outcome: .passed, killingTests: nil)
        var timedOut = kill(naming: [sum], count: 1, isComplete: false)
        timedOut.propertyRerun = .init(outcome: .timeout, killingTests: nil)

        let summary = try XCTUnwrap(PropertyKillSummary(of: [killedToo, passed, timedOut], globs: ["*Properties*"]))

        XCTAssertEqual([summary.killedOnlyByExamples, summary.killedByBoth], [2, 1])
        XCTAssertEqual(summary.incompleteExampleOnlyKills, 1, "only the rerun that timed out leaves it unsettled")
        XCTAssertEqual([summary.propertyReruns, summary.propertyRerunKills, summary.propertyRerunPasses], [3, 1, 1])
        XCTAssertEqual(summary.properties, [
            .init(name: "ordered()", file: "SortProperties.swift", mutants: 1, onlyRecordedKillerOf: 0),
        ])
        XCTAssertEqual(
            summary.splitSentences[1],
            "The property tests ran again on their own for 3 kills only examples were recorded making: a property "
                + "failed too for 1, which count as by both, and every property passed for 1; 1 timed out or didn't "
                + "build, which settles nothing."
        )
    }

    // MARK: - What the reports say

    func test_theSentences_giveEachShareOfTheScoredMutants_andSayWhenTheCountsAreBounds() throws {
        let summary = try XCTUnwrap(PropertyKillSummary(of: Self.mutations, globs: ["*Properties*", "SortSpec.swift"]))

        XCTAssertEqual(
            summary.globSentence,
            #"Property tests are those whose name or file matches "*Properties*" or "SortSpec.swift"."#
        )
        XCTAssertEqual(summary.splitSentences, [
            "Of the 9 mutants scored, examples alone were recorded killing 2 (22%), properties alone 2 (22%), and "
                + "both 1 (11%).",
            "2 more killed mutants (22%) name no failed test, as a crash may not, so they count as neither.",
            "1 of the kills by one kind stopped at its first failed test or time limit, or named more than 20 tests, "
                + "so a test of the other kind may have failed too: the count by both is a lower bound, and the "
                + "counts by one kind alone may be high. stopAtFirstFailure: false records every failed test, at the "
                + "cost of a longer run.",
        ])
        XCTAssertNil(summary.shownPropertiesSentence)
    }

    func test_withEveryListComplete_andNoPropertyFailing_theSentencesSaySo() throws {
        let summary = try XCTUnwrap(PropertyKillSummary(
            of: [kill(naming: [failedTest("sum()", in: "SumTests.swift")])],
            globs: ["*Properties*"]
        ))

        XCTAssertEqual(summary.globSentence, #"Property tests are those whose name or file matches "*Properties*"."#)
        XCTAssertEqual(summary.splitSentences, [
            "Of the 1 mutant scored, examples alone were recorded killing 1 (100%), properties alone 0 (0%), and both "
                + "0 (0%).",
        ])
        XCTAssertEqual(summary.shownPropertiesSentence, "No property test was recorded failing for a killed mutant.")
    }

    func test_theReports_haveAnExamplesAndPropertiesSection_onlyWithGlobs() throws {
        let withGlobs = MutationTestOutcome.make(mutations: Self.mutations, propertyTests: ["*Properties*"])
        let withoutGlobs = MutationTestOutcome.make(mutations: Self.mutations)

        let text = PlainTextReporter().report(from: withGlobs)
        XCTAssertTrue(text.contains("\n-----------------------\nExamples and Properties\n-----------------------\n"))
        XCTAssertTrue(text.contains("\nOf the 9 mutants scored, examples alone were recorded killing 2 (22%)"))
        let section = try XCTUnwrap(text.components(separatedBy: "Examples and Properties\n").last)
        let table = section.components(separatedBy: "\n")
            .filter { $0.hasPrefix("ordered()") || $0.hasPrefix("Property ") }
        XCTAssertEqual(table.count, 2, text)
        XCTAssertTrue(table[0].hasSuffix("Mutants   Only Recorded Killer Of"), table[0])
        XCTAssertFalse(PlainTextReporter().report(from: withoutGlobs).contains("Examples and Properties"))

        let html = HTMLReporter().report(from: withGlobs)
        XCTAssertTrue(html.contains("<span class=\"divider-content\">Examples and Properties</span>"))
        XCTAssertTrue(html.contains("<td class=\"left-aligned\">-[AppTests.ParseProperties testRoundTrip]</td>"))
        XCTAssertFalse(
            HTMLReporter().report(from: withoutGlobs)
                .contains("Examples and Properties")
        )

        let json = try JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: withGlobs).utf8))
        let summary = try XCTUnwrap((json as? [String: Any])?["propertyKillSummary"] as? [String: Any])
        XCTAssertEqual(summary["killedByBoth"] as? Int, 1)
        XCTAssertEqual(summary["globs"] as? [String], ["*Properties*"])
        let jsonWithout = try JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: withoutGlobs).utf8))
        XCTAssertNil((jsonWithout as? [String: Any])?["propertyKillSummary"])
    }
}

private extension PropertyKillSummaryTests {
    /// Two property tests, one Swift Testing's in SortProperties.swift and one XCTest's, and an example. Killed: 2 by
    /// examples alone, one of them by a run that stopped at its first failed test; 2 by properties alone; 1 by both;
    /// a crash and a kill whose log names no test. Then a survivor, a timeout and a build error.
    static var mutations: [MutationTestOutcome.Mutation] {
        let sum = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:3:5")
        let ordered = FailedTestLine.FailedTest(name: "ordered()", location: "SortProperties.swift:8:5")
        let roundTrip = FailedTestLine.FailedTest(name: "-[AppTests.ParseProperties testRoundTrip]", location: nil)
        return [
            mutant(.failed, KillingTests(tests: [sum], count: 1, isComplete: true)),
            mutant(.failed, KillingTests(tests: [ordered], count: 1, isComplete: true)),
            mutant(.failed, KillingTests(tests: [sum, ordered], count: 2, isComplete: true)),
            mutant(.failed, KillingTests(tests: [sum], count: 1, isComplete: false)),
            mutant(.failed, KillingTests(tests: [roundTrip], count: 1, isComplete: true)),
            mutant(.runtimeError, nil),
            mutant(.failed, KillingTests(tests: [], count: 0, isComplete: true)),
            mutant(.passed, nil),
            mutant(.timeout, KillingTests(tests: [], count: 0, isComplete: false)),
            mutant(.buildError, nil),
        ]
    }

    typealias KillingTests = MutationTestOutcome.KillingTests

    static func mutant(_ outcome: TestSuiteOutcome, _ killingTests: KillingTests?) -> MutationTestOutcome.Mutation {
        .make(
            testSuiteOutcome: outcome,
            point: .make(filePath: "/project/Sources/Sort.swift", position: 3),
            killingTests: killingTests
        )
    }

    func kill(
        naming tests: [FailedTestLine.FailedTest],
        count: Int? = nil,
        isComplete: Bool = true
    ) -> MutationTestOutcome.Mutation {
        Self.mutant(.failed, KillingTests(tests: tests, count: count ?? tests.count, isComplete: isComplete))
    }

    func failedTest(_ name: String, in file: String) -> FailedTestLine.FailedTest {
        .init(name: name, location: "\(file):3:5")
    }

    func identity(_ name: String, in file: String?) -> FailedTestLine.TestIdentity {
        .init(name: name, file: file)
    }
}
