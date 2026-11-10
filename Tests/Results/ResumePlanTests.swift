@testable import muterCore
import XCTest

final class ResumePlanTests: XCTestCase {
    func test_reusesARecordWhoseKeyFileAndMutationMatch() {
        let sum = key()
        let kept = record(of: sum)

        XCTAssertEqual(
            plan([sum], recorded: [kept]),
            ResumePlan(reused: [0: kept], toRun: [], retestedBecause: [:], retired: [], noLongerDiscovered: 0)
        )
    }

    // A session that stopped before it tested the kill again leaves the first run's line, which proves nothing.
    func test_aKillWhoseCodeDidntRun_andThatWasntTestedAgain_isTestedAgain() {
        let keys = (1...4).map { key(line: $0) }
        var unproven = record(of: keys[0], outcome: .failed)
        unproven.activated = .didNotRun
        var settled = record(of: keys[1], outcome: .failed)
        settled.activated = .didNotRun
        settled.rerun = MutantResult.Rerun(because: MutantResult.Rerun.codeNotShownRunning, workers: 1)
        var survivor = record(of: keys[2], outcome: .passed)
        survivor.activated = .didNotRun
        // Its session's other runs show they can say, so a run that says nothing, as a crash at launch, is one too.
        let showedNothing = record(of: keys[3], outcome: .runtimeError)

        let made = plan(keys, recorded: [unproven, settled, survivor, showedNothing])

        XCTAssertEqual(made.toRun, [0, 3])
        XCTAssertEqual(made.retestedBecause, [.codeNotShownRunning: 2])
    }

    // A line from before the key, or from a host that can't write, says nothing, and stands. So does a result kept
    // from an earlier run, which this file's session didn't test.
    func test_aKillThatShowsNothing_inASessionThatShowedNothing_orReused_isKept() {
        let keys = (1...3).map { key(line: $0) }
        let older = record(of: keys[0], outcome: .failed)
        var reused = record(of: keys[1], outcome: .failed)
        reused.reusedFrom = ReusedFrom(resultsFile: "/old.jsonl", session: 1, despiteChanges: false)
        XCTAssertEqual(plan(keys, recorded: [older, reused]).toRun, [2])

        var showing = record(of: keys[2], outcome: .passed)
        showing.activated = .ran
        XCTAssertEqual(plan(keys, recorded: [reused, showing]).toRun, [0])
    }

