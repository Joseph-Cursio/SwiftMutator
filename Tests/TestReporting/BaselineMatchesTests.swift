@testable import muterCore
import XCTest

/// Which of a run's survivors a baseline file records: by what each changes and its line, never by its key alone, and
/// identical twins counted as a multiset.
final class BaselineMatchesTests: XCTestCase {

    func test_aSurvivorAtItsKey_stillSurvives() {
        let matches = BaselineMatches([entry(key(42))], against: [tested(key(42))])

        XCTAssertEqual(matches.stillSurvive, 1)
        XCTAssertEqual(matches.newSurvivors, [])
        XCTAssertEqual(matches.fixed, [])
        XCTAssertEqual(matches.notTested, [])
        XCTAssertEqual(matches.matchedWithoutLine, 0)
    }

    // Two lines added above it move its key; what it changes, and its line, follow it.
    func test_aSurvivorWhoseLineMoved_stillSurvives() {
        let matches = BaselineMatches([entry(key(42))], against: [tested(key(44))])

        XCTAssertEqual(matches.stillSurvive, 1)
        XCTAssertEqual(matches.newSurvivors, [])
    }

    // A timeout and a survivor flip between runs: both count against the score, and matching ignores which it was.
    func test_aSurvivorThatTimedOutNow_stillSurvives() {
        let matches = BaselineMatches([entry(key(42), .survived)], against: [tested(key(42), .survivor(.timedOut))])

        XCTAssertEqual(matches.stillSurvive, 1)
        XCTAssertEqual(matches.newSurvivors, [])
    }

    // A different mutant that came to have the key isn't the one recorded.
    func test_neverByTheKeyAlone() {
        let other = tested(key(42), before: "==", after: "!=", line: "if count == limit {")
        let matches = BaselineMatches([entry(key(42))], against: [other])

        XCTAssertEqual(matches.stillSurvive, 0)
        XCTAssertEqual(matches.newSurvivors, [other])
        XCTAssertEqual(matches.notTested, [entry(key(42))])
    }

    // An edit to the mutant's own line is a change to its code.
    func test_anEditedLine_isANewSurvivor_andTheEntryNotTested() {
        let edited = tested(key(42), line: "if total < limit {")
        let matches = BaselineMatches([entry(key(42))], against: [edited])

        XCTAssertEqual(matches.newSurvivors, [edited])
        XCTAssertEqual(matches.notTested.count, 1)
    }

    func test_anotherFile_orOperator_isntMatched() {
        let otherFile = tested(key(42, path: "Sources/Other.swift"))
        let otherOperator = tested(key(42, operator: .removeSideEffects))
        let matches = BaselineMatches([entry(key(42))], against: [otherFile, otherOperator])

        XCTAssertEqual(matches.newSurvivors, [otherFile, otherOperator])
        XCTAssertEqual(matches.notTested.count, 1)
    }

    // Two identical entries match two identical survivors, and a third is new.
    func test_identicalTwins_areCountedAsAMultiset() {
        let entries = [entry(key(10)), entry(key(20))]
        let survivors = [tested(key(11)), tested(key(21)), tested(key(31))]

        let matches = BaselineMatches(entries, against: survivors)

        XCTAssertEqual(matches.stillSurvive, 2)
        XCTAssertEqual(matches.newSurvivors.count, 1)
        XCTAssertEqual(matches.fixed, [])
    }

    // The nearest twin to the entry's old line is the one it follows, so the new one is the one added.
    func test_aTwinFollowsTheNearestSurvivor() {
        let matches = BaselineMatches([entry(key(10))], against: [tested(key(12)), tested(key(80))])

        XCTAssertEqual(matches.newSurvivors.map(\.key), [key(80)])
    }

    // Survivors are paired first, so a twin that was killed is fixed, and the one that survives isn't new.
    func test_aTwinSurvivedAndATwinWasKilled_isOneStillSurviving_andOneFixed() {
        let entries = [entry(key(10)), entry(key(20))]
        let run = [tested(key(10), .killed), tested(key(20))]

        let matches = BaselineMatches(entries, against: run)

        XCTAssertEqual(matches.stillSurvive, 1)
        XCTAssertEqual(matches.fixed.count, 1)
        XCTAssertEqual(matches.newSurvivors, [])
    }

