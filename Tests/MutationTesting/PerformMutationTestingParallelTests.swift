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

    func test_outcomesKeepTheMutantsOrder_whenTheirRunsFinishOutOfOrder() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.mutationMapping = try (1...4).map { try makeSchemataMapping(line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .passed] + Array(repeating: .failed, count: 4)
        // The first run to start waits until the last one has started, so the other worker runs the other three
        // mutants meanwhile. The wait is bounded, so the test can't hang.
        let lastRunStarted = DispatchSemaphore(value: 0)
        ioDelegate.whileRunningMutant = { number in
            if number == 0 { _ = lastRunStarted.wait(timeout: .now() + 5) }
            if number == 3 { lastRunStarted.signal() }
        }
        let finishedLines = linesOfPostedOutcomes()

        let result = try await sut.run(with: state)

        XCTAssertNotEqual(finishedLines(), [1, 2, 3, 4], "the runs didn't finish out of order")
        guard case let .mutationTestOutcomeGenerated(outcome) = result.first else {
            return XCTFail("Expected an outcome, got \(result)")
        }
        XCTAssertEqual(outcome.mutations.map(\.point.position.line), [1, 2, 3, 4])
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

    func test_whenCancelled_noFurtherMutantStarts_andNothingMoreIsRecorded() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.mutationMapping = try (1...6).map { try makeSchemataMapping(line: $0) }
        // The baseline, the worker clone's build, then every mutant, in case cancelling doesn't stop them.
        ioDelegate.testSuiteOutcomes = [.passed, .passed] + Array(repeating: .failed, count: 6)
        let recorded = cancelMutationTesting(whenPosted: .newMutationTestOutcomeAvailable)

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(recorded(), 1)
        // The two that started together, and no other.
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 2)
        XCTAssertEqual(removedClones, [[workerClone]])
    }

    // The run under way returns as if it had exited by itself, as a process killed before its run's cancellation
    // handler is in place does.
    func test_whenCancelledWithNoMutantLeftToStart_theRunUnderWayIsNotRecorded() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        let recorded = cancelMutationTesting(whenPosted: .newMutationTestOutcomeAvailable)

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(recorded(), 1)
        XCTAssertEqual(removedClones, [[workerClone]])
    }

    // Each clone costs a copy and about one baseline build, which a stopped run would only throw away. With no run
    // under way to return, mutation testing would also end as if every mutant had been tested.
    func test_whenCancelledBeforeTheFirstMutant_noWorkerIsCloned() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        // The baseline's log is the last thing posted before the worker clones are made.
        _ = cancelMutationTesting(whenPosted: .newTestLogAvailable)

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(removedClones, [])
        XCTAssertFalse(ioDelegate.methodCalls.contains { $0.hasPrefix("runTestSuite") })
    }

    // Stopping the run kills the clones' builds, which then fail. That says nothing about the clones.
    func test_aCancelledWorkerBuild_throwsCancellation_notWorkerBaselineTestFailed() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .buildError]
        let mutationTesting = CancellableTask<[MutationTestState.Change]>()
        ioDelegate.whileRunningBaseline = { worker in
            if worker == 1 { mutationTesting.cancel() }
        }

        let result = await mutationTesting.run { [sut, state] in try await sut.run(with: state) }

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertFalse(ioDelegate.methodCalls.contains { $0.hasPrefix("runTestSuite") })
        XCTAssertEqual(removedClones, [[workerClone]])
    }

    // Stopping the run kills a `cp` under way, which then fails. That says nothing about cloning the project.
    func test_aCloneThatFailsOnceCancelled_throwsCancellation() async throws {
        let sut = PerformMutationTesting(
            makeWorkerDirectories: { [workerClone] _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw PerformMutationTesting.WorkerDirectoryError(clone: workerClone, status: SIGKILL)
            },
            removeWorkerDirectories: { _ in }
        )
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed]

        let result = await Task { [state] in try await sut.run(with: state) }.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(ioDelegate.builtWorkerDirectories, [])
    }

    // A worker's run can finish before one that started earlier, and each outcome is kept as it is recorded, so what
    // a stopped run tested is sorted back into the mutants' order for its partial report.
    func test_anInterruptedRun_postsWhatItRecorded_inJobOrder() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.mutationMapping = try (1...6).map { try makeSchemataMapping(line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .passed] + Array(repeating: .failed, count: 6)
        // The first run to start returns once the third mutant is recorded, and the fourth run to start once the
        // first is, so the first run's mutant is recorded third, after the third mutant. Mutation testing is
        // cancelled then. The waits are bounded, so the test can't hang.
        let thirdMutantRecorded = DispatchSemaphore(value: 0)
        let firstRunRecorded = DispatchSemaphore(value: 0)
        ioDelegate.whileRunningMutant = { number in
            if number == 0 { _ = thirdMutantRecorded.wait(timeout: .now() + 5) }
            if number == 3 { _ = firstRunRecorded.wait(timeout: .now() + 5) }
        }
        var recordedLines: [Int] = []
        whenPosted(.newMutationTestOutcomeAvailable) { notification in
            guard let mutation = notification.object as? MutationTestOutcome.Mutation else { return }
            recordedLines.append(mutation.point.position.line)
            if recordedLines.count == 2 { thirdMutantRecorded.signal() }
            if recordedLines.count == 3 {
                withUnsafeCurrentTask { $0?.cancel() }
                firstRunRecorded.signal()
            }
        }
        var earlyEnds: [EarlyEnd] = []
        whenPosted(.mutationTestingEndedEarly) { notification in
            (notification.object as? EarlyEnd).map { earlyEnds.append($0) }
        }

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(recordedLines.count, 3)
        XCTAssertNotEqual(recordedLines, recordedLines.sorted(), "the runs weren't recorded out of job order")
        XCTAssertEqual(earlyEnds.count, 1)
        let earlyEnd = try XCTUnwrap(earlyEnds.first)
        XCTAssertEqual(earlyEnd.reason, .interrupted)
        XCTAssertEqual(earlyEnd.discovered, 6)
        XCTAssertEqual(earlyEnd.outcome.mutations.map(\.point.position.line), recordedLines.sorted())
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

    // Nothing else would remove them until a later parallel run replaced them.
    func test_whenCloningTheSecondWorkerFails_theFirstCloneAndTheSecondsPartialCopyAreRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project_mutated")
        let source = project.appendingPathComponent("Sources/File.swift")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("let answer = 42".utf8).write(to: source)
        let failingClone = root.appendingPathComponent("project_mutated_worker2")

        XCTAssertThrowsError(
            try PerformMutationTesting.cloneMutatedProject(project, count: 3) { project, clone in
                guard clone.path == failingClone.path else {
                    return try FileManager.default.copyItem(at: project, to: clone)
                }
                // A copy that fails partway through leaves what it had copied.
                try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
                try Data().write(to: clone.appendingPathComponent("partial.o"))
                throw PerformMutationTesting.WorkerDirectoryError(clone: clone, status: 1)
            }
        ) { error in
            XCTAssertEqual((error as? PerformMutationTesting.WorkerDirectoryError)?.clone.path, failingClone.path)
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["project_mutated"])
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "let answer = 42", "the project is intact")
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

    /// Runs mutation testing in a task of its own, so a test that cancels it mid-run doesn't cancel itself.
    private func runInItsOwnTask() async -> Result<[MutationTestState.Change], Error> {
        await Task { [sut, state] in try await sut.run(with: state) }.result
    }

    /// Cancels mutation testing whenever it posts `name`, from the task that posts it; returns how often it did.
    private func cancelMutationTesting(whenPosted name: Notification.Name) -> () -> Int {
        var count = 0
        let observer = notificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
            count += 1
            withUnsafeCurrentTask { $0?.cancel() }
        }
        addTeardownBlock { [notificationCenter] in notificationCenter.removeObserver(observer) }
        return { count }
    }

    /// Calls `handler` with each notification posted with `name`, from the task that posts it, until the test ends.
    private func whenPosted(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
        let observer = notificationCenter.addObserver(forName: name, object: nil, queue: nil, using: handler)
        addTeardownBlock { [notificationCenter] in notificationCenter.removeObserver(observer) }
    }

    /// The line of each mutant whose outcome is posted, in the order they're posted, until the test ends.
    private func linesOfPostedOutcomes() -> () -> [Int] {
        var lines: [Int] = []
        let observer = notificationCenter.addObserver(
            forName: .newMutationTestOutcomeAvailable, object: nil, queue: nil
        ) { notification in
            if let mutation = notification.object as? MutationTestOutcome.Mutation {
                lines.append(mutation.point.position.line)
            }
        }
        addTeardownBlock { [notificationCenter] in notificationCenter.removeObserver(observer) }
        return { lines }
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
