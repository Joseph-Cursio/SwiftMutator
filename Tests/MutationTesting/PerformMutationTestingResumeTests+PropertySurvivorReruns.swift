@testable import muterCore
import XCTest

extension PerformMutationTestingResumeTests {
    // A resume keeps the survivor reruns its file records for the results it keeps, so its report says what they came
    // to, and no survivor is tested again.
    func test_aResume_keepsTheRecordedPropertySurvivorReruns() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            propertyTests: ["*Properties*"],
            propertyTestFilter: ["Properties"],
            propertySurvivorReruns: 5
        )
        let product = record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0")
        state.resumeState = try ResumeState.make(
            lines: [
                ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree),
                product,
                PropertySurvivorRerunResult.make(of: product, outcome: .failed, run: 4, of: 5),
                record(of: "Sources/Quotient.swift", line: 4, .runtimeError, fileSHA256: "3c4f"),
                record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c"),
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
        XCTAssertEqual(outcome.mutations.map(\.propertySurvivorRerun?.failedOnRun), [4, nil, nil, nil])
        XCTAssertEqual(try resultsFiles.records(PropertySurvivorRerunResult.self), [], "none tested again")
    }
}
