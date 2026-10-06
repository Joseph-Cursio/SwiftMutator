@testable import muterCore
import SnapshotTesting
import TestingExtensions
import XCTest

final class RegressionTests: XCTestCase {
    /// Keys left out of the snapshots: where and how long a run took, and the killing tests, their summary and the
    /// kills only suspect tests made, which depend on timing (runs stop at their first failed test). Each is dropped at
    /// any depth, inside arrays too (`recursivelyFiltered`), so the snapshots, which hold none of them, need no
    /// re-recording.
    static let keysToExclude: Set<String> = [
        "filePath", "utf8Offset", "timeElapsed",
        "killingTests",
        "killingTestSummary",
        "killedOnlyBySuspectTests",
    ]

    /// How a report is compared with its snapshot: as JSON, without `keysToExclude`.
    static var snapshotting: Snapshotting<MuterTestReport, String> {
        .json(excludingKeysMatching: { keysToExclude.contains($0) })
    }

    /// These tests read the reports `runRegressionTests.sh` wrote into `samples/`. That script recreates the
    /// folder before it writes anything, so a missing folder means it hasn't been run, not that it failed:
    /// skip, so a plain `swift test` can pass. A run that failed partway leaves the folder, and these tests
    /// then fail.
    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "\(rootTestDirectory)/samples"),
            "No samples: run `make regression-test` to generate them and run these tests"
        )
    }

    func runRegressionTest(
        forFixtureNamed fixtureName: String,
        withResultAt path: FilePath,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) -> Result<Void, MuterError> {
        guard let data = FileManager.default.contents(atPath: path) else {
            return .failure(.literal(reason: "Unable to load a valid Muter test report from \(path)"))
        }

        do {
            let testReport = try JSONDecoder().decode(MuterTestReport.self, from: data)
            assertSnapshot(
                of: testReport,
                as: Self.snapshotting,
                named: fixtureName,
                file: file,
                testName: testName,
                line: line
            )
            return .success(())
        } catch let deserializationError {
            return .failure(
                .literal(reason: """
                Unable to deserialize a valid Muter test report from \(path)

                \(String(data: data, encoding: .utf8) ?? "no-content")

                \(deserializationError)
                """)
            )
        }
    }

    func test_bonMot() {
        let path = "\(rootTestDirectory)/samples/bonmot_regression_test_output.json"
        if case let .failure(MuterError.literal(reason: description)) = runRegressionTest(
            forFixtureNamed: "bonmot",
            withResultAt: path
        ) {
            XCTFail(description.description)
        }
    }

    func test_parseCombinator() {
        let path = "\(rootTestDirectory)/samples/parsercombinator_regression_test_output.json"
        if case let .failure(MuterError.literal(reason: description)) = runRegressionTest(
            forFixtureNamed: "parsercombinator",
            withResultAt: path
        ) {
            XCTFail(description)
        }
    }

    func test_projectWithConcurrency() {
        let path = "\(rootTestDirectory)/samples/projectwithconcurrency_test_output.json"
        if case let .failure(MuterError.literal(reason: description)) = runRegressionTest(
            forFixtureNamed: "projectwithconcurrency",
            withResultAt: path
        ) {
            XCTFail(description)
        }
    }
}

private extension RegressionTests {
    var rootTestDirectory: String {
        String(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .withoutScheme()
        )
    }
}
