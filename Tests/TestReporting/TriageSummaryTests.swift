@testable import muterCore
// As in PlainTextReporterTests: XCTest runs these tests one at a time on the main thread.
@preconcurrency import Rainbow
import XCTest

/// Which mutant each label belongs to (`TriageMatches`), and what the reports say of them (`TriageSummary`).
final class TriageSummaryTests: MuterTestCase {
    let path = "Sources/A.swift"

    override func setUp() {
        super.setUp()
        Rainbow.outputTarget = .console
        Rainbow.enabled = false
    }

    func key(line: Int, column: Int = 9, _ id: MutationOperator.Id = .ror, occurrence: Int = 0) -> MutantKey {
        MutantKey(path: path, mutationOperatorId: id, line: line, column: column, occurrence: occurrence)
    }

    func entry(
        line: Int,
        text: String? = "if a == b {",
        label: TriageLabel = .equivalent,
        before: String? = "==",
        after: String? = "!="
    ) -> TriageEntry {
        TriageEntry(mutant: key(line: line), label: label, before: before, after: after, line: text)
    }

    /// The mutant at `line`, which changes `text`, or a line that can't be read when nil.
    func mutant(
        line: Int,
        text: String? = "    if a == b {",
        outcome: TestSuiteOutcome = .passed,
        id: MutationOperator.Id = .ror,
        file: String? = nil,
        before: String = "==",
        after: String = "!="
    ) -> AppliedMutationOperator {
        let place = file ?? path
        return AppliedMutationOperator(
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

    /// Where each entry matched, by its mutant's index, how many entries matched none, and which matched a mutant
    /// that moved.
    private struct Matched {
        let at: [Int?]
        let unmatched: Int
        let moved: [Bool]
    }

    private func matched(
        _ entries: [TriageEntry],
        _ mutants: [AppliedMutationOperator]
    ) -> Matched {
        let matches = TriageMatches(entries, against: mutants)
        return Matched(
            at: entries.map { entry in matches.matches.first { $0.entry == entry }?.index },
            unmatched: matches.unmatched.count,
            moved: entries.map { entry in matches.matches.first { $0.entry == entry }?.moved ?? false }
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
        let keyless = AppliedMutationOperator(
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
}
