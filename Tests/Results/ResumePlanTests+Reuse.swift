@testable import muterCore
import XCTest

extension ResumePlanTests {
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
            record(of: keys[5], fileSHA256: "0ld", outcome: .failed),
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
}
