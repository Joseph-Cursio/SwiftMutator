@testable import muterCore
import XCTest

final class ResumeCheckTests: XCTestCase {
    func test_identicalRuns_resume() {
        XCTAssertEqual(check(current()), ResumeCheck.Verdict())
    }

    func test_aChangedConfigurationKey_refuses_namingItsTwoValues() {
        let recorded = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], coverageThreshold: 70)
        let changed = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], coverageThreshold: 80)

        let verdict = check(current(configuration: changed), recorded: header(of: current(configuration: recorded)))

        let difference = ResumeCheck.Difference(name: "coverageThreshold", was: "70", isNow: "80")
        XCTAssertEqual(verdict.refusals, [.configurationChanged(difference)])
        XCTAssertEqual(
            "\(ResumeRefusal.configurationChanged(difference))",
            "coverageThreshold was 70 and is 80 now. A configuration change needs a new run."
        )
    }

    // Every result holds under a limit no shorter than any session's, as a run that ended in time still does, but a
    // timeout under a shorter one, which the plan tests again.
    func test_aLimitAtLeastAsLongAsEverySessions_goesAhead_forAResumeOrAReuse() {
        let recorded = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 60)
        let header = header(of: current(configuration: recorded))
        for (limit, longest) in [(120.0, 90.0), (90.0, 90.0)] {
            let longer = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: limit)
            for purpose in [ResumeCheck.Purpose.resume, .reuse] {
                let verdict = check(
                    current(configuration: longer),
                    recorded: header,
                    for: purpose,
                    longestLimit: longest
                )

                XCTAssertEqual(verdict.refusals, [], "\(limit), \(purpose)")
                XCTAssertEqual(
                    verdict.notices,
                    [
                        "mutationTestTimeout was 60 and is \(Int(limit)) now, no shorter than any session's limit: "
                            + "the timeouts under a shorter one are tested again.",
                    ]
                )
            }
        }
    }

    // A default limit, which the baseline set, is the session's in its header: a longer configured one goes ahead.
    func test_aLimitSetWhereNoneWas_goesAhead_ifAtLeastAsLongAsEverySessions() {
        let timed = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 120)

        XCTAssertEqual(check(current(configuration: timed), longestLimit: 109.5).refusals, [])
        XCTAssertEqual(
            check(current(configuration: timed), longestLimit: 120.5).refusals,
            [.configurationChanged(.init(name: "mutationTestTimeout", was: nil, isNow: "120"))]
        )
    }

    // A shorter limit can make a kept kill or survivor a timeout; no limit is a default the baseline sets, after the
    // check; and merged shards must have tested with one configuration.
    func test_aShorterLimit_noLimit_orAMerge_refuses() {
        let limit = { (seconds: Double?) in
            MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: seconds)
        }
        let recorded = header(of: current(configuration: limit(60)))

        XCTAssertEqual(
            check(current(configuration: limit(30)), recorded: recorded, longestLimit: 60).refusals,
            [.configurationChanged(.init(name: "mutationTestTimeout", was: "60", isNow: "30"))]
        )
        XCTAssertEqual(
            check(current(configuration: limit(nil)), recorded: recorded, longestLimit: 60).refusals,
            [.configurationChanged(.init(name: "mutationTestTimeout", was: "60", isNow: nil))]
        )
        XCTAssertEqual(
            check(current(configuration: limit(120)), recorded: recorded, for: .merge, longestLimit: 60).refusals,
            [.configurationChanged(.init(name: "mutationTestTimeout", was: "60", isNow: "120"))]
        )
        // With no limit known for every result, a new one says so.
        let unknown = check(current(configuration: limit(120)), recorded: recorded)
        let difference = ResumeCheck.Difference(name: "mutationTestTimeout", was: "60", isNow: "120")
        XCTAssertEqual(unknown.refusals, [.timeLimitUnknown(difference)])
        XCTAssertEqual(
            "\(ResumeRefusal.timeLimitUnknown(difference))",
            "mutationTestTimeout was 60 and is 120 now. The file doesn't record the time limit every result was "
                + "tested under, as for one --reuse kept, so a new limit needs a new run."
        )
        // Another key is never let through for its value.
        let threshold = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], coverageThreshold: 80)
        XCTAssertEqual(
            check(current(configuration: threshold), longestLimit: 0).refusals,
            [.configurationChanged(.init(name: "coverageThreshold", was: "0", isNow: "80"))]
        )
    }

    // Set where it wasn't, and shorter than the session's limit, which the baseline set.
    func test_aConfigurationKeyThatIsSetOnOneSideOnly_isAChange() {
        let timed = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 60)

        let verdict = check(current(configuration: timed), longestLimit: 96.5)

        let difference = ResumeCheck.Difference(name: "mutationTestTimeout", was: nil, isNow: "60")
        XCTAssertEqual(verdict.refusals, [.configurationChanged(difference)])
        XCTAssertEqual(
            "\(ResumeRefusal.configurationChanged(difference))",
            "mutationTestTimeout was not set and is 60 now. A time limit shorter than a session's, or none, needs a "
                + "new run: one at least as long as every session's only tests timeouts again."
        )
    }

    func test_workersAndStopAtFirstFailure_onlyNotify() {
        let recorded = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 4)
        let changed = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            mutationTestWorkers: 2,
            stopAtFirstFailure: false
        )

        let verdict = check(current(configuration: changed), recorded: header(of: current(configuration: recorded)))

        XCTAssertEqual(verdict.refusals, [])
        XCTAssertEqual(verdict.forced, [])
        XCTAssertEqual(
            verdict.notices,
            [
                "mutationTestWorkers was 4 and is 2 now, which no result depends on.",
                "stopAtFirstFailure was not set and is false now, which no result depends on.",
            ]
        )
    }

    // A limit only stops a step that runs too long, before any mutant is tested.
    func test_aChangedBuildTimeout_onlyNotifies() {
        let recorded = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], buildTimeout: 900)
        let changed = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], buildTimeout: 1_800)

        let verdict = check(current(configuration: changed), recorded: header(of: current(configuration: recorded)))

        XCTAssertEqual(verdict.refusals, [])
        XCTAssertEqual(verdict.notices, ["buildTimeout was 900 and is 1800 now, which no result depends on."])
    }

    // It judges the score once the run finishes, never a mutant's result.
    func test_aChangedFailUnder_onlyNotifies() {
        let recorded = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], failUnder: 80)
        let changed = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], failUnder: 72.5)

        let verdict = check(current(configuration: changed), recorded: header(of: current(configuration: recorded)))

        XCTAssertEqual(verdict.refusals, [])
        XCTAssertEqual(verdict.notices, ["failUnder was 80 and is 72.5 now, which no result depends on."])
    }
}
