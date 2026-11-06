@testable import muterCore
// As in PlainTextReporterTests: XCTest runs these tests one at a time on the main thread.
@preconcurrency import Rainbow
import XCTest

/// Which mutant each label belongs to (`TriageMatches`), and what the reports say of them (`TriageSummary`).
final class TriageSummaryTests: MuterTestCase {
    private let path = "Sources/A.swift"

    override func setUp() {
        super.setUp()
        Rainbow.outputTarget = .console
        Rainbow.enabled = false
    }

    private func key(line: Int, column: Int = 9, _ id: MutationOperator.Id = .ror, occurrence: Int = 0) -> MutantKey {
        MutantKey(path: path, mutationOperatorId: id, line: line, column: column, occurrence: occurrence)
    }

    private func entry(
        line: Int,
        text: String? = "if a == b {",
        label: TriageLabel = .equivalent,
        before: String? = "==",
        after: String? = "!="
    ) -> TriageEntry {
        TriageEntry(mutant: key(line: line), label: label, before: before, after: after, line: text)
    }

    /// The mutant at `line`, which changes `text`, or a line that can't be read when nil.
    private func mutant(
        line: Int,
        text: String? = "    if a == b {",
        outcome: TestSuiteOutcome = .passed,
        id: MutationOperator.Id = .ror,
        file: String? = nil,
        before: String = "==",
        after: String = "!="
    ) -> MuterTestReport.AppliedMutationOperator {
        let place = file ?? path
        return MuterTestReport.AppliedMutationOperator(
            mutationPoint: MutationPoint(
                mutationOperatorId: id,
                filePath: "/copy/\(place)",
                position: MutationPosition(utf8Offset: 0, line: line, column: 9)
            ),
            mutationSnapshot: .make(before: before, after: after, description: "changed \(before) to \(after)"),
            testSuiteOutcome: outcome,
            sourceChange: text.map { SourceChange(line: line, before: $0, after: nil) },
            path: place,
            key: MutantKey(path: place, mutationOperatorId: id, line: line, column: 9, occurrence: 0).description
        )
    }

    private func matched(
        _ entries: [TriageEntry],
        _ mutants: [MuterTestReport.AppliedMutationOperator]
    ) -> (at: [Int?], unmatched: Int, moved: [Bool]) {
        let matches = TriageMatches(entries, against: mutants)
        return (
            entries.map { entry in matches.matches.first { $0.entry == entry }?.index },
            matches.unmatched.count,
            entries.map { entry in matches.matches.first { $0.entry == entry }?.moved ?? false }
        )
    }

    // MARK: - Which mutant a label belongs to

    func test_aLabel_appliesAtItsKey_whenItsMutantChangesTheSameThing() {
        let result = matched([entry(line: 3)], [mutant(line: 1, text: "other"), mutant(line: 3)])

        XCTAssertEqual(result.at, [1])
        XCTAssertEqual(result.moved, [false])
    }

    func test_aDifferentMutantAtTheKey_isntLabelled() {
        XCTAssertEqual(matched([entry(line: 3)], [mutant(line: 3, text: "if c == d {")]).unmatched, 1, "another line")
        XCTAssertEqual(matched([entry(line: 3)], [mutant(line: 3, before: "<", after: ">")]).unmatched, 1, "a change")
    }

    func test_aLabel_followsItsCode_toTheOneMutantThatChangesItsLine() {
        let result = matched(
            [entry(line: 3)],
            [mutant(line: 3, text: "// a comment", before: "x"), mutant(line: 5, text: "        if a == b {")]
        )

        XCTAssertEqual(result.at, [1], "indented anew")
        XCTAssertEqual(result.moved, [true])
    }

    func test_aLabel_doesntFollow_toAnyMutantThatIsntItsCode() {
        let inOtherFile = mutant(line: 5, file: "Sources/B.swift")
        let otherOperator = mutant(line: 5, id: .removeSideEffects)
        let otherLine = mutant(line: 5, text: "if c == d {")
        let otherChange = mutant(line: 5, after: "<")

        for other in [inOtherFile, otherOperator, otherLine, otherChange] {
            XCTAssertEqual(matched([entry(line: 3)], [other]).unmatched, 1, "\(other)")
        }
    }

    func test_aLabel_withTwoPlacesItCouldHaveMovedTo_labelsNeither() {
        let result = matched([entry(line: 3)], [mutant(line: 5), mutant(line: 8)])

        XCTAssertEqual(result.at, [nil])
        XCTAssertEqual(result.unmatched, 1)
    }

    func test_twoLabels_withOnePlaceToMoveTo_labelNothing() {
        let result = matched([entry(line: 3), entry(line: 4)], [mutant(line: 5)])

        XCTAssertEqual(result.unmatched, 2)
    }

    func test_aMutantAnotherLabelIsAtItsKeyOn_isntFollowedTo() {
        let result = matched([entry(line: 3), entry(line: 9, label: .missingTest)], [mutant(line: 3)])

        XCTAssertEqual(result.at, [0, nil], "whatever order the entries are in")
        XCTAssertEqual(result.unmatched, 1)
    }

