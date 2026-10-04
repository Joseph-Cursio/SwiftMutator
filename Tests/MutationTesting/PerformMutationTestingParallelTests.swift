@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

/// The default test timeout and parallel workers.
final class PerformMutationTestingParallelTests: MuterTestCase {
    private let state = MutationTestState()
    private let workerClone = URL(fileURLWithPath: "/project_mutated_worker1")
    private var clonedCounts: [Int] = []
    private var removedClones: [[URL]] = []

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [unowned self] _, count in
            clonedCounts.append(count)
            return Array(repeating: workerClone, count: count)
        },
        removeWorkerDirectories: { [unowned self] in removedClones.append($0) }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.mutationMapping = try [makeSchemataMapping(line: 1), makeSchemataMapping(line: 2)]
    }

    func test_withoutATimeout_mutantsGetTheMinimumDefault() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        // The spy's baseline returns at once, so the minimum applies.
        XCTAssertEqual(
            ioDelegate.configurations.map(\.testSuiteTimeout),
            [PerformMutationTesting.minimumDefaultTimeout, PerformMutationTesting.minimumDefaultTimeout]
        )
    }

    func test_aConfiguredTimeoutIsKept() async throws {
        state.muterConfiguration = MuterConfiguration(testSuiteTimeOut: 42)
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), [42, 42])
    }

    func test_withTwoWorkers_eachMutantRunsInAWorkerDirectory() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        // The baseline, the worker clone's build, then the two mutants.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed]

        let result = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [1])
        XCTAssertEqual(removedClones, [[workerClone]])
        XCTAssertEqual(ioDelegate.builtWorkerDirectories, [workerClone])
        XCTAssertEqual(
            ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") },
            Array(repeating: "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:workingDirectory:)", count: 2)
        )
        XCTAssertFalse(ioDelegate.methodCalls.contains("switchOn(schemata:for:at:)"))
        XCTAssertEqual(
            Set(ioDelegate.workingDirectories),
            [state.mutatedProjectDirectoryURL, workerClone]
        )

        // Outcomes keep the mutants' order, whichever worker finished first.
        guard case let .mutationTestOutcomeGenerated(outcome) = result.first else {
            return XCTFail("Expected an outcome, got \(result)")
        }
        XCTAssertEqual(outcome.mutations.map(\.point.position.line), [1, 2])
    }

    func test_workersAreCappedAtTheNumberOfMutants() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 8
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [1], "two mutants need one clone, not seven")
    }

    // The clone is copied after the mutated project was built. Its tests must run from binaries built
    // in the clone, or every path compiled into them, `#filePath` included, still points into the
    // mutated project, and tests that write files next to their sources share them across workers.
    func test_eachWorkerCloneIsBuiltBeforeAnyMutantRunsInIt() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls.prefix(2), [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "benchmarkTests(using:savingResultsIntoFileNamed:workingDirectory:)",
        ])
        XCTAssertEqual(ioDelegate.testLogs.prefix(2), ["baseline run", "baseline run worker 1"])
    }

    func test_aWorkerCloneWhoseBaselineFails_stopsTheRun() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .buildError]

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(
                reason: .workerBaselineTestFailed(worker: 1, directory: workerClone.path, log: "testLog")
            )
        )

        XCTAssertFalse(ioDelegate.methodCalls.contains { $0.hasPrefix("runTestSuite") })
        XCTAssertEqual(removedClones, [[workerClone]])
    }

    func test_withThreeWorkers_everyCloneIsBuilt() async throws {
        let clones = (1...2).map { URL(fileURLWithPath: "/project_mutated_worker\($0)") }
        let sut = PerformMutationTesting(makeWorkerDirectories: { _, _ in clones }, removeWorkerDirectories: { _ in })
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 3
        )
        state.mutationMapping = try (1...3).map { try makeSchemataMapping(line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .passed, .failed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(Set(ioDelegate.builtWorkerDirectories), Set(clones))
        XCTAssertEqual(ioDelegate.builtWorkerDirectories.count, 2)
    }

    // Both clone builds fail, in whichever order they finish; the report names the same worker each time.
    func test_whenWorkerClonesFail_theLowestNumberedWorkerIsNamed() async throws {
        let clones = (1...2).map { URL(fileURLWithPath: "/project_mutated_worker\($0)") }
        let sut = PerformMutationTesting(makeWorkerDirectories: { _, _ in clones }, removeWorkerDirectories: { _ in })
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 3
        )
        state.mutationMapping = try (1...3).map { try makeSchemataMapping(line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .buildError, .failed]

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(
                reason: .workerBaselineTestFailed(worker: 1, directory: clones[0].path, log: "testLog")
            )
        )
    }

    // Clang module caches record the path they were built under, so the clone's own build would fail
    // on the ones copied from the mutated project.
    func test_cloningTheMutatedProject_discardsItsModuleCaches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project_mutated")
        let files = [
            "Sources/File.swift",
            ".build/debug/kept.o",
            ".build/debug/ModuleCache/Swift.pcm",
            ".build/out/Intermediates.noindex/ModuleCache.noindex/Swift.pcm",
        ]
        for file in files {
            let url = project.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }

        let clones = try PerformMutationTesting.cloneMutatedProject(project, count: 1)

        XCTAssertEqual(clones.map(\.path), [root.appendingPathComponent("project_mutated_worker1").path])
        let clone = try XCTUnwrap(clones.first)
        let exists = { (directory: URL, path: String) in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path)
        }
        XCTAssertTrue(exists(clone, "Sources/File.swift"))
        XCTAssertTrue(exists(clone, ".build/debug/kept.o"))
        XCTAssertFalse(exists(clone, ".build/debug/ModuleCache"))
        XCTAssertFalse(exists(clone, ".build/out/Intermediates.noindex/ModuleCache.noindex"))
        XCTAssertTrue(files.allSatisfy { exists(project, $0) }, "the mutated project keeps its caches")
    }

    func test_xcodebuildProjectsIgnoreWorkers() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild", arguments: ["test"], mutationTestWorkers: 4
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(
            ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") },
            Array(repeating: "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)", count: 2)
        )
    }

    private func makeSchemataMapping(line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/some/path",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/tmp/project/file.swift",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line, line: line, column: 0),
                        snapshot: .null
                    ),
                ]
            )
        )
    }
}
