@testable import muterCore
import XCTest

final class ResumeCheckTests: XCTestCase {
    private let swift = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
    private static let tree = ProjectTree(
        listedBy: .git,
        files: ["Sources/Sum.swift": "ab12"],
        excluded: [],
        treeSHA256: "cd34"
    )

    func test_identicalRuns_resume() {
        XCTAssertEqual(check(current()), ResumeCheck.Verdict())
    }

    func test_aChangedConfigurationKey_refuses_namingItsTwoValues() {
        let recorded = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 60)
        let changed = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 120)

        let verdict = check(current(configuration: changed), recorded: header(of: current(configuration: recorded)))

        let difference = ResumeCheck.Difference(name: "mutationTestTimeout", was: "60", isNow: "120")
        XCTAssertEqual(verdict.refusals, [.configurationChanged(difference)])
        XCTAssertEqual(
            "\(ResumeRefusal.configurationChanged(difference))",
            "mutationTestTimeout was 60 and is 120 now. A configuration change needs a new run."
        )
    }

    func test_aConfigurationKeyThatIsSetOnOneSideOnly_isAChange() {
        let timed = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 60)

        let verdict = check(current(configuration: timed))

        let difference = ResumeCheck.Difference(name: "mutationTestTimeout", was: nil, isNow: "60")
        XCTAssertEqual(verdict.refusals, [.configurationChanged(difference)])
        XCTAssertEqual(
            "\(ResumeRefusal.configurationChanged(difference))",
            "mutationTestTimeout was not set and is 60 now. A configuration change needs a new run."
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
        let changed = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], buildTimeout: 1800)

        let verdict = check(current(configuration: changed), recorded: header(of: current(configuration: recorded)))

        XCTAssertEqual(verdict.refusals, [])
        XCTAssertEqual(verdict.notices, ["buildTimeout was 900 and is 1800 now, which no result depends on."])
    }

    func test_everyConfigurationKeyButThree_isCompared() {
        // A new configuration key is compared unless it is added to keysThatDontAffectOutcomes, and fails this test
        // either way, so each one is a decision.
        let verdict = check(
            current(configuration: configurationWithEveryFieldSet()),
            recorded: header(of: current(configuration: MuterConfiguration()))
        )

        XCTAssertEqual(
            verdict.refusals.compactMap(configurationKey),
            ["arguments", "buildSystem", "coverageThreshold", "exclude", "excludeCalls", "executable", "mutationTestTimeout"]
        )
        XCTAssertEqual(verdict.refusals.count, 7)
        XCTAssertEqual(
            verdict.notices,
            [
                "buildTimeout was not set and is 600 now, which no result depends on.",
                "mutationTestWorkers was not set and is 4 now, which no result depends on.",
                "stopAtFirstFailure was not set and is false now, which no result depends on.",
            ]
        )
    }

    func test_configurationValues_areSortedKeysJSON() {
        XCTAssertEqual(
            ResumeCheck.configurationDifferences(MuterConfiguration(), configurationWithEveryFieldSet()),
            [
                .init(name: "arguments", was: "[]", isNow: #"["test"]"#),
                .init(name: "buildSystem", was: nil, isNow: #""swift""#),
                .init(name: "buildTimeout", was: nil, isNow: "600"),
                .init(name: "coverageThreshold", was: "0", isNow: "80"),
                .init(name: "exclude", was: "[]", isNow: #"["Generated"]"#),
                .init(name: "excludeCalls", was: "[]", isNow: #"["print"]"#),
                .init(name: "executable", was: #""""#, isNow: #""/usr/bin/swift""#),
                .init(name: "mutationTestTimeout", was: nil, isNow: "30"),
                .init(name: "mutationTestWorkers", was: nil, isNow: "4"),
                .init(name: "stopAtFirstFailure", was: nil, isNow: "false"),
            ]
        )
    }

    func test_anIntTimeoutAndTheSameDouble_areEqual() throws {
        let written = Data(#"{"executable":"/usr/bin/swift","arguments":["test"],"mutationTestTimeout":60}"#.utf8)
        let recorded = try ResultsCoding.decoder.decode(MuterConfiguration.self, from: written)
        let current = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 60.0)

        XCTAssertEqual(ResumeCheck.configurationDifferences(recorded, current), [])
    }

    func test_aChangedBuildToolchainOrSDKROOT_refuses_unlessForced_andForcingNamesIt() {
        let cases: [(name: String, provenance: Provenance, was: String?, isNow: String?)] = [
            (
                "swiftMutator.executableSHA256",
                provenance(executableSHA256: "b916"),
                #""9f2c""#,
                #""b916""#
            ),
            (
                "toolchain.testCommandVersion",
                provenance(testCommandVersion: "Apple Swift version 6.3.3\nTarget: arm64-apple-macosx26.0"),
                #""Apple Swift version 6.4""#,
                #""Apple Swift version 6.3.3\nTarget: arm64-apple-macosx26.0""#
            ),
            (
                "toolchain.environment",
                provenance(environment: ["SDKROOT": "/Applications/Xcode.app/MacOSX27.0.sdk"]),
                #"{"SDKROOT":"/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"}"#,
                #"{"SDKROOT":"/Applications/Xcode.app/MacOSX27.0.sdk"}"#
            ),
            (
                "toolchain.environment",
                provenance(environment: [:]),
                #"{"SDKROOT":"/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"}"#,
                "{}"
            ),
        ]

        for (name, provenance, was, isNow) in cases {
            let difference = ResumeCheck.Difference(name: name, was: was, isNow: isNow)

            XCTAssertEqual(check(current(provenance: provenance)).refusals, [.needsForce(difference)], name)
            XCTAssertEqual(check(current(provenance: provenance)).forced, [], name)
            XCTAssertEqual(
                check(current(provenance: provenance), forcing: true),
                ResumeCheck.Verdict(forced: [name]),
                name
            )
        }
    }

    func test_needsForce_saysWhatChangedAndThatForceLetsItThrough() {
        XCTAssertEqual(
            "\(ResumeRefusal.needsForce(.init(name: "toolchain.testCommandVersion", was: #""6.3.3""#, isNow: #""6.4""#)))",
            #"The toolchain (toolchain.testCommandVersion) was "6.3.3" and is "6.4" now. "#
                + "--force-resume reuses the results anyway."
        )
        XCTAssertEqual(
            "\(ResumeRefusal.needsForce(.init(name: "swiftMutator.executableSHA256", was: #""9f2c""#, isNow: nil)))",
            #"SwiftMutator (swiftMutator.executableSHA256) was "9f2c" and is unknown now. "#
                + "--force-resume reuses the results anyway."
        )
        XCTAssertEqual(
            "\(ResumeRefusal.needsForce(.init(name: "swiftMutator.executableSHA256", was: nil, isNow: nil)))",
            "SwiftMutator (swiftMutator.executableSHA256) is unknown, so it may have changed. "
                + "--force-resume reuses the results anyway."
        )
    }

    func test_anUnidentifiedBuild_needsForce() {
        let unidentified = provenance(executableSHA256: nil)
        let difference = ResumeCheck.Difference(name: "swiftMutator.executableSHA256", was: nil, isNow: nil)

        let verdict = check(current(provenance: unidentified), recorded: header(of: current(provenance: unidentified)))

        XCTAssertEqual(verdict.refusals, [.needsForce(difference)])
        XCTAssertEqual(
            check(current(provenance: unidentified), recorded: header(of: current()), forcing: true).forced,
            ["swiftMutator.executableSHA256"]
        )
    }

    func test_aToolchainWhoseVersionIsUnknown_needsForce() {
        let unidentified = provenance(testCommandVersion: nil)

        let verdict = check(current(provenance: unidentified), recorded: header(of: current(provenance: unidentified)))

        XCTAssertEqual(
            verdict.refusals,
            [.needsForce(.init(name: "toolchain.testCommandVersion", was: nil, isNow: nil))]
        )
    }

    func test_aWrapperTestCommand_isIdentifiedByItsSHA256_notItsVersion() {
        let wrapper = MuterConfiguration(executable: "/project/Scripts/test.sh", arguments: [])
        let hashed = provenance(testCommandVersion: nil, testExecutableSHA256: "77aa")
        let same = current(configuration: wrapper, provenance: hashed)

        XCTAssertEqual(check(same, recorded: header(of: same)), ResumeCheck.Verdict())

        let edited = current(configuration: wrapper, provenance: provenance(testCommandVersion: nil, testExecutableSHA256: "88bb"))
        XCTAssertEqual(
            check(edited, recorded: header(of: same)).refusals,
            [.needsForce(.init(name: "toolchain.testExecutableSHA256", was: #""77aa""#, isNow: #""88bb""#))]
        )

        let unreadable = current(configuration: wrapper, provenance: provenance(testCommandVersion: nil))
        XCTAssertEqual(
            check(unreadable, recorded: header(of: unreadable)).refusals,
            [.needsForce(.init(name: "toolchain.testExecutableSHA256", was: nil, isNow: nil))]
        )
    }

    func test_whatTheBuildAndToolchainDontIdentify_isNotCompared() {
        let elsewhere = Provenance(
            swiftMutator: .init(
                version: "2.0.0",
                executablePath: "/opt/homebrew/bin/swift-mutator",
                executableSHA256: Provenance.fixture.swiftMutator.executableSHA256
            ),
            toolchain: Provenance.fixture.toolchain,
            processIdentifier: 4321,
            host: "studio.local",
            arguments: ["run", "--resume", "results.jsonl"]
        )

        XCTAssertEqual(check(current(provenance: elsewhere)), ResumeCheck.Verdict())
    }

    func test_forceNeverCoversConfigurationOrSelection() {
        let changed = current(
            configuration: MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test", "--parallel"]),
            operators: ["SwapTernary"],
            provenance: provenance(executableSHA256: "b916")
        )

        let verdict = check(changed, forcing: true)

        XCTAssertEqual(
            verdict.refusals,
            [
                .configurationChanged(.init(name: "arguments", was: #"["test"]"#, isNow: #"["test","--parallel"]"#)),
                .selectionChanged(.init(name: "operators", was: #"["RelationalOperatorReplacement"]"#, isNow: #"["SwapTernary"]"#)),
            ]
        )
        XCTAssertEqual(verdict.forced, ["swiftMutator.executableSHA256"])
    }

    func test_changedOperatorsFilesToMutateOrSkipCoverage_refuse() {
        let cases: [(current: ResumeCheck.Current, difference: ResumeCheck.Difference)] = [
            (
                current(operators: ["RelationalOperatorReplacement", "SwapTernary"]),
                .init(
                    name: "operators",
                    was: #"["RelationalOperatorReplacement"]"#,
                    isNow: #"["RelationalOperatorReplacement","SwapTernary"]"#
                )
            ),
            (
                current(filesToMutate: ["Sources/Sum.swift"]),
                .init(name: "filesToMutate", was: "[]", isNow: #"["Sources/Sum.swift"]"#)
            ),
            (
                current(skipCoverage: false),
                .init(name: "skipCoverage", was: "true", isNow: "false")
            ),
        ]

        for (current, difference) in cases {
            XCTAssertEqual(check(current).refusals, [.selectionChanged(difference)], difference.name)
        }
        XCTAssertEqual(
            "\(ResumeRefusal.selectionChanged(.init(name: "skipCoverage", was: "true", isNow: "false")))",
            "skipCoverage was true and is false now. A change to which mutants are tested needs a new run."
        )
    }

    func test_filesToMutateInAnotherOrder_isTheSameSelection() {
        let recorded = header(of: current(filesToMutate: ["Sources/Sum.swift", "Sources/Product.swift"]))

        XCTAssertEqual(
            check(current(filesToMutate: ["Sources/Product.swift", "Sources/Sum.swift", "Sources/Sum.swift"]), recorded: recorded),
            ResumeCheck.Verdict()
        )
    }

    func test_aTestPlanRun_cannotBeResumed() {
        let planned = current(usingTestPlan: true)

        XCTAssertEqual(check(current(), recorded: header(of: planned, project: nil)).refusals, [.testPlanRun])
        XCTAssertEqual(check(planned, recorded: header(of: current())).refusals, [.testPlanRun])
    }

    func test_aHeaderWithoutAProjectTree_cannotBeResumed() {
        XCTAssertEqual(check(current(), recorded: header(of: current(), project: nil)).refusals, [.noProjectTree])
    }

    func test_theStatesCurrentRun_isWhatItsHeaderRecords() {
        let state = MutationTestState(
            from: .make(
                filesToMutate: ["Sources/Sum.swift"],
                mutationOperatorsList: [.swapTernary, .ror],
                skipCoverage: true
            )
        )
        state.apply([.configurationParsed(swift), .projectTreeFingerprinted(Self.tree)])
        let written = ResultsHeader(
            session: 1,
            startedAt: ResultsHeader.fixedStart,
            state: state,
            logDirectory: "/project_muter_logs/run",
            configuration: swift.withDefaultTestSuiteTimeout(96.5),
            baselineSeconds: 32.125,
            workers: 1,
            mutantsDiscovered: 3,
            mutantsToTest: 3,
            provenance: .fixture
        )

        let current = ResumeCheck.Current(state: state, provenance: .fixture)

        XCTAssertEqual(current.operators, ["RelationalOperatorReplacement", "SwapTernary"])
        XCTAssertEqual(ResumeCheck.compare(written, with: current, forcing: false), ResumeCheck.Verdict())
    }

    // MARK: - Coverage

    // Without coverage in either session, as when both skipped it, or the same coverage in both, discovery has the same
    // to go on.
    func test_coverageInNeitherSession_orTheSameInBoth_isNoChange() {
        let gathered = coverage(78, ["/project_mutated/Sources/Untested.swift"])

        XCTAssertNil(coverageChange(nil, nil))
        XCTAssertNil(coverageChange(gathered, gathered))
    }

    // A session without coverage discovers every mutant, so this is what a change in discovery most often comes from.
    // Only coverage this run has can leave out a mutant the last session discovered, and only coverage the last session
    // had can have left out one this run discovers.
    func test_coverageGatheredInOneSessionOnly_saysWhich_andWhichWayItCanMoveDiscovery() {
        let gathered = coverage(78, ["/project_mutated/Sources/Untested.swift"])

        XCTAssertEqual(coverageChange(nil, gathered), .gatheredOnlyNow)
        XCTAssertEqual(coverageChange(gathered, nil), .gatheredOnlyThen)
        XCTAssertEqual(
            "\(ResumeCheck.CoverageChange.gatheredOnlyNow)",
            "coverage couldn't be gathered then, and is now"
        )
        XCTAssertEqual(
            "\(ResumeCheck.CoverageChange.gatheredOnlyThen)",
            "coverage was gathered then, and couldn't be now"
        )
        XCTAssertTrue(ResumeCheck.CoverageChange.gatheredOnlyNow.isGatheredInOneSessionOnly)
        XCTAssertTrue(ResumeCheck.CoverageChange.gatheredOnlyThen.isGatheredInOneSessionOnly)
        XCTAssertTrue(ResumeCheck.CoverageChange.gatheredOnlyNow.canLeaveOutMutants)
        XCTAssertFalse(ResumeCheck.CoverageChange.gatheredOnlyNow.canBringInMutants)
        XCTAssertFalse(ResumeCheck.CoverageChange.gatheredOnlyThen.canLeaveOutMutants)
        XCTAssertTrue(ResumeCheck.CoverageChange.gatheredOnlyThen.canBringInMutants)
    }

    func test_theSameFilesWithoutCoverage_inAnotherOrder_isNoChange() {
        XCTAssertNil(
            coverageChange(
                coverage(78, ["/project_mutated/Sources/A.swift", "/project_mutated/Sources/B.swift"]),
                coverage(78, ["/project_mutated/Sources/B.swift", "/project_mutated/Sources/A.swift"])
            )
        )
    }

    // xcodebuild names them by their absolute path in the copy, which moves with the project, as when another CI agent
    // resumes the run. SwiftPM names them by their path in the project, which a move leaves as it is.
    func test_theSameFilesWithoutCoverage_inTheCopiesOfAProjectThatMoved_isNoChange() {
        XCTAssertNil(
            ResumeCheck.coverageChange(
                from: coverage(78, ["/agent1/App_mutated/App/Untested.swift"]),
                in: URL(fileURLWithPath: "/agent1/App_mutated"),
                to: coverage(78, ["/agent2/App_mutated/App/Untested.swift"]),
                in: URL(fileURLWithPath: "/agent2/App_mutated")
            )
        )
        XCTAssertNil(
            ResumeCheck.coverageChange(
                from: coverage(78, ["App/Untested.swift"]),
                in: URL(fileURLWithPath: "/agent1/App_mutated"),
                to: coverage(78, ["App/Untested.swift"]),
                in: URL(fileURLWithPath: "/agent2/App_mutated")
            )
        )
        XCTAssertEqual(
            ResumeCheck.coverageChange(
                from: coverage(78, ["/agent1/App_mutated/App/Untested.swift"]),
                in: URL(fileURLWithPath: "/agent1/App_mutated"),
                to: coverage(78, ["/agent2/App_mutated/App/Tested.swift"]),
                in: URL(fileURLWithPath: "/agent2/App_mutated")
            ),
            .filesWithoutCoverageChanged
        )
    }

    // A file without coverage is left out whole, which matters more than the percent, whatever it did. Either way,
    // discovery can find more mutants or fewer.
    func test_otherFilesWithoutCoverage_isAChange_whateverThePercent() {
        let change = coverageChange(
            coverage(78, ["/project_mutated/Sources/A.swift"]),
            coverage(78, ["/project_mutated/Sources/A.swift", "/project_mutated/Sources/B.swift"])
        )

        XCTAssertEqual(change, .filesWithoutCoverageChanged)
        XCTAssertEqual(
            coverageChange(coverage(78, ["/project_mutated/Sources/A.swift"]), coverage(81, [])),
            .filesWithoutCoverageChanged
        )
        XCTAssertEqual(change.map { "\($0)" }, "the files without coverage changed")
        XCTAssertEqual(change?.isGatheredInOneSessionOnly, false)
        XCTAssertEqual(change?.canLeaveOutMutants, true)
        XCTAssertEqual(change?.canBringInMutants, true)
    }

    func test_aChangedPercentAlone_namesBothPercents() {
        let change = coverageChange(
            coverage(78, ["/project_mutated/Sources/A.swift"]),
            coverage(81, ["/project_mutated/Sources/A.swift"])
        )

        XCTAssertEqual(change, .percentChanged(was: 78, isNow: 81))
        XCTAssertEqual(change.map { "\($0)" }, "coverage was 78% and is 81% now")
        XCTAssertEqual(change?.isGatheredInOneSessionOnly, false)
        XCTAssertEqual(change?.canLeaveOutMutants, true)
        XCTAssertEqual(change?.canBringInMutants, true)
    }

    // MARK: - Helpers

    private func coverage(_ percent: Int, _ filesWithoutCoverage: [String]) -> CoverageSummary {
        CoverageSummary(percent: percent, filesWithoutCoverage: filesWithoutCoverage)
    }

    /// The change between two sessions that gathered coverage in the same copy.
    private func coverageChange(
        _ recorded: CoverageSummary?,
        _ current: CoverageSummary?
    ) -> ResumeCheck.CoverageChange? {
        let copy = URL(fileURLWithPath: "/project_mutated")
        return ResumeCheck.coverageChange(from: recorded, in: copy, to: current, in: copy)
    }

    // MARK: - --since

    private static let selected = ChangeSelection.make(
        changedLines: true,
        files: [ChangedFile(path: "Sources/Sum.swift", lines: [LineRange(first: 3, last: 4)], sha256: "ab12")]
    )

    func test_theSameMergeBase_resumes_whateverTheRefIsCalled() {
        let recorded = header(of: current(since: Self.selected))
        let renamed = ChangeSelection.make(ref: "ba5e000", changedLines: true, files: Self.selected.files)

        XCTAssertEqual(check(current(since: renamed), recorded: recorded), ResumeCheck.Verdict())
    }

    func test_sinceGivenOnOneSideOnly_refuses() {
        let verdict = check(current(since: Self.selected))

        let difference = ResumeCheck.Difference(name: "since", was: nil, isNow: #""main""#)
        XCTAssertEqual(verdict.refusals, [.selectionChanged(difference)])
        XCTAssertEqual(
            "\(ResumeRefusal.selectionChanged(difference))",
            #"since was not set and is "main" now. A change to which mutants are tested needs a new run."#
        )
        XCTAssertEqual(
            check(current(), recorded: header(of: current(since: Self.selected))).refusals,
            [.selectionChanged(.init(name: "since", was: #""main""#, isNow: nil))]
        )
    }

    // A ref that moved, as origin/main does after a fetch, names another merge base, and so other changes.
    func test_anotherMergeBase_orChangedLinesTurnedOn_refuses() {
        let recorded = header(of: current(since: .make(files: Self.selected.files)))
        let moved = ChangeSelection.make(mergeBase: "fee1000000000000000000000000000000000000", changedLines: true)

        let verdict = check(current(since: moved), recorded: recorded)

        XCTAssertEqual(verdict.refusals, [
            .selectionChanged(.init(
                name: "since.mergeBase",
                was: #""ba5e000000000000000000000000000000000000""#,
                isNow: #""fee1000000000000000000000000000000000000""#
            )),
            .selectionChanged(.init(name: "since.changedLines", was: "false", isNow: "true")),
        ])
    }

    // The files and lines follow from the working tree: a changed file is compared as the project's files are, and its
    // mutants are tested again; a mutant no longer chosen is one no longer discovered.
    func test_otherFilesOrLines_fromTheSameMergeBase_resume() {
        let recorded = header(of: current(since: Self.selected))
        let edited = ChangeSelection.make(changedLines: true, files: [
            ChangedFile(path: "Sources/Product.swift", sha256: "ef56"),
            ChangedFile(path: "Sources/Sum.swift", lines: [LineRange(first: 3, last: 5)], deletionsAfter: [9], sha256: "ff"),
        ])

        XCTAssertEqual(check(current(since: edited), recorded: recorded).refusals, [])
    }

    // A reuse keeps a result only for a mutant it discovers, which holds whatever else is tested.
    func test_aReuse_doesntCompareWhatSinceChose_eitherWay() {
        let moved = ChangeSelection.make(mergeBase: "fee1000000000000000000000000000000000000")

        XCTAssertEqual(check(current(), recorded: header(of: current(since: Self.selected)), reusing: true).refusals, [])
        XCTAssertEqual(check(current(since: Self.selected), recorded: header(of: current()), reusing: true).refusals, [])
        XCTAssertEqual(
            check(current(since: moved), recorded: header(of: current(since: Self.selected)), reusing: true).refusals,
            []
        )
    }

    private func current(
        configuration: MuterConfiguration? = nil,
        operators: [String] = ["RelationalOperatorReplacement"],
        filesToMutate: [String] = [],
        skipCoverage: Bool = true,
        usingTestPlan: Bool = false,
        provenance: Provenance = .fixture,
        since: ChangeSelection? = nil
    ) -> ResumeCheck.Current {
        ResumeCheck.Current(
            configuration: configuration ?? swift,
            operators: operators,
            filesToMutate: filesToMutate,
            skipCoverage: skipCoverage,
            usingTestPlan: usingTestPlan,
            provenance: provenance,
            since: since
        )
    }

    /// The header a session of `current` wrote.
    private func header(of current: ResumeCheck.Current, project: ProjectTree? = ResumeCheckTests.tree) -> ResultsHeader {
        ResultsHeader.make(
            project: project,
            provenance: current.provenance,
            configuration: current.configuration,
            operators: current.operators,
            filesToMutate: current.filesToMutate,
            skipCoverage: current.skipCoverage,
            usingTestPlan: current.usingTestPlan,
            since: current.since
        )
    }

    /// `current` checked against `recorded`, by default the header of a session with the fixture's run.
    private func check(
        _ current: ResumeCheck.Current,
        recorded: ResultsHeader? = nil,
        forcing: Bool = false,
        reusing: Bool = false
    ) -> ResumeCheck.Verdict {
        ResumeCheck.compare(recorded ?? header(of: self.current()), with: current, forcing: forcing, reusing: reusing)
    }

    private func provenance(
        executableSHA256: String? = Provenance.fixture.swiftMutator.executableSHA256,
        testCommandVersion: String? = Provenance.fixture.toolchain.testCommandVersion,
        testExecutableSHA256: String? = nil,
        environment: [String: String] = Provenance.fixture.toolchain.environment
    ) -> Provenance {
        let fixture = Provenance.fixture
        return Provenance(
            swiftMutator: .init(
                version: fixture.swiftMutator.version,
                executablePath: fixture.swiftMutator.executablePath,
                executableSHA256: executableSHA256
            ),
            toolchain: .init(
                testCommandVersion: testCommandVersion,
                testExecutableSHA256: testExecutableSHA256,
                environment: environment
            ),
            processIdentifier: fixture.processIdentifier,
            host: fixture.host,
            arguments: fixture.arguments
        )
    }

    private func configurationKey(_ refusal: ResumeRefusal) -> String? {
        guard case let .configurationChanged(difference) = refusal else { return nil }
        return difference.name
    }
}
