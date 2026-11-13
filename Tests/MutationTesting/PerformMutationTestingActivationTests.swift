@testable import muterCore
import TestingExtensions
import XCTest

/// What a run does with whether each mutant's block ran (`TestRun.activated`): a survivor whose block didn't is not
/// covered, a kill whose block didn't is tested again, and a run that shows nothing either way leaves every verdict as
/// it was, or stops, where it should have shown something.
final class PerformMutationTestingActivationTests: MuterTestCase {
    private static let path = "Sources/Sum.swift"
    private static let hash = "ab12"
    let state = MutationTestState()

    lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { _, count in
            (0 ..< count).map { URL(fileURLWithPath: "/project_mutated_worker\($0 + 1)") }
        },
        removeWorkerDirectories: { _ in }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        state.muterConfiguration = swiftTest(workers: 1)
        state.mutationMapping = try [makeMapping(lines: Array(1...2))]
        let files = [Self.path: Self.hash]
        state.projectTree = ProjectTree(
            listedBy: .git, files: files, excluded: [], treeSHA256: ProjectTree.treeHash(of: files)
        )
    }

    // MARK: - Survivors

    // The line keeps the run's own outcome, which reads as a survivor to anything older, and says its block didn't run.
    func test_aSurvivorWhoseBlockDidntRun_isNotCovered_andItsLineStillSaysItPassed() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .passed]
        ioDelegate.mutantActivations = [.didNotRun, .ran]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.noCoverage, .passed])
        XCTAssertEqual(outcome.mutations.map(\.activated), [.didNotRun, .ran])
        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.map(\.outcome), [.passed, .passed])
        XCTAssertEqual(records.map(\.activated), [.didNotRun, .ran])
    }

    // Both count alike in the score, which is #89's to change.
    func test_aMutantNotCovered_countsInTheScoreAsASurvivorDoes() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantActivations = [.ran, .didNotRun]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .noCoverage])
        XCTAssertEqual(MuterTestReport(from: outcome).globalMutationScore, 50)
    }

    func test_aSurvivorThatShowsNothing_staysASurvivor_andItsLineSaysNothing() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .passed]
        ioDelegate.mutantActivations = [.unknown, .ran]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .passed])
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.activated), [.unknown, .ran])
    }

    func test_theResultsFile_readsAsTheRunReportedIt() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed]
        ioDelegate.mutantActivations = [.didNotRun, .ran]

        let outcome = try await run()

        let recorded = try RecordedResults.read(Data(resultsFiles.lines.joined(separator: "\n").utf8), path: "/logs/r")
            .mutationTestOutcome(resultsFile: "/logs/r")
        XCTAssertEqual(recorded.mutations.map(\.testSuiteOutcome), outcome.mutations.map(\.testSuiteOutcome))
        XCTAssertEqual(recorded.mutations.map(\.activated), outcome.mutations.map(\.activated))
    }

    // MARK: - Helpers

    func swiftTest(workers: Int) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 42, mutationTestWorkers: workers
        )
    }

    func givenFiveMutantsThatShowNothing() {
        // Six, so a run that didn't stop tests one more than the stop allows.
        state.mutationMapping = (try? [makeMapping(lines: Array(1...6))]) ?? []
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .passed, count: 6)
        ioDelegate.mutantActivations = Array(repeating: .unknown, count: 6)
    }

    /// The plan of a `--resume` of the results file as it stands, with every file as it was recorded.
    func planFromTheLines() throws -> ResumePlan {
        let recorded = try RecordedResults.read(Data(resultsFiles.lines.joined(separator: "\n").utf8), path: "/logs/r")
        let keys = recorded.latest.keys.sorted { $0.description < $1.description }
        return ResumePlan.make(
            keys: keys,
            snapshots: keys.map { recorded.latest[$0]?.snapshot ?? .null },
            recorded: recorded.latest,
            fileHashes: [Self.path: Self.hash],
            workers: ResumePlan.workers(of: recorded.headers),
            limits: ResumePlan.limits(of: recorded.headers),
            sessionsShowingNoCode: ResumePlan.showingNoCode(recorded.sessions)
        )
    }

    func run() async throws -> MutationTestOutcome {
        let changes = try await sut.run(with: state)
        guard case let .mutationTestOutcomeGenerated(outcome)? = changes.first else {
            throw MuterError.literal(reason: "Expected an outcome, got \(changes)")
        }
        return outcome
    }

    func recordEvents(named names: [RunEvent.Name]) -> () -> [RunEvent] {
        var sent: [RunEvent] = []
        let observer = runEvents.observe { event in
            if names.contains(event.name) { sent.append(event) }
        }
        addTeardownBlock { observer.cancel() }
        return { sent }
    }

    func makeMapping(lines: [Int]) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            (
                source: "func bar() { }",
                schemata: lines.map { line in
                    try .make(
                        filePath: "/project_mutated/Sources/Sum.swift",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line * 10, line: line, column: 5),
                        snapshot: .make(before: ">", after: "<", description: "changed > to <")
                    )
                }
            ),
            filePath: "/project_mutated/Sources/Sum.swift"
        )
    }
}
