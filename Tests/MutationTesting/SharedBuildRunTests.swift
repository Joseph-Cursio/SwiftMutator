@testable import muterCore
import XCTest

/// A SwiftPM run's workers sharing the mutated project's build, rather than each having a clone.
final class SharedBuildRunTests: MuterTestCase {
    private let state = MutationTestState()
    private let project = URL(fileURLWithPath: "/project_mutated.noindex")
    private let named = URL(fileURLWithPath: "/project_mutated_worker1.noindex")
    private let direct = DirectTestRun(
        helper: "/toolchain/swiftpm-testing-helper",
        productsFolder: ".build/out/Products/Debug",
        bundles: ["CoreTests"],
        testFiles: [:],
        platformDeveloperFolder: "/Platforms/MacOSX.platform/Developer",
        arguments: ["--skip-build"]
    )
    private var clonedCounts: [Int] = []
    private var removedClones: [[URL]] = []
    private var choices: [WorkerChoice] = []
    private let readingsTaken = Locked(0)

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [weak self] _, count in
            guard let self else { return [] }
            clonedCounts.append(count)
            return Array(repeating: named, count: count)
        },
        removeWorkerDirectories: { [weak self] in self?.removedClones.append($0) }
    )

    override func setUp() {
        super.setUp()

        current.directTestRun = { [direct] _, _ in .success(direct) }
        readingFiles([sameFiles, sameFiles])
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.mutatedProjectDirectoryURL = project
        state.loggingDirectory = "/logs"
        state.mutationMapping = try [makeSchemataMapping(line: 1), makeSchemataMapping(line: 2)]
        ioDelegate.baselineTestLog = "✔ Test run with 12 tests in 3 suites passed after 0.5 seconds.\n"
        ioDelegate.testRunsWithoutBuilding = [(.passed, ioDelegate.baselineTestLog)]
        whenSent(.workersChosen) { [weak self] event in
            if case let .workersChosen(choice) = event { self?.choices.append(choice) }
        }
    }

    private let sameFiles = ProjectFiles(entries: ["": .init(mode: 1, size: 1, seconds: 1, nanoseconds: 1)])

    /// The readings of the project's files, in order.
    private func readingFiles(_ readings: [ProjectFiles?]) {
        let left = Locked(readings)
        let taken = readingsTaken
        current.projectFiles = { _ in
            taken.change { $0 += 1 }
            return left.change { $0.isEmpty ? nil : $0.removeFirst() }
        }
    }

    func test_aDirectRunThatWroteNothing_needsNoClone() async throws {
        // The baseline, then the two mutants: no clone's baseline.
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(ioDelegate.builtWorkerDirectories, [])
        XCTAssertEqual(Set(ioDelegate.workingDirectories), [project, named], "each worker has its own name")
        XCTAssertEqual(Set(ioDelegate.configurations.map(\.directTestRun?.sharedBuild)), [project])
        XCTAssertEqual(choices.map(\.sharesBuild), [true])
        XCTAssertEqual(removedClones, [[named]], "what's beside each name goes, as it does for a clone")
        XCTAssertEqual(try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first).workers, 2)
    }

    func test_aDirectRunThatWroteInTheProject_getsClones_andSaysWhere() async throws {
        let changed = ProjectFiles(entries: ["Tests": .init(mode: 1, size: 1, seconds: 2, nanoseconds: 1)])
        readingFiles([sameFiles, changed])
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        var said: [String] = []
        whenSent(.testBundlesWroteInTheProject) { event in
            if case let .testBundlesWroteInTheProject(path) = event { said.append(path) }
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [1])
        XCTAssertEqual(said, ["Tests"])
        XCTAssertEqual(Set(ioDelegate.configurations.map(\.directTestRun?.sharedBuild)), [nil])
        XCTAssertEqual(choices.map(\.sharesBuild), [false])
    }

    // No clone to pay back, so the count needs no more mutants than it has workers.
    func test_aSmallRunByDefault_usesEveryWorker() async throws {
        current.processorCount = 18
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutationMapping = try (1...20).map { try makeSchemataMapping(line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 20)

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(choices.map(\.used), [4])
        XCTAssertEqual(choices.map(\.sharesBuild), [true])
        XCTAssertEqual(try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first).workers, 4)
    }

    // A clone is still to pay back, so the same small run tests on one worker, and the notice says why.
    func test_aSmallRunByDefault_thatWroteInTheProject_usesOneWorker_andSaysWhere() async throws {
        current.processorCount = 18
        readingFiles([sameFiles, ProjectFiles(entries: ["Tests": .init(mode: 1, size: 1, seconds: 2, nanoseconds: 1)])])
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutationMapping = try (1...20).map { try makeSchemataMapping(line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 20)
        var said: [String] = []
        whenSent(.testBundlesWroteInTheProject) { event in
            if case let .testBundlesWroteInTheProject(path) = event { said.append(path) }
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(choices.map(\.used), [1])
        XCTAssertEqual(said, ["Tests"])
    }

    func test_filesThatCantBeRead_getClones() async throws {
        readingFiles([nil, nil])
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [1])
    }

    func test_theKey_turnsItOff() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2, workersShareBuild: false
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]

        var said: [String] = []
        whenSent(.testBundlesWroteInTheProject) { event in
            if case let .testBundlesWroteInTheProject(path) = event { said.append(path) }
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [1])
        XCTAssertEqual(choices.map(\.sharesBuild), [false])
        XCTAssertEqual(readingsTaken.value, 0, "no walk of the project, and no notice, for what wasn't asked for")
        XCTAssertEqual(said, [])
    }

    // `swift test` locks the build folder, so only direct runs can share it.
    func test_withoutDirectRuns_workersGetClones() async throws {
        current.directTestRun = { _, _ in .failure(.init(reason: nil)) }
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [1])
        XCTAssertEqual(choices.map(\.sharesBuild), [false])
    }

    func test_oneWorker_hasNothingToShare() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(Set(ioDelegate.configurations.map(\.directTestRun?.sharedBuild)), [nil])
        XCTAssertEqual(choices.map(\.sharesBuild), [false])
        XCTAssertEqual(readingsTaken.value, 0, "no walk of the project, and no notice, with nothing to share")
    }

    private func whenSent(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) {
        let observer = runEvents.observe(name, handler)
        addTeardownBlock { observer.cancel() }
    }

    private func makeSchemataMapping(line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
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
            ),
            filePath: "/some/path"
        )
    }
}