    func test_aKilledMutant_isFixed() {
        let matches = BaselineMatches([entry(key(42))], against: [tested(key(45), .killed)])

        XCTAssertEqual(matches.fixed, [entry(key(42))])
        XCTAssertEqual(matches.stillSurvive, 0)
        XCTAssertEqual(matches.notTested, [])
    }

    // A build error wasn't tested, so it says nothing of the entry.
    func test_anEntryMatchingNothingTested_isNotTested() {
        let matches = BaselineMatches(
            [entry(key(42)), entry(key(7, path: "Sources/Gone.swift"))],
            against: [tested(key(42), .notTested)]
        )

        XCTAssertEqual(matches.notTested.count, 2)
        XCTAssertEqual(matches.fixed, [])
        XCTAssertEqual(matches.stillSurvive, 0)
    }

    // A file that changed since it was tested, or can't be read, has no line: what it changes is compared alone, and
    // the pairing counted.
    func test_aLineNotKnown_onEitherSide_comparesTheChangeAlone_andIsCounted() {
        let unknownNow = BaselineMatches([entry(key(42))], against: [tested(key(50), line: nil)])
        XCTAssertEqual(unknownNow.stillSurvive, 1)
        XCTAssertEqual(unknownNow.matchedWithoutLine, 1)

        let unknownThen = BaselineMatches([entry(key(42), line: nil)], against: [tested(key(50))])
        XCTAssertEqual(unknownThen.stillSurvive, 1)
        XCTAssertEqual(unknownThen.matchedWithoutLine, 1)

        let atItsKey = BaselineMatches([entry(key(42), line: nil)], against: [tested(key(42), .killed)])
        XCTAssertEqual(atItsKey.fixed.count, 1)
        XCTAssertEqual(atItsKey.matchedWithoutLine, 1)
    }

    // A line known on both sides pairs first, so a survivor whose line is unknown is left for an entry without one.
    func test_aKnownLine_pairsBeforeAnUnknownOne() {
        let known = tested(key(60))
        let unknown = tested(key(61), line: nil)
        let matches = BaselineMatches([entry(key(42))], against: [unknown, known])

        XCTAssertEqual(matches.newSurvivors, [unknown])
        XCTAssertEqual(matches.matchedWithoutLine, 0)
    }

    // A survivor whose own key is taken by an entry it doesn't match can still be followed to by another.
    func test_eachSurvivorPairsOnce() {
        let matches = BaselineMatches([entry(key(42)), entry(key(42, occurrence: 1))], against: [tested(key(42))])

        XCTAssertEqual(matches.stillSurvive, 1)
        XCTAssertEqual(matches.notTested.count, 1)
        XCTAssertEqual(matches.newSurvivors, [])
    }

    // A shard holds the first twin and the pasted one, and another shard the second twin: the second's entry is paired
    // with its own mutant, which this shard left out, and so can't hide the pasted survivor.
    func test_anEntryForAMutantTheRunLeftOut_takesNoIdenticalSurvivorItTested() {
        let pasted = tested(key(70))
        let matches = BaselineMatches(
            [entry(key(10)), entry(key(40))],
            against: [tested(key(10)), pasted, tested(key(40), .notTested)]
        )

        XCTAssertEqual(matches.newSurvivors, [pasted])
        XCTAssertEqual(matches.stillSurvive, 1)
        XCTAssertEqual(matches.notTested, [entry(key(40))])
    }

    // Moved, it follows its code to where the run left it out, nearer than a pasted copy the run tested.
    func test_anEntryWhoseMutantMoved_andWasLeftOut_isNotTested_andTheCopyNew() {
        let pasted = tested(key(70))
        let matches = BaselineMatches([entry(key(10))], against: [tested(key(11), .notTested), pasted])

        XCTAssertEqual(matches.newSurvivors, [pasted])
        XCTAssertEqual(matches.notTested.count, 1)
    }

