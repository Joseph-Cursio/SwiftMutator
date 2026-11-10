@testable import muterCore
import XCTest

extension ResumeCheckTests {
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
            check(
                current(filesToMutate: ["Sources/Product.swift", "Sources/Sum.swift", "Sources/Sum.swift"]),
                recorded: recorded
            ),
            ResumeCheck.Verdict()
        )
    }

    func test_aTestPlanRun_resumesWithTheSamePlan() {
        let planned = current(usingTestPlan: true, testPlanSHA256: "91a")

        XCTAssertEqual(check(planned, recorded: header(of: planned)), ResumeCheck.Verdict())
    }

    func test_aChangedTestPlan_refusesTheResume_whateverIsForced() {
        let recorded = header(of: current(usingTestPlan: true, testPlanSHA256: "91a"))
        let changed = ResumeRefusal.testPlanChanged(
            ResumeCheck.Difference(name: "testPlan.sha256", was: #""91a""#, isNow: #""b07""#)
        )

        let planned = current(usingTestPlan: true, testPlanSHA256: "b07")

        XCTAssertEqual(check(planned, recorded: recorded).refusals, [changed])
        XCTAssertEqual(check(planned, recorded: recorded, forcing: true).refusals, [changed])
    }

    func test_aPlanRun_andARunWithoutAPlan_refuseEachOther() {
        let planned = current(usingTestPlan: true, testPlanSHA256: "91a")

        XCTAssertEqual(
            check(current(), recorded: header(of: planned)).refusals,
            [.testPlanRun(recordedUsedOne: true)]
        )
        // Not for want of a project tree, which only a run without a plan is checked for.
        XCTAssertEqual(
            check(current(), recorded: header(of: planned, project: nil)).refusals,
            [.testPlanRun(recordedUsedOne: true)]
        )
        XCTAssertEqual(check(planned, recorded: header(of: current())).refusals, [.testPlanRun(recordedUsedOne: false)])
        XCTAssertEqual(
            check(current(), recorded: header(of: planned), for: .reuse).refusals,
            [.testPlanRun(recordedUsedOne: true)]
        )
    }

    func test_aPlanRunFromBeforePlanRunsResumed_isRefused() {
        // A SwiftMutator from before plan runs resumed recorded neither the plan nor the copy.
        let recorded = header(of: current(usingTestPlan: true), project: nil)

        let planned = current(usingTestPlan: true, testPlanSHA256: "91a")

        XCTAssertEqual(check(planned, recorded: recorded).refusals, [.testPlanNotRecorded])
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

    func test_aPlanRunsCurrentRun_andItsHeader_nameThePlansSHA256() {
        let state = MutationTestState(from: .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json")))
        let plan = LoadedTestPlan(
            path: "/project/muter-mappings.json",
            sha256: "91a",
            formatVersion: TestPlanCoding.formatVersion,
            swiftMutatorVersion: "16",
            scope: nil,
            sources: nil,
            mutatedFiles: nil,
            linkedFiles: nil,
            mutatedPaths: []
        )
        state.apply([.configurationParsed(swift), .testPlanLoaded(plan), .projectTreeFingerprinted(Self.tree)])
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

        XCTAssertEqual(current.testPlanSHA256, "91a")
        XCTAssertEqual(ResumeCheck.Current(header: written).testPlanSHA256, "91a")
        XCTAssertEqual(ResumeCheck.compare(written, with: current, forcing: false), ResumeCheck.Verdict())
    }

    // A run of one mutant tests no other: no whole run resumes or reuses its results, and it resumes none.
    func test_aRunOfOneMutant_andAWholeRun_refuseEachOther_forEveryPurpose() {
        let key = "Sources/Sum.swift:3:4 RelationalOperatorReplacement"
        let alone = header(of: current(mutant: key))

        for purpose in [ResumeCheck.Purpose.resume, .reuse, .merge] {
            XCTAssertEqual(
                check(current(), recorded: alone, for: purpose).refusals,
                [.selectionChanged(.init(name: "mutant", was: #""\#(key)""#, isNow: nil))],
                "\(purpose)"
            )
            XCTAssertEqual(
                check(current(mutant: key), for: purpose).refusals,
                [.selectionChanged(.init(name: "mutant", was: nil, isNow: #""\#(key)""#))],
                "\(purpose)"
            )
        }
        XCTAssertEqual(
            "\(ResumeRefusal.selectionChanged(.init(name: "mutant", was: #""\#(key)""#, isNow: nil)))",
            #"mutant was "\#(key)" and is not set now. A change to which mutants are tested needs a new run."#
        )
        XCTAssertEqual(ResumeCheck.Current(header: alone).mutant, key)
    }

    func test_theStatesCurrentRun_namesTheMutantItChose() {
        let state = MutationTestState(from: .make(mutant: MutantReference(path: "Sum.swift", line: 3)))
        let key = MutantKey(path: "Sources/Sum.swift", mutationOperatorId: .ror, line: 3, column: 4, occurrence: 0)

        XCTAssertNil(ResumeCheck.Current(state: state, provenance: .fixture).mutant)
        state.apply([.mutantSelected(key)])

        XCTAssertEqual(ResumeCheck.Current(state: state, provenance: .fixture).mutant, key.description)
    }
}
