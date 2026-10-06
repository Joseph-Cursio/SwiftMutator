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

    func test_everyConfigurationKeyButTwo_isCompared() {
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

    // MARK: - Helpers

    private func current(
        configuration: MuterConfiguration? = nil,
        operators: [String] = ["RelationalOperatorReplacement"],
        filesToMutate: [String] = [],
        skipCoverage: Bool = true,
        usingTestPlan: Bool = false,
        provenance: Provenance = .fixture
    ) -> ResumeCheck.Current {
        ResumeCheck.Current(
            configuration: configuration ?? swift,
            operators: operators,
            filesToMutate: filesToMutate,
            skipCoverage: skipCoverage,
            usingTestPlan: usingTestPlan,
            provenance: provenance
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
            usingTestPlan: current.usingTestPlan
        )
    }

    /// `current` checked against `recorded`, by default the header of a session with the fixture's run.
    private func check(
        _ current: ResumeCheck.Current,
        recorded: ResultsHeader? = nil,
        forcing: Bool = false
    ) -> ResumeCheck.Verdict {
        ResumeCheck.compare(recorded ?? header(of: self.current()), with: current, forcing: forcing)
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
