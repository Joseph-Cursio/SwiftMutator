@testable import muterCore
import XCTest

extension ResumeCheckTests {
    func test_everyConfigurationKeyButSeven_isCompared() {
        // A new configuration key is compared unless it is added to keysThatDontAffectOutcomes, and fails this test
        // either way, so each one is a decision.
        let verdict = check(
            current(configuration: configurationWithEveryFieldSet()),
            recorded: header(of: current(configuration: MuterConfiguration())),
            // Longer than its limit, 30 s.
            longestLimit: 60
        )

        XCTAssertEqual(
            verdict.refusals.compactMap(configurationKey),
            [
                "arguments",
                "buildSystem",
                "coverageThreshold",
                "exclude",
                "excludeCalls",
                "executable",
                "mutationTestTimeout",
            ]
        )
        // And the reason more that this run worked its configuration out, as the fixture's is.
        XCTAssertEqual(verdict.refusals.count, 8)
        XCTAssertEqual(verdict.refusals.last, .configurationWorkedOut(then: false, now: true))
        XCTAssertEqual(
            verdict.notices,
            [
                "buildTimeout was not set and is 600 now, which no result depends on.",
                "controlRunEvery was not set and is 50 now, which no recorded result depends on, though it chooses "
                    + "which kills are tested again alone.",
                "failUnder was not set and is 80 now, which no result depends on.",
                "keepAllLogs was not set and is true now, which no result depends on.",
                "keepLogFolders was not set and is 3 now, which no result depends on.",
                "keepSwiftLintPhases was not set and is true now, which no result depends on.",
                "mutationTestWorkers was not set and is 4 now, which no result depends on.",
                "oneWorkerSimulator was not set and is true now, which no result depends on.",
                #"propertyTestFilter was not set and is ["Properties"] now, which no result depends on."#,
                #"propertyTests was not set and is ["*Properties*"] now, which no result depends on."#,
                #"reports was not set and is ["markdown:summary.md"] now, which no result depends on."#,
                "stopAtFirstFailure was not set and is false now, which no result depends on.",
                "suspectKillReruns was not set and is 25 now, which no recorded result depends on, though it chooses "
                    + "which kills are tested again alone.",
                "suspectTestFilePercent was not set and is 30 now, which no recorded result depends on, though it "
                    + "chooses which kills are tested again alone.",
                "suspectTestMinimumFiles was not set and is 5 now, which no recorded result depends on, though it "
                    + "chooses which kills are tested again alone.",
                "workersShareBuild was not set and is false now, which no result depends on.",
            ]
        )
    }

    // Where one worker tests, on the destination or on a simulator of its own, can change a kill's kind, but not
    // whether it is killed.
    func test_aChangedOneWorkerSimulator_onlyNotifies() {
        let recorded = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        let changed = MuterConfiguration(
            executable: "/usr/bin/xcodebuild", arguments: ["test"], oneWorkerSimulator: .enabled
        )

        let verdict = check(current(configuration: changed), recorded: header(of: current(configuration: recorded)))

        XCTAssertEqual(verdict.refusals, [])
        XCTAssertEqual(verdict.forced, [])
        XCTAssertEqual(
            verdict.notices, ["oneWorkerSimulator was not set and is true now, which no result depends on."]
        )
    }

