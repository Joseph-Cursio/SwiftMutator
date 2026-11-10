@testable import muterCore
import XCTest

extension ResumePlanTests {
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
}