    // Nothing such a session recorded says anything of its mutants, whatever it recorded.
    func test_everyResultOfASessionThatShowedNoCodeRunning_isTestedAgain() {
        let keys = (1...2).map { key(line: $0) }
        let records = [record(of: keys[0], outcome: .passed), record(of: keys[1], outcome: .failed)]

        let made = ResumePlan.make(
            keys: keys,
            snapshots: keys.map { _ in Self.mutation },
            recorded: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }),
            fileHashes: Self.hashes,
            sessionsShowingNoCode: [records[0].session]
        )

        XCTAssertEqual(made.toRun, [0, 1])
        XCTAssertEqual(made.retestedBecause, [.sessionShowedNoCodeRunning: 2])
    }

    func test_reusesKillsSurvivorsAndTimeouts() {
        // A timeout counts in the score like a survivor, so reusing one can never overstate it. The session tested one
        // mutant at a time, as low a load as any.
        let keys = (1...5).map { key(line: $0) }
        let records = [
            record(of: keys[0], outcome: .failed),
            record(of: keys[1], outcome: .failed, endedBy: .stoppedAtFailedTest),
            record(of: keys[2], outcome: .runtimeError),
            record(of: keys[3], outcome: .passed),
            record(of: keys[4], outcome: .timeout, endedBy: .timedOut),
        ]

        let plan = plan(keys, recorded: records)

        XCTAssertEqual(
            plan.reused,
            Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.offset, $0.element) })
        )
        XCTAssertEqual(plan.toRun, [])
        XCTAssertEqual(plan.retestedBecause, [:])
        XCTAssertEqual(plan.retired, [])
    }

    func test_retestsBuildErrors_includingRunsThatCouldNotStart() {
        let keys = [key(line: 1), key(line: 2)]
        let records = [
            record(of: keys[0], outcome: .buildError),
            record(of: keys[1], outcome: .buildError, endedBy: .couldNotRun),
        ]

        let plan = plan(keys, recorded: records)

        XCTAssertEqual(plan.reused, [:])
        XCTAssertEqual(plan.toRun, [0, 1])
        XCTAssertEqual(plan.retestedBecause, [.buildError: 2])
        XCTAssertEqual(plan.retired, keys)
    }

    func test_retestsAMutantInAChangedFile() {
        // E5c: an edit of the same length away from the mutant changes neither its key nor its mutation, only its
        // file's hash. A mutant in a file that didn't change is still reused.
        let sum = key()
        let product = key("Sources/Product.swift")
        let records = [record(of: sum), record(of: product)]

        let plan = plan(
            [sum, product],
            recorded: records,
            fileHashes: ["Sources/Sum.swift": "ef56", "Sources/Product.swift": "cd34"]
        )

        XCTAssertEqual(plan.reused, [1: records[1]])
        XCTAssertEqual(plan.toRun, [0])
        XCTAssertEqual(plan.retestedBecause, [.fileChanged: 1])
        XCTAssertEqual(plan.retired, [sum])
    }

    func test_retestsAChangedMutationAtTheSamePlace() {
        // E5b: `> 0` became `< 0` at the mutant, so its key is the same but its mutation isn't. The file's hash says
        // so too; the mutation says so even when the hash doesn't, as when another SwiftMutator mutates the same
        // place differently.
        let sum = key()
        let earlier = record(of: sum)

        let plan = plan(
            [sum],
            recorded: [earlier],
            snapshots: [.make(before: "<", after: ">", description: "changed < to >")]
        )

        XCTAssertEqual(plan.reused, [:])
        XCTAssertEqual(plan.toRun, [0])
        XCTAssertEqual(plan.retestedBecause, [.mutationChanged: 1])
        XCTAssertEqual(plan.retired, [sum])
    }

    func test_retestsARecordWithoutAFileHash() {
        // Nothing shows such a file is the one that was tested: not a record without a hash, even when this run can't
        // hash the file either, nor a file this run has no hash for, as one outside the project.
        let sum = key()
        let product = key("Sources/Product.swift")
        let outside = key("/elsewhere/Shared.swift")
        let records = [
            record(of: sum, fileSHA256: nil),
            record(of: product, fileSHA256: nil),
            record(of: outside, fileSHA256: "ef56"),
        ]

        let plan = plan([sum, product, outside], recorded: records, fileHashes: ["Sources/Sum.swift": "ab12"])

        XCTAssertEqual(plan.reused, [:])
        XCTAssertEqual(plan.toRun, [0, 1, 2])
        XCTAssertEqual(plan.retestedBecause, [.fileChanged: 3])
    }

    func test_neverReusesAPlaceAndOperatorThatRepeats() {
        // Repeats share a switch ID, so none of their results can be trusted. Another operator at the same place is
        // another mutant, and isn't a repeat.
        let first = key()
        let second = key(occurrence: 1)
        let otherOperator = key(mutationOperator: .logicalOperator)
        let records = [record(of: first), record(of: second), record(of: otherOperator)]

        let plan = plan([first, second, otherOperator], recorded: records)

        XCTAssertEqual(plan.reused, [2: records[2]])
        XCTAssertEqual(plan.toRun, [0, 1])
        XCTAssertEqual(plan.retestedBecause, [.repeated: 2])
        XCTAssertEqual(plan.retired, [first, second])
    }

    func test_ignoresSwitchIDAndOffset() {
        // Both count SwiftMutator's own header and import, so they change with how it prepares the file.
        let sum = key()
        let prepared = MutantResult.make(
            path: sum.path,
            line: sum.line,
            column: sum.column,
            utf8Offset: 9_999,
            switchID: "Sum_RelationalOperatorReplacement_73_22_9999",
            fileSHA256: "ab12"
        )

        XCTAssertEqual(plan([sum], recorded: [prepared]).reused, [0: prepared])
    }

    func test_toRunIsInJobOrder_andEachReasonIsCounted() {
        let keys = [
            key(line: 1),
            key(line: 2),
            key(line: 3),
            key("Sources/Product.swift", line: 4),
            key(line: 5),
            key(line: 6),
            key(line: 6, occurrence: 1),
            key(line: 8),
            key(line: 9),
            key(line: 10),
            key(line: 11),
        ]
        let records = [
            record(of: keys[1]),
            record(of: keys[2], outcome: .buildError),
            record(of: keys[3], fileSHA256: "0ld"),
            record(of: keys[4], snapshot: .make(before: "<", after: ">", description: "changed < to >")),
            record(of: keys[5]),
            record(of: keys[7], outcome: .passed),
            record(of: keys[9], outcome: .timeout, endedBy: .timedOut),
            timeout(of: keys[10], session: 2),
        ]

        let plan = plan(keys, recorded: records, workers: [1: 4, 2: 1], limits: [1: 120, 2: 60], limit: 120)

        XCTAssertEqual(plan.reused, [1: records[0], 7: records[5]])
        XCTAssertEqual(plan.toRun, [0, 2, 3, 4, 5, 6, 8, 9, 10])
        XCTAssertEqual(
            plan.retestedBecause,
            [
                .notRecorded: 2,
                .buildError: 1,
                .fileChanged: 1,
                .mutationChanged: 1,
                .repeated: 2,
                .timeoutNotRerun: 1,
                .timeoutUnderShorterLimit: 1,
            ]
        )
        // Every reason but a reuse's.
        XCTAssertEqual(
            Set(plan.retestedBecause.keys),
            Set(ResumePlan.Reason.allCases).subtracting([
                .timedOut, .otherFileChanged, .testsChanged, .codeNotShownRunning, .sessionShowedNoCodeRunning,
            ])
        )
        XCTAssertEqual(plan.retestedBecause.values.reduce(0, +), plan.toRun.count)
    }
}
