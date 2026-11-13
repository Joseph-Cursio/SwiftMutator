@testable import muterCore
import XCTest

extension PerformMutationTestingResumeTests {
    // A resume keeps the example reruns its file records for the results it keeps, so its report splits the kills as
    // the earlier session's did.
    func test_aResume_keepsTheRecordedExampleReruns() async throws {
        let property = FailedTestLine.FailedTest(name: "ordered()", location: "SortProperties.swift:8:5")
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            propertyTests: ["*Properties*"],
            propertyTestFilter: ["Properties"]
        )
        let sum = record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", killedBy: [property])
        state.resumeState = try ResumeState.make(
            lines: [
                ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree),
                record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
                record(of: "Sources/Quotient.swift", line: 4, .runtimeError, fileSHA256: "3c4f"),
                sum,
                ExampleRerunResult.make(of: sum, outcome: .failed),
                record(of: "Sources/Total.swift", line: 8, .timeout, fileSHA256: "9e21"),
                ResultsEnd.make(reason: .interrupted, detail: "SIGINT", testDurationSeconds: 100.5, recorded: 4),
            ],
            file: XCTUnwrap(state.resumeState).file,
            path: resultsPath
        )
        ioDelegate.testSuiteOutcomes = []

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertEqual(outcome.mutations.map(\.exampleRerun?.outcome), [nil, nil, .failed, nil])
    }
}
