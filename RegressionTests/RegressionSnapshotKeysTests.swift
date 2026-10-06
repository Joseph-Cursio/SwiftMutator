@testable import muterCore
import SnapshotTesting
import XCTest

/// The regression snapshots leave out what depends on a run's timing, so they don't change from one run to the next.
/// Checked on a report made here, so a plain `swift test`, which has no samples to snapshot, runs it.
final class RegressionSnapshotKeysTests: XCTestCase {
    func test_killingTestKeys_leaveTheSnapshotUnchanged() throws {
        let withKillingTests = MuterTestReport(from: outcome(namingKillingTests: true))
        let withoutKillingTests = MuterTestReport(from: outcome(namingKillingTests: false))

        let unfiltered = try XCTUnwrap(String(data: JSONEncoder().encode(withKillingTests), encoding: .utf8))
        for key in ["killingTests"] {
            XCTAssertTrue(unfiltered.contains("\"\(key)\""), "the report has no \(key) to leave out")
            XCTAssertTrue(RegressionTests.keysToExclude.contains(key), key)
        }
        XCTAssertEqual(snapshot(of: withKillingTests), snapshot(of: withoutKillingTests))
    }
}

private extension RegressionSnapshotKeysTests {
    /// What the regression tests compare with their snapshot.
    func snapshot(of report: MuterTestReport) -> String? {
        var snapshot: String?
        RegressionTests.snapshotting.snapshot(report).run { snapshot = $0 }
        return snapshot
    }

    /// A kill, a crash, a time-out and a survivor in each of two files, with the tests that failed for each, as a run
    /// records them, or with none.
    func outcome(namingKillingTests: Bool) -> MutationTestOutcome {
        let killingTests: [TestSuiteOutcome: MutationTestOutcome.KillingTests] = [
            .failed: .init(
                tests: [
                    .init(name: "sum()", location: "SumTests.swift:3:5"),
                    .init(name: "-[Tests.SumTests testTotal]", location: nil),
                ],
                count: 3,
                isComplete: false
            ),
            .runtimeError: .init(
                tests: [.init(name: "sum()", location: "SumTests.swift:3:5")],
                count: 1,
                isComplete: true
            ),
            .timeout: .init(tests: [], count: 0, isComplete: false),
        ]
        let outcomes: [TestSuiteOutcome] = [.failed, .runtimeError, .timeout, .passed]
        let mutations = ["/project/Sources/Sum.swift", "/project/Sources/Total.swift"].flatMap { path in
            outcomes.enumerated().map { index, outcome in
                MutationTestOutcome.Mutation(
                    testSuiteOutcome: outcome,
                    mutationPoint: MutationPoint(
                        mutationOperatorId: .ror,
                        filePath: path,
                        position: MutationPosition(utf8Offset: index * 40, line: index + 1, column: 5)
                    ),
                    mutationSnapshot: MutationOperator.Snapshot(before: ">", after: "<", description: "changed > to <"),
                    originalProjectDirectoryUrl: URL(fileURLWithPath: "/project"),
                    mutatedProjectDirectoryURL: URL(fileURLWithPath: "/project_mutated"),
                    killingTests: namingKillingTests ? killingTests[outcome] : nil
                )
            }
        }
        return MutationTestOutcome(mutations: mutations)
    }
}