    // The operators themselves are compared, however they were chosen, so the keys that choose them say nothing more.
    func test_keysChoosingTheSameOperators_areNoDifference() {
        let recorded = current(configuration: MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], operators: [.ror, .swapTernary]
        ))
        let changed = current(configuration: MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], skipOperators: [.logicalOperator]
        ))

        let verdict = check(changed, recorded: header(of: recorded))

        XCTAssertEqual(verdict.refusals, [])
        XCTAssertEqual(verdict.notices, [])
    }

    func test_keysChoosingOtherOperators_refuseOnce_byTheOperators() {
        let recorded = current(configuration: MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], operators: [.ror]
        ))
        let changed = current(
            configuration: MuterConfiguration(
                executable: "/usr/bin/swift", arguments: ["test"], operators: [.swapTernary]
            ),
            operators: ["SwapTernary"]
        )

        let verdict = check(changed, recorded: header(of: recorded))

        XCTAssertEqual(verdict.refusals, [
            .selectionChanged(.init(
                name: "operators", was: #"["RelationalOperatorReplacement"]"#, isNow: #"["SwapTernary"]"#
            )),
        ])
        XCTAssertEqual(verdict.notices, [])
    }

    func test_configurationValues_areSortedKeysJSON() {
        XCTAssertEqual(
            ResumeCheck.configurationDifferences(MuterConfiguration(), configurationWithEveryFieldSet()),
            [
                .init(name: "arguments", was: "[]", isNow: #"["test"]"#),
                .init(name: "buildSystem", was: nil, isNow: #""swift""#),
                .init(name: "buildTimeout", was: nil, isNow: "600"),
                .init(name: "controlRunEvery", was: nil, isNow: "50"),
                .init(name: "coverageThreshold", was: "0", isNow: "80"),
                .init(name: "exclude", was: "[]", isNow: #"["Generated"]"#),
                .init(name: "excludeCalls", was: "[]", isNow: #"["print"]"#),
                .init(name: "executable", was: #""""#, isNow: #""/usr/bin/swift""#),
                .init(name: "failUnder", was: nil, isNow: "80"),
                .init(name: "keepAllLogs", was: nil, isNow: "true"),
                .init(name: "keepLogFolders", was: nil, isNow: "3"),
                .init(name: "keepSwiftLintPhases", was: nil, isNow: "true"),
                .init(name: "mutationTestTimeout", was: nil, isNow: "30"),
                .init(name: "mutationTestWorkers", was: nil, isNow: "4"),
                .init(name: "oneWorkerSimulator", was: nil, isNow: "true"),
                .init(name: "operators", was: nil, isNow: #"["RelationalOperatorReplacement","SwapTernary"]"#),
                .init(name: "propertyTestFilter", was: nil, isNow: #"["Properties"]"#),
                .init(name: "propertyTests", was: nil, isNow: #"["*Properties*"]"#),
                .init(name: "reports", was: nil, isNow: #"["markdown:summary.md"]"#),
                .init(name: "skipOperators", was: nil, isNow: #"["SwapTernary"]"#),
                .init(name: "stopAtFirstFailure", was: nil, isNow: "false"),
                .init(name: "suspectKillReruns", was: nil, isNow: "25"),
                .init(name: "suspectTestFilePercent", was: nil, isNow: "30"),
                .init(name: "suspectTestMinimumFiles", was: nil, isNow: "5"),
                .init(name: "workersShareBuild", was: nil, isNow: "false"),
            ]
        )
    }

    // `--exclude`'s entries come after the file's, and choose the same files in any order.
    func test_excludeEntriesInAnotherOrder_areEqual() {
        let recorded = MuterConfiguration(executable: "/swift", arguments: [], excludeList: ["/Gen/", "!/Stubs/"])
        let current = MuterConfiguration(executable: "/swift", arguments: [], excludeList: ["!/Stubs/", "/Gen/"])
        XCTAssertEqual(ResumeCheck.configurationDifferences(recorded, current), [])

        let other = MuterConfiguration(executable: "/swift", arguments: [], excludeList: ["/Gen/"])
        XCTAssertEqual(ResumeCheck.configurationDifferences(recorded, other).map(\.name), ["exclude"])
    }

    func test_anIntTimeoutAndTheSameDouble_areEqual() throws {
        let written = Data(#"{"executable":"/usr/bin/swift","arguments":["test"],"mutationTestTimeout":60}"#.utf8)
        let recorded = try ResultsCoding.decoder.decode(MuterConfiguration.self, from: written)
        let current = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 60.0)

        XCTAssertEqual(ResumeCheck.configurationDifferences(recorded, current), [])
    }
}
