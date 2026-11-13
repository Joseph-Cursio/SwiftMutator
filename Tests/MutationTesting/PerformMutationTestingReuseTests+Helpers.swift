@testable import muterCore
import XCTest

extension PerformMutationTestingReuseTests {
    /// Makes `lines` the earlier run's results file, whose only session's tree was this run's, with `changes` from it
    /// to this run's, and `globs` waiving those they match.
    func reuse(
        _ lines: [any Encodable],
        changes fileChanges: [ProjectTree.FileChange] = [],
        waiving globs: [String] = []
    ) throws {
        state.resumeState = try ResumeState.make(lines: lines, file: nil, path: earlierPath)
        var files = tree.files
        for change in fileChanges {
            files[change.path] = change.kind == .removed ? nil : "ffff"
        }
        let earlier = ProjectTree(
            listedBy: .git,
            files: tree.files.filter { path, _ in !fileChanges.contains { $0.path == path && $0.kind == .added } },
            excluded: [],
            treeSHA256: "e5b8"
        )
        let current = ProjectTree(listedBy: .git, files: files, excluded: [], treeSHA256: "f00d")
        state.reuseChanges = [1: ReuseChanges(from: earlier, to: current, waiving: globs) { _ in nil }]
    }

    /// An earlier run whose every result this run keeps.
    func heldEverywhere() -> [any Encodable] {
        [
            ResultsHeader.make(
                mutantsDiscovered: 4,
                mutantsToTest: 4,
                project: tree,
                logDirectory: "/project_muter_logs/earlier"
            ),
            record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
            record(of: "Sources/Quotient.swift", line: 4, .passed, fileSHA256: "3c4f"),
            record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", killedBy: [sumTest]),
            record(of: "Sources/Total.swift", line: 8, .passed, fileSHA256: "9e21"),
            ResultsEnd.make(recorded: 4),
        ]
    }

    /// Calls `handler` with each event sent with `name`, from the task that sends it, until the test ends.
    func whenSent(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) {
        let observer = runEvents.observe(name, handler)
        addTeardownBlock { observer.cancel() }
    }

    /// The earlier run's record of the mutant `makeSchemataMapping(file:line:)` makes.
    func record(
        of file: String,
        line: Int,
        _ outcome: TestSuiteOutcome,
        fileSHA256: String,
        killedBy: [FailedTestLine.FailedTest]? = nil,
        keptLog: Bool = true,
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
            endedBy: outcome == .timeout ? .timedOut : .exited,
            killedBy: killedBy,
            fileSHA256: fileSHA256,
            rerun: rerun,
            keptLog: keptLog
        )
    }

    /// A file in the mutated project with one mutant, at `line`, column 5.
    func makeSchemataMapping(file: String, line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            (
                source: "func bar() { }",
                schemata: [
                    try .make(
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

    /// Where a test run whose log is `name` writes its output: in the log folder's `running` folder.
    func running(_ name: String) -> String {
        "/project_muter_logs/now/running/\(name)"
    }
}
