@testable import muterCore
import XCTest

/// Runs a worker's baseline and two of its mutants with a real test command, a shell script standing for
/// `swift test`, through the real process factory, time limit and file writing. SwiftPM keys its cache of
/// compiled package manifests on the whole environment, names and values, so the three runs must get the same
/// environment, and each must still read its own mutant from the worker's active-mutant file.
final class MutantActivationProcessTests: MuterTestCase {
    private let sut = MutationTestingDelegate()
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = try URL(fileURLWithPath: makeTemporaryDirectory())
        // Test logs are written to the current directory; keep them in the folder removed afterwards.
        fileManager.currentDirectoryPathToReturn = directory.path
    }

    func test_aWorkersBaselineAndMutantsShareOneEnvironment_andEachReadsItsOwnMutant() async throws {
        // MuterTestCase.setUp() replaces `current` after setUpWithError(), so these are set here. The
        // active-mutant file is written for real, but only in this test's folder.
        current.process = MuterProcessFactory.makeProcess
        current.writeFile = World().writeFile
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let worker = directory.appendingPathComponent("project_mutated")
        try FileManager.default.createDirectory(at: worker, withIntermediateDirectories: true)
        // `buildSystem: swift` makes it stand for `swift test`, which adds `--skip-build` to a mutant's run;
        // sh takes that as `$0`.
        let configuration = MuterConfiguration(
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"env | LC_ALL=C sort; printf "active=%s\n" "$(cat "$SWIFTMUTATOR_ACTIVE_MUTANT_FILE")""#,
            ],
            testSuiteTimeOut: 60,
            buildSystem: .swift
        )
        let mutantA = try MutationSchema.make(filePath: "/path/Sample.swift", position: .init(line: 1))
        let mutantB = try MutationSchema.make(filePath: "/path/Other.swift", position: .init(line: 2))

        let baseline = try await runTests(of: nil, in: worker, using: configuration)
        let first = try await runTests(of: mutantA, in: worker, using: configuration)
        let second = try await runTests(of: mutantB, in: worker, using: configuration)

        for (name, mutantsRun) in [("mutant A", first), ("mutant B", second)] {
            XCTAssertTrue(
                mutantsRun.environment == baseline.environment,
                "\(name)'s run and the baseline differ in: \(mutantsRun.linesThatDiffer(from: baseline))"
            )
        }
        XCTAssertEqual(baseline.activeMutant, "", "\(baseline.otherOutput)")
        XCTAssertEqual(first.activeMutant, mutantA.id, "\(first.otherOutput)")
        XCTAssertEqual(second.activeMutant, mutantB.id, "\(second.otherOutput)")
        let activeMutantFile = "\(worker.path)/.swiftmutator-active-mutant"
        XCTAssertTrue(
            baseline.environment.contains("\(activeMutantFileKey)=\(activeMutantFile)"),
            "\(baseline.environment.filter { $0.hasPrefix(activeMutantFileKey) })"
        )
    }

    // MARK: - Helpers

    /// What a run's script printed: its environment, sorted, and the mutant it read from the active-mutant file.
    /// A failure shows only the lines that differ, and what isn't a variable, not the values this suite inherited.
    private struct Dump {
        let environment: [String]
        let activeMutant: String?
        /// Lines that aren't a variable, such as an error from `cat`, or SwiftMutator's when it ran nothing.
        let otherOutput: [String]

        init(log: String) {
            let activeMutantPrefix = "active="
            let lines = log.components(separatedBy: "\n").filter { !$0.isEmpty }
            environment = lines.filter { !$0.hasPrefix(activeMutantPrefix) }
            activeMutant = lines.last { $0.hasPrefix(activeMutantPrefix) }
                .map { String($0.dropFirst(activeMutantPrefix.count)) }
            otherOutput = environment.filter { $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) == nil }
        }

        func linesThatDiffer(from other: Dump) -> [String] {
            Set(environment).symmetricDifference(other.environment).sorted()
        }
    }

    /// Runs `mutant`'s tests in `folder`, as a worker runs them, or the worker's baseline when `mutant` is nil.
    /// Cancels the run after 30 seconds, which kills its processes, so a run that never ends fails the test
    /// instead of hanging it. Then waits at most 10 seconds more.
    private func runTests(
        of mutant: MutationSchema?,
        in folder: URL,
        using configuration: MuterConfiguration
    ) async throws -> Dump {
        let logFileName = "\(UUID().uuidString).log"
        let ended = XCTestExpectation(description: "the run ended")
        let run = Task { [sut] in
            let testLog: String
            if let mutant {
                testLog = await sut.runTestSuite(
                    withSchemata: mutant,
                    using: configuration,
                    savingResultsIntoFileNamed: logFileName,
                    workingDirectory: folder
                ).testLog
            } else {
                testLog = await sut.benchmarkTests(
                    using: configuration,
                    savingResultsIntoFileNamed: logFileName,
                    workingDirectory: folder
                ).testLog
            }
            ended.fulfill()
            return testLog
        }
        let deadline = Task {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            run.cancel()
        }
        defer { deadline.cancel() }
        guard await XCTWaiter().fulfillment(of: [ended], timeout: 40) == .completed else {
            return try XCTUnwrap(nil, "the run ignored its cancellation")
        }
        return Dump(log: await run.value)
    }
}