    func test_aMutantWhoseLineCantBeRead_isComparedByItsChangeAtItsKey_andNeverFollowedTo() {
        XCTAssertEqual(matched([entry(line: 3)], [mutant(line: 3, text: nil)]).at, [0], "at its key")
        XCTAssertEqual(matched([entry(line: 3)], [mutant(line: 3, text: nil, after: "<")]).unmatched, 1)
        XCTAssertEqual(matched([entry(line: 3)], [mutant(line: 5, text: nil)]).unmatched, 1, "not after moving")
    }

    func test_anEntryWithoutItsLine_appliesAtItsKey_andNeverFollows() {
        let bare = entry(line: 3, text: nil, before: nil, after: nil)
        XCTAssertEqual(matched([bare], [mutant(line: 3, before: "<", after: ">")]).at, [0], "its key is all it says")
        XCTAssertEqual(matched([entry(line: 3, text: nil)], [mutant(line: 5)]).unmatched, 1)
    }

    // Identical lines 3, 7 and 11, with 4 lines added above: those at 7 and 11 are at keys that hold labels, which
    // can't be told from their own. Line 15 is the one left, which isn't enough to say the label on 3 is its.
    func test_aLabel_doesntFollow_toTheOneMutantLeftByElimination() {
        let result = matched(
            [entry(line: 3), entry(line: 7), entry(line: 11)],
            [mutant(line: 7), mutant(line: 11), mutant(line: 15)]
        )

        XCTAssertEqual(result.at, [nil, 0, 1])
        XCTAssertEqual(result.unmatched, 1)
    }

    // Line 2's twin on line 4 was tested, and line 2 wasn't: that's not code that moved.
    func test_inResultsThatLeaveOutMutants_noLabelFollows() {
        let matches = TriageMatches([entry(line: 2), entry(line: 4)], against: [mutant(line: 4)], following: false)

        XCTAssertEqual(matches.matches.map(\.entry.mutant.line), [4], "at its key, still")
        XCTAssertEqual(matches.unmatched.map(\.mutant.line), [2])
    }

    func test_whichResultsLeaveOutMutants() {
        let selection = { (changedLines: Bool) in
            ChangeSelection(
                ref: "main",
                commit: "abc",
                mergeBase: "abc",
                changedLines: changedLines,
                files: []
            )
        }

        XCTAssertFalse(MutationTestOutcome().leavesOutSomeMutants, "a whole run")
        XCTAssertFalse(MutationTestOutcome(since: selection(false)).leavesOutSomeMutants, "whole files")
        XCTAssertTrue(MutationTestOutcome(since: selection(true)).leavesOutSomeMutants)
        XCTAssertTrue(MutationTestOutcome(mutant: "Sources/A.swift:1:1 SwapTernary").leavesOutSomeMutants)
        XCTAssertTrue(
            MutationTestOutcome(shards: ShardScope(indices: [0], count: 2, mutantsInAllShards: 9)).leavesOutSomeMutants
        )
        XCTAssertTrue(MutationTestOutcome(sampleIsCutShort: true).leavesOutSomeMutants, "a run that stopped")
    }

    func test_aMutantThatsNotNamedByAKey_isntLabelled() {
        let keyless = MuterTestReport.AppliedMutationOperator(
            mutationPoint: .make(),
            mutationSnapshot: .make(before: "==", after: "!="),
            testSuiteOutcome: .passed,
            sourceChange: SourceChange(line: 3, before: "if a == b {", after: nil),
            path: path
        )

        XCTAssertEqual(matched([entry(line: 3)], [keyless]).unmatched, 1)
    }

    // A label on a mutant no test reached may still hold: nothing tested it to say otherwise.
    func test_aMutantNotCovered_keepsItsLabel_andCountsAmongThoseToTriage() throws {
        let labelled = report(
            [(line: 3, outcome: .noCoverage), (line: 4, outcome: .passed)],
            entries: [entry(line: 3, text: nil, before: nil, after: nil)]
        )

        let result = MuterTestReport(from: labelled)
        let summary = try XCTUnwrap(result.triageSummary)

        XCTAssertEqual(summary.survivors, 2)
        XCTAssertEqual(summary.triaged, 1)
        XCTAssertEqual(summary.noLongerSurviving, [])
        XCTAssertEqual(result.notCovered.map(\.appliedOperator.triage?.label), [.equivalent])
        XCTAssertEqual(summary.notCovered, 1)
        XCTAssertTrue(summary.countSentence.hasPrefix("Of the 2 mutants that survived, timed out or no test reached,"))
    }

    // MARK: - What the reports say

    private func report(
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
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary, json)
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
        let result = MuterTestReport(from: outcome, readingSourcesWith: { _ in source })

        let summary = try XCTUnwrap(result.triageSummary)
        XCTAssertEqual(summary.moved, [])
        XCTAssertEqual(summary.noLongerSurviving.map(\.mutant), [key(line: 4).description])
        XCTAssertEqual(summary.noLongerSurviving.map(\.savedAs), [key(line: 2).description], "what --remove takes")
    }
}
