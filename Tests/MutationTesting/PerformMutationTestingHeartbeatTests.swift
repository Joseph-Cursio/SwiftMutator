@testable import muterCore
import TestingExtensions
import XCTest

/// The mutants under way, sent once none has finished for a minute, so that a log file shows a hung run isn't a slow
/// one.
final class PerformMutationTestingHeartbeatTests: MuterTestCase {
    private let state = MutationTestState()
    /// The seconds the clock has moved on.
    private let clock = Locked<UInt64>(0)

    private lazy var sut = PerformMutationTesting(
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
        state.mutationMapping = try [makeSchemataMapping(lines: [3, 7])]
    }

    // After `setUpWithError`, which `MuterTestCase.setUp` would undo.
    override func setUp() {
        super.setUp()

        current.instant = { [clock] in DispatchTime(uptimeNanoseconds: 1 + clock.value * 1_000_000_000) }
        // A moment, whatever the wait: the clock moves only when a test moves it.
        current.sleep = { _ in try await Task.sleep(nanoseconds: 1_000_000) }
    }

    func test_oneWorker_aMutantThatRunsAMinute_isNamed() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = holdTheRuns(numbered: [0], until: 1)

        _ = try await sut.run(with: state)

        XCTAssertEqual(sent.value, [
            StillTesting(runs: [.init(worker: 0, place: "Sum.swift:3:5", seconds: 75)], workers: 1),
        ])
    }

    func test_twoWorkers_eachWorkersMutantIsNamed() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        // The baseline, the clone's build, then the two mutants.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed]
        let sent = holdTheRuns(numbered: [0, 1], until: 1)

        _ = try await sut.run(with: state)

        XCTAssertEqual(sent.value, [
            StillTesting(
                runs: [
                    .init(worker: 0, place: "Sum.swift:3:5", seconds: 75),
                    .init(worker: 1, place: "Sum.swift:7:5", seconds: 75),
                ],
                workers: 2
            ),
        ])
    }

    func test_mutantsThatFinishWithinAMinute_areNeverNamed() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = Locked<[StillTesting]>([])
        whenSent(.stillTesting) { event in
            (event.object as? StillTesting).map { still in sent.change { $0.append(still) } }
        }
        ioDelegate.whileRunningMutant = { [clock] _ in
            clock.change { $0 += 59 }
            usleep(20_000)
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(sent.value, [])
    }

    /// The events with the mutants under way. The mutant runs `numbered` don't return until they all have started, the
    /// clock has moved on 75 seconds, and `count` such events have been sent, or 5 seconds have passed.
    private func holdTheRuns(numbered numbers: Set<Int>, until count: Int) -> Locked<[StillTesting]> {
        let sent = Locked<[StillTesting]>([])
        whenSent(.stillTesting) { event in
            (event.object as? StillTesting).map { still in sent.change { $0.append(still) } }
        }
        let arrived = Locked(0)
        ioDelegate.whileRunningMutant = { [clock] number in
            guard numbers.contains(number) else { return }
            if arrived.change({ $0 += 1; return $0 }) == numbers.count {
                clock.change { $0 += 75 }
            }
            let deadline = Date().addingTimeInterval(5)
            while sent.value.count < count, Date() < deadline {
                usleep(1_000)
            }
        }
        return sent
    }

    /// Calls `handler` with each event sent with `name`, from the task that sends it, until the test ends.
    private func whenSent(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) {
        let observer = runEvents.observe(name, handler)
        addTeardownBlock { observer.cancel() }
    }

    /// Sum.swift in the mutated project, with a mutant at each of `lines`, column 5.
    private func makeSchemataMapping(lines: [Int]) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/project_mutated/Sources/Sum.swift",
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
            )
        )
    }
}
