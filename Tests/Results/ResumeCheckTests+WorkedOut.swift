@testable import muterCore
import XCTest

extension ResumeCheckTests {
    private static let swiftTest = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
    private static let parallel = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test", "--parallel"])

    private func header(of configuration: MuterConfiguration, workedOut: Bool) -> ResultsHeader {
        var recorded = header(of: current(configuration: configuration))
        recorded.configurationWorkedOut = workedOut
        return recorded
    }

    // #263: a configuration change that refuses says which session worked its configuration out, and how to get the
    // last session's again.
    func test_aConfigurationChange_whenEitherSessionWorkedItOut_saysSo() {
        let difference = ResumeCheck.Difference(name: "arguments", was: #"["test"]"#, isNow: #"["test","--parallel"]"#)
        let cases: [(then: Bool, now: Bool)] = [(true, true), (true, false), (false, true)]
        for (then, now) in cases {
            let changed = now ? Self.parallel.workedOutFromTheProject() : Self.parallel

            let verdict = check(current(configuration: changed), recorded: header(of: Self.swiftTest, workedOut: then))

            XCTAssertEqual(
                verdict.refusals,
                [.configurationChanged(difference), .configurationWorkedOut(then: then, now: now)],
                "\(then), \(now)"
            )
        }
        XCTAssertEqual(
            "\(ResumeRefusal.configurationWorkedOut(then: true, now: true))",
            "Both runs worked out their configuration, as there was no muter.conf.yml, so the project or this run's "
                + "options gave a different one. Run with the last session's options, or have `swift-mutator init` "
                + "write this run's configuration to a file and set it back to the last session's, to resume."
        )
        XCTAssertEqual(
            "\(ResumeRefusal.configurationWorkedOut(then: true, now: false))",
            "The last session worked out its configuration, as there was no muter.conf.yml, and this run reads "
                + "muter.conf.yml. Set the file, and this run's options, to the last session's to resume."
        )
        XCTAssertEqual(
            ResumeRefusal.configurationWorkedOut(then: false, now: true).describe(reusing: true),
            "The last session read muter.conf.yml, and this run works out its configuration, as there is none. "
                + "Put the file back, and run with the last session's options, to reuse."
        )
    }

    // The operators the file's keys choose refuse as a change to the selection, which says where the configuration
    // came from too.
    func test_anOperatorChange_fromAFileNow_saysTheLastSessionWorkedItOut() throws {
        let skipping = try MuterConfiguration(
            from: Data("executable: /usr/bin/swift\narguments: [test]\nskipOperators: [RemoveSideEffects]\n".utf8)
        )
        let changed = current(configuration: skipping, operators: ["ROR"])

        let verdict = check(changed, recorded: header(of: Self.swiftTest, workedOut: true))

        XCTAssertEqual(verdict.refusals.count, 2)
        XCTAssertEqual(verdict.refusals.first, .configurationWorkedOut(then: true, now: false))
        XCTAssertEqual(verdict.notices, [])
    }

    // A difference no recorded result depends on goes ahead, and the notice doesn't call the values the same.
    func test_aDifferenceThatChangesNoResult_fromElsewhere_isntCalledTheSameValues() {
        var withWorkers = Self.swiftTest
        withWorkers.mutationTestWorkers = 4

        let verdict = check(current(configuration: withWorkers), recorded: header(of: Self.swiftTest, workedOut: true))

        XCTAssertEqual(verdict.refusals, [])
        XCTAssertEqual(
            verdict.notices.last,
            "The last session worked out its configuration, as there was no muter.conf.yml, and this run reads "
                + "muter.conf.yml: what differs changes no recorded result."
        )
    }

    // The same values from elsewhere change no result: the resume goes ahead, and says where they came from.
    func test_theSameConfiguration_fromElsewhere_goesAhead_withANotice() {
        let fromAFile = check(
            current(configuration: Self.swiftTest),
            recorded: header(of: Self.swiftTest, workedOut: true)
        )
        let workedOut = check(
            current(configuration: Self.swiftTest.workedOutFromTheProject()),
            recorded: header(of: Self.swiftTest, workedOut: false)
        )

        XCTAssertEqual(fromAFile.refusals, [])
        XCTAssertEqual(fromAFile.notices, [
            "The last session worked out its configuration, as there was no muter.conf.yml, and this run reads "
                + "muter.conf.yml, with the same values.",
        ])
        XCTAssertEqual(workedOut.refusals, [])
        XCTAssertEqual(workedOut.notices, [
            "The last session read muter.conf.yml, and this run works out its configuration, as there is none, with "
                + "the same values.",
        ])
    }

    // Both worked out alike, or both read from files: nothing to say. A change with neither worked out says only the
    // change; a merge compares no source.
    func test_noWorkedOutConfiguration_orTheSameOneTwice_saysNothingMore() {
        let twice = check(
            current(configuration: Self.swiftTest.workedOutFromTheProject()),
            recorded: header(of: Self.swiftTest, workedOut: true)
        )
        let neither = check(
            current(configuration: Self.parallel),
            recorded: header(of: Self.swiftTest, workedOut: false)
        )
        let merged = check(
            current(configuration: Self.parallel),
            recorded: header(of: Self.swiftTest, workedOut: true),
            for: .merge
        )

        XCTAssertEqual(twice, ResumeCheck.Verdict())
        XCTAssertEqual(neither.refusals.count, 1)
        XCTAssertEqual(merged.refusals.count, 1)
    }
}
