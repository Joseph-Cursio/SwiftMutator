@testable import muterCore
import XCTest

extension TriageSummaryTests {
    func report(
        _ outcomes: [(line: Int, outcome: TestSuiteOutcome)],
        entries: [TriageEntry],
        file: String = "/project/muter.triage.yml"
    ) -> MutationTestOutcome {
        let mutations = outcomes.map { place in
            MutationTestOutcome.Mutation.make(
                testSuiteOutcome: place.outcome,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/project_mutated/\(path)",
                    position: MutationPosition(utf8Offset: 0, line: place.line, column: 9)
                ),
                snapshot: .make(before: "==", after: "!=", description: "changed == to !="),
                originalProjectDirectoryUrl: URL(fileURLWithPath: "/project"),
                mutatedProjectDirectoryURL: URL(fileURLWithPath: "/project_mutated"),
                key: key(line: place.line)
            )
        }
        return MutationTestOutcome(mutations: mutations, triage: TriageFile(path: file, entries: entries))
    }

    func test_counts_markSurvivorsAlone_andLeaveTheScore() throws {
        let labelled = report(
            [(1, .passed), (2, .timeout), (3, .passed), (4, .failed), (5, .buildError)],
            entries: [
                entry(line: 1, text: nil, label: .missingTest),
                entry(line: 2, text: nil, label: .equivalent),
                entry(line: 4, text: nil, label: .equivalent),
                entry(line: 5, text: nil, label: .outOfScope),
                entry(line: 90, text: nil, label: .toolLimitation),
            ]
        )
        var bare = labelled
        bare.triage = nil

        let result = MuterTestReport(from: labelled)
        let summary = try XCTUnwrap(result.triageSummary)

        XCTAssertEqual(summary.survivors, 3)
        XCTAssertEqual(summary.triaged, 2)
        XCTAssertEqual(summary.byLabel, [
            .init(label: .missingTest, mutants: 1),
            .init(label: .equivalent, mutants: 1),
            .init(label: .outOfScope, mutants: 0),
            .init(label: .toolLimitation, mutants: 0),
        ])
        XCTAssertEqual(summary.noLongerSurviving, [
            .init(
                mutant: key(line: 4).description,
                label: .equivalent,
                verdict: "killed",
                savedAs: key(line: 4).description
            ),
        ])
        // It wasn't tested, so nothing shows the label no longer holds.
        XCTAssertEqual(summary.notTested, [
            .init(
                mutant: key(line: 5).description,
                label: .outOfScope,
                verdict: "build error",
                savedAs: key(line: 5).description
            ),
        ])
        XCTAssertEqual(summary.unmatched, [.init(mutant: key(line: 90).description, label: .toolLimitation)])
        let marks = result.survivors.map(\.appliedOperator.triage?.label)
        XCTAssertEqual(marks, [.missingTest, .equivalent, nil])

        XCTAssertEqual(result.globalMutationScore, MuterTestReport(from: bare).globalMutationScore, "no score changes")
        XCTAssertEqual(result.numberOfKilledMutants, MuterTestReport(from: bare).numberOfKilledMutants)
    }

    func test_aFileWithNoEntries_leavesEveryReportAsItWas() throws {
        var bare = report([(1, .passed)], entries: [])
        let empty = bare
        bare.triage = nil

        XCTAssertEqual(PlainTextReporter().report(from: empty), PlainTextReporter().report(from: bare))
        // The JSON report doesn't sort its keys, so two encodes of one report can differ as text.
        let parsed = try [empty, bare].map { outcome in
            let json = JsonReporter().report(from: outcome)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: AnyHashable], json)
        }
        XCTAssertEqual(parsed[0], parsed[1])
        XCTAssertNil(MuterTestReport(from: empty).triageSummary)
    }

    func test_thePlainReport_marksEachSurvivor_andSaysWhatNeedsAttention() {
        let text = PlainTextReporter().report(from: report(
            [(1, .passed), (2, .passed), (4, .failed)],
            entries: [
                TriageEntry(mutant: key(line: 1), label: .equivalent, note: "a is b\nhere"),
                entry(line: 4, text: nil),
                entry(line: 90, text: nil, label: .outOfScope),
            ]
        ))

        XCTAssertTrue(text.contains("    Triaged: equivalent: a is b here\n"), text)
        XCTAssertEqual(text.components(separatedBy: "Triaged:").count, 2, "one mark, on line 1's survivor")
        XCTAssertTrue(text.contains("Labels people gave surviving mutants. They change no score."), text)
        let counts = "Of the 2 mutants that survived or timed out, 1 is triaged in muter.triage.yml, and 1 isn't."
        XCTAssertTrue(text.contains(counts), text)
        XCTAssertTrue(text.contains("By label: 1 equivalent."), text)
        let noLonger = "1 label is on a mutant that no longer survives:\n  \(key(line: 4)) (equivalent): killed"
        XCTAssertTrue(text.contains(noLonger), text)
        XCTAssertTrue(text.contains("  \(key(line: 90)) (out of scope)"), text)
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "Triage\n")).lowerBound,
            try XCTUnwrap(text.range(of: "Mutation Test Scores")).lowerBound
        )
    }

    func test_aLongList_isCut_andTheJSONHoldsItAll() throws {
        let entries = (100..<112).map { entry(line: $0, text: nil) }
        let outcome = report([(1, .passed)], entries: entries)

        let text = PlainTextReporter().report(from: outcome)
        XCTAssertTrue(text.contains("12 labels match no mutant"), text)
        XCTAssertTrue(text.contains("  and 2 more; the JSON report lists them all"), text)
        XCTAssertFalse(text.contains(key(line: 110).description), text)

        let json = try JSONDecoder().decode(
            MuterTestReport.self,
            from: Data(JsonReporter().report(from: outcome).utf8)
        )
        XCTAssertEqual(json.triageSummary?.unmatched.count, 12)
    }

    func test_theJSON_holdsTheSummary_andEachSurvivorsMark() throws {
        let outcome = report(
            [(1, .passed)],
            entries: [TriageEntry(mutant: key(line: 1), label: .toolLimitation, note: "why")]
        )

        let json = try JSONDecoder().decode(
            MuterTestReport.self,
            from: Data(JsonReporter().report(from: outcome).utf8)
        )

        XCTAssertEqual(json.triageSummary?.file, "/project/muter.triage.yml")
        XCTAssertEqual(json.triageSummary?.triaged, 1)
        XCTAssertEqual(
            json.fileReports.first?.appliedOperators.first?.triage,
            TriageMark(label: .toolLimitation, note: "why")
        )
    }

    func test_theHTML_showsTheLabels_withANoteAsText() {
        let html = HTMLReporter().report(from: report(
            [(1, .passed), (2, .passed)],
            entries: [TriageEntry(mutant: key(line: 1), label: .equivalent, note: "<b>a</b> is b")]
        ))

        XCTAssertTrue(html.contains("<th>Triage</th>"), html)
        XCTAssertTrue(html.contains("equivalent: &lt;b&gt;a&lt;/b&gt; is b"), html)
        XCTAssertFalse(html.contains("<b>a</b>"), html)
        XCTAssertTrue(html.contains("Of the 2 mutants that survived or timed out, 1 is triaged"), html)
    }

    func test_theHTML_withoutAFile_hasNoTriageColumn() {
        var outcome = report([(1, .passed)], entries: [])
        outcome.triage = nil

        XCTAssertFalse(HTMLReporter().report(from: outcome).contains("Triage"))
    }

    func test_aMoveToAMutantThatNoLongerSurvives_isSaidOnce() throws {
        let outcome = report(
            [(4, .failed)],
            entries: [entry(line: 2, text: "== b")]
        )
        // Line 4, with its `==` at the mutant's column, 9.
        let source = Data("\n\n\n        == b\n".utf8)
        let result = MuterTestReport(from: outcome) { _ in source }

        let summary = try XCTUnwrap(result.triageSummary)
        XCTAssertEqual(summary.moved, [])
        XCTAssertEqual(summary.noLongerSurviving.map(\.mutant), [key(line: 4).description])
        XCTAssertEqual(summary.noLongerSurviving.map(\.savedAs), [key(line: 2).description], "what --remove takes")
    }
}
