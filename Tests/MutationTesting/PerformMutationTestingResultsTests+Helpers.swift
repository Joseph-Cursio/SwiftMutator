@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingResultsTests {
    /// What `killingLog` names, for a run that exited by itself.
    var sumKilled: MutationTestOutcome.KillingTests {
        MutationTestOutcome.KillingTests(
            tests: [FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:12:5")],
            count: 1,
            isComplete: true
        )
    }

    /// The outcome mutation testing that made `changes` reports, if it made one.
    func outcome(of changes: [MutationTestState.Change]) -> MutationTestOutcome? {
        guard case let .mutationTestOutcomeGenerated(outcome)? = changes.first else { return nil }
        return outcome
    }

    /// Records every event sent with one of `names`, in order, until the test ends.
    func recordEvents(named names: [RunEvent.Name]) -> () -> [RunEvent] {
        var sent: [RunEvent] = []
        for name in names {
            whenSent(name) { sent.append($0) }
        }
        return { sent }
    }

    /// Mutation testing whose worker clone is `workerClone`, and whose clone removal records the kinds of the results
    /// lines written by then, once for each removal.
    func removingClonesRecordsTheResultsLines() -> (sut: PerformMutationTesting, kindsAtEach: () -> [[String]]) {
        var kindsAtEach: [[String]] = []
        let sut = PerformMutationTesting(
            makeWorkerDirectories: { [workerClone] _, count in Array(repeating: workerClone, count: count) },
            removeWorkerDirectories: { [workerClone, resultsFiles] clones in
                XCTAssertEqual(clones, [workerClone])
                kindsAtEach.append((try? resultsFiles.kinds()) ?? [])
            }
        )
        return (sut, { kindsAtEach })
    }

    /// Calls `handler` with each event sent with `name`, from the task that sends it, until the test ends.
    func whenSent(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) {
        let observer = runEvents.observe(name, handler)
        addTeardownBlock { observer.cancel() }
    }

    /// A tree of `files`, each a path relative to the project and its hash.
    func makeProjectTree(_ files: [String: String]) -> ProjectTree {
        ProjectTree(listedBy: .git, files: files, excluded: [], treeSHA256: ProjectTree.treeHash(of: files))
    }

    /// A file in the mutated project with one mutant, at `line`, column 5.
    func makeSchemataMapping(file: String, line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/project_mutated/\(file)",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line * 10, line: line, column: 5),
                        snapshot: .make(before: ">", after: "<", description: "changed > to <")
                    ),
                ]
            ),
            filePath: "/project_mutated/\(file)"
        )
    }
}
