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
        for key in ["killingTests", "killingTestSummary", "killedOnlyBySuspectTests"] {
            XCTAssertTrue(unfiltered.contains("\"\(key)\""), "the report has no \(key) to leave out")
            XCTAssertTrue(RegressionTests.keysToExclude.contains(key), key)
        }
        XCTAssertEqual(snapshot(of: withKillingTests), snapshot(of: withoutKillingTests))
    }

    // Each mutant's duration and the run's details (its log folder, build, toolchain and settings) differ every run.
    func test_durationAndRunKeys_leaveTheSnapshotUnchanged() throws {
        var timed = outcome(namingKillingTests: false, durationSeconds: 2.412)
        timed.run = try JSONDecoder().decode(RunDetails.self, from: Data(#"""
        {"resultsFiles": ["/project_muter_logs/run/results.jsonl"], "sessions": 1,
         "swiftMutator": {"version": "1.4.0", "executableSHA256": "3f9a"},
         "toolchain": {"testCommandVersion": "Apple Swift version 6.2", "environment": {}},
         "workers": 4, "timeoutSeconds": 24, "timeoutIsDefault": true,
         "configuration": {"executable": "/usr/bin/swift", "arguments": ["test"]}}
        """#.utf8))
        let untimed = outcome(namingKillingTests: false)

        let unfiltered = try XCTUnwrap(String(data: JSONEncoder().encode(MuterTestReport(from: timed)), encoding: .utf8))
        for key in ["durationSeconds", "run"] {
            XCTAssertTrue(unfiltered.contains("\"\(key)\""), "the report has no \(key) to leave out")
            XCTAssertTrue(RegressionTests.keysToExclude.contains(key), key)
        }
        XCTAssertEqual(snapshot(of: MuterTestReport(from: timed)), snapshot(of: MuterTestReport(from: untimed)))
    }
}

private extension RegressionSnapshotKeysTests {
    /// What the regression tests compare with their snapshot.
    func snapshot(of report: MuterTestReport) -> String? {
        var snapshot: String?
        RegressionTests.snapshotting.snapshot(report).run { snapshot = $0 }
        return snapshot
    }

    /// A kill, a crash, a time-out and a survivor in each of ten files, with the tests that failed for each, as a run
    /// records them, or with none, each taking `durationSeconds`, if given. The kills' tests failed in every file, so they are suspect, and each kill is theirs
    /// alone.
    func outcome(namingKillingTests: Bool, durationSeconds: Double? = nil) -> MutationTestOutcome {
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
        let mutations = (0 ..< 10).map { "/project/Sources/File\($0).swift" }.flatMap { path in
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
                    killingTests: namingKillingTests ? killingTests[outcome] : nil,
                    reusedFrom: nil,
                    key: nil,
                    durationSeconds: durationSeconds
                )
            }
        }
        return MutationTestOutcome(mutations: mutations)
    }
}
