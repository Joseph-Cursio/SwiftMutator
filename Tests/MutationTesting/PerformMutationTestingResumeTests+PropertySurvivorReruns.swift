@testable import muterCore
import XCTest

extension PerformMutationTestingResumeTests {
    private static let ordered = "✘ Test ordered() recorded an issue at SortProperties.swift:8:5: Expectation failed"
    private static let threePassed = "✔ Test run with 3 tests in 1 suite passed after 0.4 seconds."

    // A resume with mutants left to test keeps the survivor reruns its file records, tests again only the survivors
    // without one, and reports both.
    func test_aResume_testsAgainOnlyTheSurvivorsWithoutARecordedRerun_andKeepsTheOthers() async throws {
        state.resumeState = try resumeState(limit: nil)
        // The baseline, then Quotient.swift's mutant, which survives, and Total.swift's, which is killed; then the
        // property tests with no mutant on, and Quotient.swift's survivor again, which a property fails for.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        ioDelegate.mutantTestLogs = ["testLog", "testLog", Self.ordered]
        ioDelegate.controlRuns = [(.passed, Self.threePassed)]

        let changes = try await sut.run(with: state)

        let reruns = try resultsFiles.records(PropertySurvivorRerunResult.self)
        XCTAssertEqual(reruns.map(\.path), ["Sources/Quotient.swift"], "not Product.swift's, already recorded")
        XCTAssertEqual(reruns.map(\.run), [1])
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertEqual(outcome.mutations.map(\.propertySurvivorRerun?.failedOnRun), [4, 1, nil, nil])
    }

    // The earlier session's reruns count against the limit, so stopping a run doesn't test more than running it
    // through; with none left, no survivor is tested again, and that is said.
    func test_aResume_countsTheRecordedSurvivorReruns_againstTheLimit() async throws {
        state.resumeState = try resumeState(limit: 1)
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed]
        ioDelegate.mutantTestLogs = ["testLog", "testLog"]
        ioDelegate.controlRuns = [(.passed, Self.threePassed)]
        let sent = recordEvents(named: [.propertySurvivorRerunsStarted, .propertySurvivorRerunsSkipped])

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(PropertySurvivorRerunResult.self), [])
        XCTAssertEqual(sent().map(\.name), [.propertySurvivorRerunsSkipped])
        let (reason, _) = try XCTUnwrap(sent().first?.object as? (String, String?))
        XCTAssertEqual(reason, "the 1 survivor to test is over propertySurvivorRerunLimit")
    }

    /// A stopped run's file that recorded Product.swift's survivor, with a property survivor rerun that a property
    /// failed for on run 4 of 5, and Sum.swift's kill, and never got to Quotient.swift's or Total.swift's mutant: run
    /// on one worker, with `propertySurvivorReruns: 5` and `limit`.
    private func resumeState(limit: Int?) throws -> ResumeState {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            mutationTestWorkers: 1,
            controlRunEvery: 0,
            propertyTests: ["*Properties*"],
            propertyTestFilter: ["Properties"],
            propertySurvivorReruns: 5,
            propertySurvivorRerunLimit: limit
        )
        let product = record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0")
        return try ResumeState.make(
            lines: [
                ResultsHeader.make(
                    mutantsDiscovered: 4, mutantsToTest: 4, project: tree, configuration: state.muterConfiguration
                ),
                product,
                PropertySurvivorRerunResult.make(of: product, outcome: .failed, run: 4, of: 5),
                record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c"),
                ResultsEnd.make(reason: .interrupted, detail: "SIGINT", testDurationSeconds: 100.5, recorded: 2),
            ],
            file: resultsFiles.openForResume(at: resultsPath),
            path: resultsPath,
            provenance: checkedProvenance,
            forced: [],
            notices: []
        )
    }
}
