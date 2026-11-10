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
            ResumePlan(reused: [0: kept], toRun: [], retestedBecause: [:], retired: [], noLongerDiscovered: 0)
        )
    }

    // A session that stopped before it tested the kill again leaves the first run's line, which proves nothing.
    func test_aKillWhoseCodeDidntRun_andThatWasntTestedAgain_isTestedAgain() {
        let keys = (1...4).map { key(line: $0) }
        var unproven = record(of: keys[0], outcome: .failed)
        unproven.activated = false
        var settled = record(of: keys[1], outcome: .failed)
        settled.activated = false
        settled.rerun = MutantResult.Rerun(because: MutantResult.Rerun.codeNotShownRunning, workers: 1)
        var survivor = record(of: keys[2], outcome: .passed)
        survivor.activated = false
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
        showing.activated = true
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

    // A session that tested more than one mutant at once tests its timeouts again at lower load once the others are
    // tested. One stopped before that, or older than that, didn't, so a resume tests them: retesting a timeout can't
    // lower the score, which counts it as a survivor.
    func test_retestsATimeoutOfASessionOnSeveralWorkers_unlessItWasRunAgain() {
        let keys = (1...5).map { key(line: $0) }
        let rerun = MutantResult.Rerun(because: MutantResult.Rerun.timeout, workers: 1)
        let records = [
            timeout(of: keys[0], session: 1),
            timeout(of: keys[1], session: 1, rerun: rerun),
            timeout(of: keys[2], session: 2),
            // A session whose header is missing may have tested on several workers.
            timeout(of: keys[3], session: 3),
            record(of: keys[4], outcome: .passed),
        ]

        let plan = plan(keys, recorded: records, workers: [1: 4, 2: 1])

        XCTAssertEqual(plan.reused, [1: records[1], 2: records[2], 4: records[4]])
        XCTAssertEqual(plan.toRun, [0, 3])
        XCTAssertEqual(plan.retestedBecause, [.timeoutNotRerun: 2])
        XCTAssertEqual(plan.retired, [keys[0], keys[3]])
    }

    // A longer limit, which `ResumeCheck` let through, tests the timeouts under a shorter one again, run again or not,
    // and nothing else: a run that ended in time under a shorter limit still does.
    func test_aLongerLimit_retestsTheTimeoutsUnderAShorterOne_only() {
        let keys = (1...6).map { key(line: $0) }
        let rerun = MutantResult.Rerun(because: MutantResult.Rerun.timeout, workers: 1)
        let records = [
            timeout(of: keys[0], session: 1),
            timeout(of: keys[1], session: 1, rerun: rerun),
            timeout(of: keys[2], session: 2),
            // A session whose limit is unknown may have had a shorter one.
            timeout(of: keys[3], session: 3),
            record(of: keys[4], outcome: .passed),
            record(of: keys[5], outcome: .failed),
        ]

        let plan = plan(keys, recorded: records, workers: [1: 4, 2: 1, 3: 1], limits: [1: 60, 2: 120], limit: 120)

        XCTAssertEqual(plan.reused, [2: records[2], 4: records[4], 5: records[5]])
        XCTAssertEqual(plan.toRun, [0, 1, 3])
        XCTAssertEqual(plan.retestedBecause, [.timeoutUnderShorterLimit: 3])
        XCTAssertEqual(plan.retired, [keys[0], keys[1], keys[3]])
    }

    // A run under the default limit, which only its baseline sets, has no limit to compare: as before.
    func test_noLimitConfigured_retestsNoTimeoutForItsLimit() {
        let keys = [key(line: 1)]
        let records = [timeout(of: keys[0], session: 1)]

        let plan = plan(keys, recorded: records, workers: [1: 1], limits: [1: 60])

        XCTAssertEqual(plan.reused, [0: records[0]])
        XCTAssertEqual(plan.retestedBecause, [:])
    }

    func test_eachSessionsLimit_comesFromTheLastHeaderOfItsNumber_andOneWithoutIsAbsent() {
        let headers = [
            ResultsHeader.make(session: 1, timeoutSeconds: 60),
            ResultsHeader.make(session: 2, timeoutSeconds: 90),
            ResultsHeader.make(session: 2, timeoutSeconds: 120),
            ResultsHeader.make(session: 3, timeoutSeconds: nil),
        ]

        XCTAssertEqual(ResumePlan.limits(of: headers), [1: 60, 2: 120])
    }

    // A reuse tests every timeout again, run again or not, for the reason it always has.
    func test_aReuse_retestsATimeoutOfASessionOnSeveralWorkers_asATimeout() {
        let keys = [key(line: 1), key(line: 2)]
        let rerun = MutantResult.Rerun(because: MutantResult.Rerun.timeout, workers: 1)
        let records = [timeout(of: keys[0], session: 1), timeout(of: keys[1], session: 1, rerun: rerun)]

        let plan = plan(keys, recorded: records, workers: [1: 4], limits: [1: 60], limit: 120, reusing: changes())

        XCTAssertEqual(plan.toRun, [0, 1])
        XCTAssertEqual(plan.retestedBecause, [.timedOut: 2])
    }

    // As `RecordedResults` reads a session's lines with the last header of its number.
    func test_eachSessionsWorkers_comeFromTheLastHeaderOfItsNumber() {
        let headers = [
            ResultsHeader.make(session: 1, workers: 4),
            ResultsHeader.make(session: 2, workers: 2),
            ResultsHeader.make(session: 2, workers: 1),
        ]

        XCTAssertEqual(ResumePlan.workers(of: headers), [1: 4, 2: 1])
    }

    func test_aReuse_retestsTimeouts_evenWithNothingChanged() {
        // A timeout may be the load the earlier run was under; a resume of the same run keeps it.
        let keys = [key(line: 1), key(line: 2), key(line: 3)]
        let records = [
            record(of: keys[0], outcome: .timeout, endedBy: .timedOut),
            record(of: keys[1], outcome: .passed),
            record(of: keys[2], outcome: .failed),
        ]

        let plan = plan(keys, recorded: records, reusing: changes())

        XCTAssertEqual(plan.reused, [1: records[1], 2: records[2]])
        XCTAssertEqual(plan.toRun, [0])
        XCTAssertEqual(plan.retestedBecause, [.timedOut: 1])
    }

    func test_aReuse_retestsEveryResult_onceAFileOtherThanATestChanged() {
        let keys = [key(line: 1), key("Sources/Product.swift", line: 2)]
        let records = [record(of: keys[0], outcome: .passed), record(of: keys[1], outcome: .failed)]

        let plan = plan(keys, recorded: records, reusing: changes(added: ["Package.resolved"]))

        XCTAssertEqual(plan.reused, [:])
        XCTAssertEqual(plan.toRun, [0, 1])
        XCTAssertEqual(plan.retestedBecause, [.otherFileChanged: 2])
        XCTAssertEqual(plan.retired, [keys[1], keys[0]])
    }

    func test_aReuse_keepsEveryResult_whenAGlobLetEveryOtherChangeThrough() {
        let keys = [key(line: 1), key(line: 2)]
        let records = [record(of: keys[0], outcome: .passed), record(of: keys[1], outcome: .failed)]

        let plan = plan(
            keys,
            recorded: records,
            reusing: changes(added: ["README.md"], waiving: ["README.md"])
        )

        XCTAssertEqual(plan.reused, [0: records[0], 1: records[1]])
        XCTAssertEqual(plan.toRun, [])
    }

    func test_aReuse_afterATestFileChanged_retestsSurvivors_andKillsNoUnchangedTestHolds() {
        // A build error and a changed file's mutant are tested again for their own reasons first.
        let keys = (1...5).map { key(line: $0) } + [key("Sources/Product.swift", line: 6)]
        let records = [
            record(of: keys[0], outcome: .passed),
            record(of: keys[1], outcome: .failed, killedBy: [.init(name: "adds()", location: "SumTests.swift:1:12")]),
            record(
                of: keys[2],
                outcome: .runtimeError,
                killedBy: [.init(name: "moved()", location: "SumTests.swift:9:5")]
            ),
            record(
                of: keys[3],
                outcome: .failed,
                killedBy: [.init(name: "-[SumTests.SumTests testAdds]", location: nil)]
            ),
            record(of: keys[4], outcome: .buildError),
            record(of: keys[5], outcome: .failed, fileSHA256: "0ld"),
        ]

        let plan = plan(
            keys,
            recorded: records,
            reusing: changes(
                added: ["Tests/SumTests/OtherTests.swift"],
                sources: ["Tests/SumTests/OtherTests.swift": "import Testing\n@Test func moved() {}"]
            )
        )

        XCTAssertEqual(plan.reused, [1: records[1]])
        XCTAssertEqual(plan.toRun, [0, 2, 3, 4, 5])
        XCTAssertEqual(plan.retestedBecause, [.testsChanged: 3, .buildError: 1, .fileChanged: 1])
    }

    func test_retiresEveryRecordedKeyItDoesntKeep_includingOnesNoLongerDiscovered_whichItCounts() {
        // A key that was never recorded has nothing to retire. Only the keys no job has any more are counted: a build
        // error is retired too, but tested again.
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
        XCTAssertEqual(plan.noLongerDiscovered, 2)
    }

    func test_everything_testsEveryJob_reusingAndRetiringNothing() {
        XCTAssertEqual(
            ResumePlan.everything(3),
            ResumePlan(reused: [:], toRun: [0, 1, 2], retestedBecause: [:], retired: [], noLongerDiscovered: 0)
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
        snapshot: MutationOperator.Snapshot = mutation,
        killedBy: [FailedTestLine.FailedTest]? = nil
    ) -> MutantResult {
        record(
            of: key,
            outcome: outcome,
            endedBy: endedBy,
            snapshot: snapshot,
            fileSHA256: Self.hashes[key.path],
            killedBy: killedBy
        )
    }

    /// A timeout recorded for `key`'s mutant by `session`, tested in its file as this run's `hashes` has it, and its
    /// `rerun`'s if it was run again.
    private func timeout(of key: MutantKey, session: Int, rerun: MutantResult.Rerun? = nil) -> MutantResult {
        MutantResult.make(
            session: session,
            path: key.path,
            line: key.line,
            column: key.column,
            occurrence: key.occurrence,
            mutationOperatorId: key.mutationOperatorId,
            snapshot: Self.mutation,
            outcome: .timeout,
            endedBy: .timedOut,
            fileSHA256: Self.hashes[key.path],
            rerun: rerun
        )
    }

    /// A result recorded for `key`'s mutant, tested in a file whose hash was `fileSHA256`.
    private func record(
        of key: MutantKey,
        outcome: TestSuiteOutcome = .failed,
        endedBy: TestRun.Ending = .exited,
        snapshot: MutationOperator.Snapshot = mutation,
        fileSHA256: String?,
        killedBy: [FailedTestLine.FailedTest]? = nil
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
            killedBy: killedBy,
            fileSHA256: fileSHA256
        )
    }

    /// A reuse's changes since session 1, from a tree that holds this run's `hashes` and `SumTests.swift`, to one with
    /// `changed` files' hashes changed, `added` added and `removed` removed, with `sources` as the test files' text.
    private func changes(
        changed: [String] = [],
        added: [String] = [],
        waiving globs: [String] = [],
        sources: [String: String] = [:]
    ) -> [Int: ReuseChanges] {
        let files = Self.hashes.merging(["Tests/SumTests/SumTests.swift": "0001"]) { $1 }
        var current = files
        for path in changed + added {
            current[path] = "ffff"
        }
        let sources = sources.merging(
            ["Tests/SumTests/SumTests.swift": "import Testing\n@Test func adds() {}"]
        ) { first, _ in
            first
        }
        return [1: ReuseChanges(from: tree(files), to: tree(current), waiving: globs, readSource: { sources[$0] })]
    }

    private func tree(_ files: [String: String]) -> ProjectTree {
        ProjectTree(listedBy: .git, files: files, excluded: [], treeSHA256: ProjectTree.treeHash(of: files))
    }

    /// The plan for jobs with `keys`, each making `mutation` unless `snapshots` says otherwise.
    private func plan(
        _ keys: [MutantKey],
        recorded records: [MutantResult],
        snapshots: [MutationOperator.Snapshot]? = nil,
        fileHashes: [String: String] = hashes,
        workers: [Int: Int] = [1: 1],
        limits: [Int: Double] = [:],
        limit: Double? = nil,
        reusing changes: [Int: ReuseChanges]? = nil
    ) -> ResumePlan {
        ResumePlan.make(
            keys: keys,
            snapshots: snapshots ?? keys.map { _ in Self.mutation },
            recorded: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }),
            fileHashes: fileHashes,
            workers: workers,
            limits: limits,
            limit: limit,
            reusing: changes
        )
    }
}