    // Code the run didn't test is never fixed, by an identical kill elsewhere.
    func test_anEntryForAMutantTheRunLeftOut_isntFixedByAnIdenticalKill() {
        let matches = BaselineMatches(
            [entry(key(10))],
            against: [tested(key(10), .notTested), tested(key(70), .killed)]
        )

        XCTAssertEqual(matches.fixed, [])
        XCTAssertEqual(matches.notTested, [entry(key(10))])
    }

    // When the mutants left out aren't known, an entry is paired only at its own key: elsewhere, an identical survivor
    // may be a new one, and its own mutant untested.
    func test_exactKeysOnly_pairsAnEntryOnlyAtItsKey() {
        let pasted = tested(key(70))
        let matches = BaselineMatches([entry(key(10))], against: [pasted], exactKeysOnly: true)
        XCTAssertEqual(matches.newSurvivors, [pasted])
        XCTAssertEqual(matches.notTested.count, 1)

        let atItsKey = BaselineMatches([entry(key(10), line: nil)], against: [tested(key(10))], exactKeysOnly: true)
        XCTAssertEqual(atItsKey.stillSurvive, 1)
        XCTAssertEqual(atItsKey.matchedWithoutLine, 1)
    }

    // Every pairing by the line is made before any without it, at a key or not: an entry whose line isn't known can't
    // take the mutant another entry's line matches, though it sits at the first entry's key.
    func test_anEntryWithoutALine_atItsKey_waitsForThePairingsByTheLine() {
        let shifted = tested(key(20), line: "if x < y {")
        let other = tested(key(50), line: "if a < b {")
        let matches = BaselineMatches(
            [entry(key(10), line: "if x < y {"), entry(key(20), line: nil)],
            against: [shifted, other]
        )

        XCTAssertEqual(matches.newSurvivors, [])
        XCTAssertEqual(matches.stillSurvive, 2)
        XCTAssertEqual(matches.notTested, [])
        XCTAssertEqual(matches.matchedWithoutLine, 1)
    }

    // A change on no one line never has a line, whatever changed: pairing it without one isn't counted.
    func test_aChangeOnNoOneLine_isMatchedWithoutItsLine_uncounted() {
        let multiline = tested(key(42), before: "foo( a, b )", after: "", line: nil, lineUnread: false)
        let recorded = entry(key(42), before: "foo( a, b )", after: "", line: nil)
        let matches = BaselineMatches([recorded], against: [multiline])

        XCTAssertEqual(matches.stillSurvive, 1)
        XCTAssertEqual(matches.matchedWithoutLine, 0)

        let unread = tested(key(42), before: "foo( a, b )", after: "", line: nil, lineUnread: true)
        let counted = BaselineMatches([recorded], against: [unread])
        XCTAssertEqual(counted.matchedWithoutLine, 1)
    }

    // Whether a line isn't known as its file can't be read, or as its change isn't on one line of a file that reads;
    // and the mutants the run left out, after those it tested, with their lines.
    func test_theTestedMutants_tellAFileUnreadFromAChangeOnNoOneLine_andHoldThoseLeftOut() {
        let source = "let limit = 3\n  if count < limit {\n    foo(\n      a)\n}\n"
        func mutation(_ file: String, line: Int, column: Int, before: String) -> MutationTestOutcome.Mutation {
            .make(
                testSuiteOutcome: .passed,
                point: .make(
                    mutationOperatorId: .ror,
                    filePath: "/project_mutated/Sources/\(file)",
                    position: .init(utf8Offset: 0, line: line, column: column)
                ),
                snapshot: .make(before: before, after: "x"),
                originalProjectDirectoryUrl: URL(fileURLWithPath: "/project"),
                mutatedProjectDirectoryURL: URL(fileURLWithPath: "/project_mutated"),
                key: key(line, column: column, path: "Sources/\(file)")
            )
        }
        var outcome = MutationTestOutcome(
            mutations: [
                mutation("Rules.swift", line: 3, column: 5, before: "foo( a)"),
                mutation("Gone.swift", line: 3, column: 5, before: "foo( a)"),
            ],
            projectPath: "/project",
            mutatedProjectPath: "/project_mutated"
        )
        outcome.unselectedMutants = [
            UnselectedMutant(
                key: key(2, column: 12),
                snapshot: .make(before: "<", after: "<="),
                originalProjectPath: "/project/Sources/Rules.swift"
            ),
        ]

        let all = Tested.all(of: outcome) { $0 == "/project/Sources/Rules.swift" ? Data(source.utf8) : nil }

        XCTAssertEqual(all.map(\.line), [nil, nil, "if count < limit {"])
        XCTAssertEqual(all.map(\.lineUnread), [false, true, false])
        XCTAssertEqual(all.map(\.kind), [.survivor(.survived), .survivor(.survived), .notTested])
        XCTAssertEqual(all.last?.key, key(2, column: 12))
    }

