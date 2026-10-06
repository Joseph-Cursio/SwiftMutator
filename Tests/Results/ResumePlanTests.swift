@testable import muterCore
import XCTest

final class ResumePlanTests: XCTestCase {
    /// The mutation every job makes, unless a test says otherwise.
    private static let mutation = MutationOperator.Snapshot.make(before: ">", after: "<", description: "changed > to <")
    /// This run's project files' hashes, unless a test says otherwise.
    private static let hashes = ["Sources/Sum.swift": "ab12", "Sources/Product.swift": "cd34"]

    func test_reusesARecordWhoseKeyFileAndMutationMatch() {
        let sum = key()
        let kept = record(of: sum)

        XCTAssertEqual(
            plan([sum], recorded: [kept]),
            ResumePlan(reused: [0: kept], toRun: [], retestedBecause: [:], retired: [])
        )
    }

    func test_reusesKillsSurvivorsAndTimeouts() {
        // A timeout counts in the score like a survivor, so reusing one can never overstate it.
        let keys = (1...5).map { key(line: $0) }
        let records = [
            record(of: keys[0], outcome: .failed),
            record(of: keys[1], outcome: .failed, endedBy: .stoppedAtFailedTest),
            record(of: keys[2], outcome: .runtimeError),
            record(of: keys[3], outcome: .passed),
            record(of: keys[4], outcome: .timeout, endedBy: .timedOut),
        ]

        let plan = plan(keys, recorded: records)

        XCTAssertEqual(plan.reused, Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.offset, $0.element) }))
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
            utf8Offset: 9999,
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
        ]
        let records = [
            record(of: keys[1]),
            record(of: keys[2], outcome: .buildError),
            record(of: keys[3], fileSHA256: "0ld"),
            record(of: keys[4], snapshot: .make(before: "<", after: ">", description: "changed < to >")),
            record(of: keys[5]),
            record(of: keys[7], outcome: .passed),
        ]

        let plan = plan(keys, recorded: records)

        XCTAssertEqual(plan.reused, [1: records[0], 7: records[5]])
        XCTAssertEqual(plan.toRun, [0, 2, 3, 4, 5, 6, 8])
        XCTAssertEqual(
            plan.retestedBecause,
            [.notRecorded: 2, .buildError: 1, .fileChanged: 1, .mutationChanged: 1, .repeated: 2]
        )
        XCTAssertEqual(Set(plan.retestedBecause.keys), Set(ResumePlan.Reason.allCases))
        XCTAssertEqual(plan.retestedBecause.values.reduce(0, +), plan.toRun.count)
    }

    func test_retiresEveryRecordedKeyItDoesntKeep_includingOnesNoLongerDiscovered() {
        // A key that was never recorded has nothing to retire.
        let kept = key(line: 1)
        let buildError = key(line: 2)
        let neverTested = key(line: 3)
        let noLongerDiscovered = key(line: 4)
        let inADeletedFile = key("Sources/Gone.swift")
        let records = [
            record(of: kept),
            record(of: buildError, outcome: .buildError),
            record(of: noLongerDiscovered),
            record(of: inADeletedFile, fileSHA256: "ef56"),
        ]

        let plan = plan([kept, buildError, neverTested], recorded: records)

        XCTAssertEqual(plan.reused, [0: records[0]])
        XCTAssertEqual(plan.toRun, [1, 2])
        XCTAssertEqual(plan.retired, [inADeletedFile, buildError, noLongerDiscovered])
    }

    func test_everything_testsEveryJob_reusingAndRetiringNothing() {
        XCTAssertEqual(
            ResumePlan.everything(3),
            ResumePlan(reused: [:], toRun: [0, 1, 2], retestedBecause: [:], retired: [])
        )
        XCTAssertEqual(ResumePlan.everything(0).toRun, [])
    }

    private func key(
        _ path: String = "Sources/Sum.swift",
        line: Int = 73,
        mutationOperator: MutationOperator.Id = .ror,
        occurrence: Int = 0
    ) -> MutantKey {
        MutantKey(path: path, mutationOperatorId: mutationOperator, line: line, column: 22, occurrence: occurrence)
    }

    /// A result recorded for `key`'s mutant, tested in its file as this run's `hashes` has it.
    private func record(
        of key: MutantKey,
        outcome: TestSuiteOutcome = .failed,
        endedBy: TestRun.Ending = .exited,
        snapshot: MutationOperator.Snapshot = mutation
    ) -> MutantResult {
        record(of: key, outcome: outcome, endedBy: endedBy, snapshot: snapshot, fileSHA256: Self.hashes[key.path])
    }

    /// A result recorded for `key`'s mutant, tested in a file whose hash was `fileSHA256`.
    private func record(
        of key: MutantKey,
        outcome: TestSuiteOutcome = .failed,
        endedBy: TestRun.Ending = .exited,
        snapshot: MutationOperator.Snapshot = mutation,
        fileSHA256: String?
    ) -> MutantResult {
        MutantResult.make(
            path: key.path,
            line: key.line,
            column: key.column,
            occurrence: key.occurrence,
            mutationOperatorId: key.mutationOperatorId,
            snapshot: snapshot,
            outcome: outcome,
            endedBy: endedBy,
            fileSHA256: fileSHA256
        )
    }

    /// The plan for jobs with `keys`, each making `mutation` unless `snapshots` says otherwise.
    private func plan(
        _ keys: [MutantKey],
        recorded records: [MutantResult],
        snapshots: [MutationOperator.Snapshot]? = nil,
        fileHashes: [String: String] = hashes
    ) -> ResumePlan {
        ResumePlan.make(
            keys: keys,
            snapshots: snapshots ?? keys.map { _ in Self.mutation },
            recorded: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }),
            fileHashes: fileHashes
        )
    }
}
