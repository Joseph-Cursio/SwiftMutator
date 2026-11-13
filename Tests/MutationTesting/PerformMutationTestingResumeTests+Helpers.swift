@testable import muterCore
import XCTest

extension PerformMutationTestingResumeTests {
    /// The events sent with any of `names` so far, in order.
    func recordEvents(named names: [RunEvent.Name]) -> () -> [RunEvent] {
        var sent: [RunEvent] = []
        for name in names {
            whenSent(name) { sent.append($0) }
        }
        return { sent }
    }

    /// Calls `handler` with each event sent with `name`, from the task that sends it, until the test ends.
    func whenSent(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) {
        let observer = runEvents.observe(name, handler)
        addTeardownBlock { observer.cancel() }
    }

    /// The stopped run's record of the mutant `makeSchemataMapping(file:line:)` makes, as it wrote it, naming
    /// `killedBy` as the tests that failed.
    func record(
        of file: String,
        line: Int,
        _ outcome: TestSuiteOutcome,
        fileSHA256: String,
        killedBy: [FailedTestLine.FailedTest]? = nil,
        rerun: MutantResult.Rerun? = nil
    ) -> MutantResult {
        let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        let operatorId = MutationOperator.Id.ror
        return MutantResult.make(
            path: file,
            line: line,
            column: 5,
            utf8Offset: line * 10,
            mutationOperatorId: operatorId,
            switchID: "\(name)_\(operatorId.rawValue)_\(line)_5_\(line * 10)",
            outcome: outcome,
            killedBy: killedBy,
            fileSHA256: fileSHA256,
            rerun: rerun
        )
    }

    /// A file in the mutated project with one mutant, at `line`, column 5.
    func makeSchemataMapping(file: String, line: Int) throws -> SchemataMutationMapping {
        try makeSchemataMapping(file: file, lines: [line])
    }

    /// A file in the mutated project with a mutant at each of `lines`, column 5.
    func makeSchemataMapping(file: String, lines: [Int]) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            (
                source: "func bar() { }",
                schemata: lines.map { line in
                    try .make(
                        filePath: "/project_mutated/\(file)",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line * 10, line: line, column: 5),
                        snapshot: .make(before: ">", after: "<", description: "changed > to <")
                    )
                }
            ),
            filePath: "/project_mutated/\(file)"
        )
    }

    /// Where a test run whose log is `name` writes its output: in the log folder's `running` folder.
    func running(_ name: String) -> String {
        "/project_muter_logs/session 2/running/\(name)"
    }
}
