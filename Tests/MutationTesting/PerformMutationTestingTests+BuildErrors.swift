@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingTests {
    func test_whenEncountersFiveConsecutiveBuildErrors_thenCancelMutationTesting() async throws {
        ioDelegate.testSuiteOutcomes = [
            .passed,
            .buildError,
            .buildError,
            .buildError,
            .buildError,
            .buildError,
        ]

        state.mutationMapping = try Array(repeating: makeSchemataMapping(), count: 5)

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .mutationTestingAborted(reason: .tooManyBuildErrors)
        )

        XCTAssertEqual(ioDelegate.methodCalls, [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
        ])
    }

    // A `muter.xctestrun` that couldn't be written still switches on the mutant before. The run stops before the
    // mutant's tests run, rather than record that mutant's verdict for this one, and what it tested is reported.
    func test_whenAMutantCannotBeSwitchedOn_thenMutationTestingStops_beforeItsTestsRun() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
        let error = CocoaError(.fileWriteOutOfSpace)
        ioDelegate.switchOnError = error
        let sent = recordEvents(named: [.mutationTestingEndedEarly])
        let id = try XCTUnwrap(state.mutationMapping.first?.mutationSchemata.first).id

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(reason: .mutantNotSwitchedOn(id: id, description: error.localizedDescription))
        )

        XCTAssertEqual(ioDelegate.methodCalls, [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
        ])
        let earlyEnd = try XCTUnwrap(sent().compactMap { $0.object as? EarlyEnd }.first)
        XCTAssertEqual(earlyEnd.reason, .aborted)
        XCTAssertEqual(earlyEnd.detail, "mutantNotSwitchedOn")
        XCTAssertEqual(earlyEnd.outcome.mutations, [])
    }

    // What an abort tested makes the partial report, the build error that ended it included.
    func test_whenTooManyBuildErrorsAbort_whatWasTestedIsPosted_inJobOrder() async throws {
        state.mutationMapping = try Array(repeating: makeSchemataMapping(), count: 6)
        ioDelegate.testSuiteOutcomes = [.passed, .failed] + Array(repeating: .buildError, count: 5)
        let sent = recordEvents(named: [.mutationTestingEndedEarly])

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(reason: .tooManyBuildErrors)
        )

        let earlyEnds = sent().compactMap { $0.object as? EarlyEnd }
        XCTAssertEqual(earlyEnds.count, 1)
        let earlyEnd = try XCTUnwrap(earlyEnds.first)
        XCTAssertEqual(earlyEnd.reason, .aborted)
        XCTAssertEqual(earlyEnd.detail, "tooManyBuildErrors")
        XCTAssertEqual(earlyEnd.discovered, 6)
        XCTAssertEqual(
            earlyEnd.outcome.mutations.map(\.testSuiteOutcome),
            [.failed] + Array(repeating: .buildError, count: 5)
        )
    }

    // A run that stops after its last mutant's result has every result, so its sample's score has a margin, as
    // `report` of its file gives one. One that stops before it doesn't.
    func test_anEarlyEndsSample_isCutShort_onlyWhenAMutantHasNoResult() async throws {
        let sent = recordEvents(named: [.mutationTestingEndedEarly])
        for mutants in [6, 8] {
            state.mutationMapping = try Array(repeating: makeSchemataMapping(), count: mutants)
            let sample = SampleSelection(size: mutants, seed: 7, mutantsSampledFrom: 20, mutantsSampled: mutants)
            state.apply([.sampleSelected(sample)])
            ioDelegate.testSuiteOutcomes = [.passed, .failed] + Array(repeating: .buildError, count: 5)

            await assertThrowsMuterError(
                try await sut.run(with: state),
                .mutationTestingAborted(reason: .tooManyBuildErrors)
            )
        }

        let earlyEnds = sent().compactMap { $0.object as? EarlyEnd }
        XCTAssertEqual(earlyEnds.map(\.outcome.sampleIsCutShort), [false, true])
    }

    // Nothing was tested, and the abort says why.
    func test_aFailedBaseline_postsNoEarlyEnd() async throws {
        ioDelegate.testSuiteOutcomes = [.failed]
        let sent = recordEvents(named: [.mutationTestingEndedEarly])

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        XCTAssertEqual(sent().count, 0)
    }

    func test_aFinishedRun_postsNoEarlyEnd() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.mutationTestingEndedEarly])

        _ = try await sut.run(with: state)

        XCTAssertEqual(sent().count, 0)
    }

    func test_whenEncountersFiveNonConsecutiveBuildErrors_thenPerformMutationTesting() async throws {
        ioDelegate.mutantActivations = Array(repeating: .unknown, count: 5)
        ioDelegate.testSuiteOutcomes = [
            .passed,
            .buildError,
            .buildError,
            .buildError,
            .buildError,
            .failed,
            .passed,
        ]

        state.mutationMapping = try Array(repeating: makeSchemataMapping(), count: 5)

        let result = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls, [
            // base line
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            // First operator
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",

            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",

            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",

            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",

            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
        ])

        let expectedFailingOutcome = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .failed,
            point: MutationPoint(
                mutationOperatorId: .ror,
                filePath: "/tmp/project/file.swift",
                position: .firstPosition
            ),
            snapshot: .null,
            originalProjectDirectoryUrl: URL(fileURLWithPath: "/project"),
            killingTests: .noneNamed,
            key: fileKey(4),
            durationSeconds: 0
        )

        let expectedTestOutcomes = (0 ..< 4).map(expectedBuildErrorOutcome) + [expectedFailingOutcome]

        var expected = MutationTestOutcome(
            mutations: expectedTestOutcomes,
            projectPath: "/project",
            mutatedProjectPath: "/project_mutated"
        )
        expected.baselineScope = LoadBaselineFile.scope(of: state)
        expected.uncoveredMutants = nil
        XCTAssertEqual(result, [.mutationTestOutcomeGenerated(expected)])
    }

    /// The record of the nth mutant at the start of /tmp/project/file.swift, which didn't build.
    private func expectedBuildErrorOutcome(_ occurrence: Int) -> MutationTestOutcome.Mutation {
        MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .buildError,
            point: MutationPoint(
                mutationOperatorId: .ror,
                filePath: "/tmp/project/file.swift",
                position: .firstPosition
            ),
            snapshot: .null,
            originalProjectDirectoryUrl: URL(fileURLWithPath: "/project"),
            key: fileKey(occurrence),
            durationSeconds: 0
        )
    }
}