    // After the tested, and before those left out: survivors not covered, each with its line from its original file,
    // under the project's path.
    func test_theMutantsOfCodeNoTestRan_areSurvivorsNotCovered_withTheirLines() {
        var outcome = MutationTestOutcome(
            mutations: [.make(testSuiteOutcome: .failed, key: key(9))],
            projectPath: "/project",
            mutatedProjectPath: "/project_mutated"
        )
        outcome.uncoveredMutants = [
            UncoveredMutant(key: key(2, column: 12), snapshot: .make(before: "<", after: "<=")),
            UncoveredMutant(key: key(4, path: "Sources/Gone.swift"), snapshot: .make(before: "<", after: "<=")),
        ]
        outcome.unselectedMutants = [
            UnselectedMutant(
                key: key(30),
                snapshot: .make(before: "<", after: "<="),
                originalProjectPath: "/project/Sources/Rules.swift"
            ),
        ]
        let source = "let limit = 3\n  if count < limit {\n}\n"

        let all = Tested.all(of: outcome) { $0 == "/project/Sources/Rules.swift" ? Data(source.utf8) : nil }

        XCTAssertEqual(all.map(\.key), [key(9), key(2, column: 12), key(4, path: "Sources/Gone.swift"), key(30)])
        XCTAssertEqual(all.map(\.kind), [.killed, .survivor(.notCovered), .survivor(.notCovered), .notTested])
        XCTAssertEqual(all.map(\.isNotCovered), [false, true, true, false])
        XCTAssertEqual(all[1].line, "if count < limit {")
        XCTAssertNil(all[2].line)
        XCTAssertTrue(all[2].lineUnread)
    }

    // A file's row for having no coverage has no key, so it isn't a mutant the run tested.
    func test_theTestedMutants_leaveOutRowsWithoutAKey_andReadEachLine() {
        let path = "/project_mutated/Sources/Rules.swift"
        let outcome = MutationTestOutcome(
            mutations: [
                .make(
                    testSuiteOutcome: .noCoverage,
                    point: .make(
                        mutationOperatorId: .ror,
                        filePath: path,
                        position: .init(utf8Offset: 0, line: 2, column: 12)
                    ),
                    snapshot: .make(before: "<", after: "<="),
                    originalProjectDirectoryUrl: URL(fileURLWithPath: "/project"),
                    mutatedProjectDirectoryURL: URL(fileURLWithPath: "/project_mutated"),
                    key: key(2, column: 12)
                ),
                .make(testSuiteOutcome: .failed, key: nil),
                .make(testSuiteOutcome: .runtimeError, key: key(9)),
                .make(testSuiteOutcome: .buildError, key: key(12)),
            ],
            projectPath: "/project",
            mutatedProjectPath: "/project_mutated"
        )
        let source = "let limit = 3\n  if count < limit {\n}\n"

        let all = Tested.all(of: outcome) { $0 == "/project/Sources/Rules.swift" ? Data(source.utf8) : nil }

        XCTAssertEqual(all.map(\.key), [key(2, column: 12), key(9), key(12)])
        XCTAssertEqual(all.map(\.kind), [.survivor(.notCovered), .killed, .notTested])
        XCTAssertEqual(all.first?.line, "if count < limit {")
    }
}
