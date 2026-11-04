@testable import muterCore
import XCTest

/// Runs mutation testing on real files, with a real test command, a shell script standing for `swift test`, through
/// the real delegate, process factory and time limit. Each log is written once: the file its run wrote in the log
/// folder's `running/` is moved to the name the log is kept under, not copied there and removed.
final class KeptLogFileTests: MuterTestCase {
    private let state = MutationTestState()
    private var root: URL!
    private var logFolder: URL { root.appendingPathComponent("logs") }
    private var mutatedProject: URL { root.appendingPathComponent("project_mutated") }
    private var clone: URL { root.appendingPathComponent("project_mutated_worker1") }

    /// Prints the inode of the file its output goes to, by GNU's `stat` or else BSD's, whose `-f` GNU's takes for a
    /// file system's, and the name of the folder it runs in. `buildSystem: swift`
    /// makes it stand for `swift test`, which adds `--skip-build` to a mutant's run; sh takes that as `$0`.
    private let script = #"""
        exec 3>&1
        printf 'inode %s\n' "$(stat -L -c %i /dev/fd/3 2>/dev/null || stat -L -f %i /dev/fd/3)"
        printf 'in %s\n' "$(basename "$(pwd -P)")"
        """#

    override func setUpWithError() throws {
        try super.setUpWithError()

        root = try URL(fileURLWithPath: makeTemporaryDirectory())
        for folder in [logFolder, mutatedProject, clone] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // A run without a working directory of its own, the baseline in the mutated project, takes it from here.
        fileManager.currentDirectoryPathToReturn = mutatedProject.path
        state.projectDirectoryURL = root.appendingPathComponent("project")
        state.mutatedProjectDirectoryURL = mutatedProject
        state.loggingDirectory = logFolder.path
        state.muterConfiguration = MuterConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", script],
            testSuiteTimeOut: 60,
            buildSystem: .swift,
            mutationTestWorkers: 2
        )
        // A mutant and its repeat, as two of one operator at one place are: their logs are `… .log` and `… (#2).log`.
        state.mutationMapping = try [makeSchemataMapping(), makeSchemataMapping()]
    }

    // The two mutants run at once, one on each worker, and each keeps its own log (#84).
    func test_eachRunsLog_isTheFileItWrote_movedToTheNameItIsKeptUnder() async throws {
        // MuterTestCase.setUp() replaces `current` after setUpWithError(), so these are set here.
        current.ioDelegate = MutationTestingDelegate()
        current.process = { MuterProcessFactory.makeProcess() }
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }
        let sut = PerformMutationTesting(
            makeWorkerDirectories: { [clone] _, _ in [clone] },
            removeWorkerDirectories: { _ in }
        )

        _ = try await sut.run(with: state)

        let kept = try FileManager.default.contentsOfDirectory(atPath: logFolder.path).sorted()
        let mutantLogs = kept.filter { $0.hasPrefix(MutationOperator.Id.ror.rawValue) }
        XCTAssertEqual(kept.count, 5, "\(kept)")
        XCTAssertTrue(kept.contains(MutationTestLog.baselineFileName), "\(kept)")
        XCTAssertTrue(kept.contains("baseline run worker 1.log"), "\(kept)")
        XCTAssertTrue(kept.contains(PerformMutationTesting.testOutputFolderName), "\(kept)")
        XCTAssertEqual(mutantLogs.count, 2, "\(kept)")
        let running = logFolder.appendingPathComponent(PerformMutationTesting.testOutputFolderName).path
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: running), [])

        let first = try XCTUnwrap(mutantLogs.first { !$0.hasSuffix(" (#2).log") })
        let repeated = try XCTUnwrap(mutantLogs.first { $0.hasSuffix(" (#2).log") })
        let (firstLog, repeatedLog) = try (log(first), log(repeated))
        XCTAssertTrue(firstLog.hasSuffix("in project_mutated\n"), firstLog)
        XCTAssertTrue(repeatedLog.hasSuffix("in project_mutated_worker1\n"), repeatedLog)
        for name in [MutationTestLog.baselineFileName, "baseline run worker 1.log", first, repeated] {
            let printed = try XCTUnwrap(try log(name).split(separator: "\n").first, name)
            XCTAssertEqual(printed, "inode \(try inode(of: name))", "\(name) is the file its run wrote")
        }
    }

    // MARK: - Helpers

    private func log(_ name: String) throws -> String {
        try String(contentsOf: logFolder.appendingPathComponent(name), encoding: .utf8)
    }

    private func inode(of name: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: logFolder.appendingPathComponent(name).path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? Int)
    }

    private func makeSchemataMapping() throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/some/path",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/tmp/project/file.swift",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: .firstPosition,
                        snapshot: .null
                    ),
                ]
            )
        )
    }
}
