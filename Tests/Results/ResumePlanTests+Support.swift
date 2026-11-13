@testable import muterCore

extension ResumePlanTests {
    /// The mutation every job makes, unless a test says otherwise.
    static let mutation = MutationOperator.Snapshot.make(before: ">", after: "<", description: "changed > to <")

    /// This run's project files' hashes, unless a test says otherwise.
    static let hashes = ["Sources/Sum.swift": "ab12", "Sources/Product.swift": "cd34"]

    func key(
        _ path: String = "Sources/Sum.swift",
        line: Int = 73,
        mutationOperator: MutationOperator.Id = .ror,
        occurrence: Int = 0
    ) -> MutantKey {
        MutantKey(path: path, mutationOperatorId: mutationOperator, line: line, column: 22, occurrence: occurrence)
    }

    /// A result recorded for `key`'s mutant, tested in its file as this run's `hashes` has it.
    func record(
        of key: MutantKey,
        outcome: TestSuiteOutcome = .failed,
        endedBy: TestRun.Ending = .exited,
        snapshot: MutationOperator.Snapshot = mutation,
        killedBy: [FailedTestLine.FailedTest]? = nil
    ) -> MutantResult {
        record(
            of: key,
            fileSHA256: Self.hashes[key.path],
            outcome: outcome,
            endedBy: endedBy,
            snapshot: snapshot,
            killedBy: killedBy
        )
    }

    /// A timeout recorded for `key`'s mutant by `session`, tested in its file as this run's `hashes` has it, and its
    /// `rerun`'s if it was run again.
    func timeout(of key: MutantKey, session: Int, rerun: MutantResult.Rerun? = nil) -> MutantResult {
        MutantResult.make(
            session: session,
            path: key.path,
            line: key.line,
            column: key.column,
            occurrence: key.occurrence,
            mutationOperatorId: key.mutationOperatorId,
            snapshot: Self.mutation,
            outcome: .timeout,
            endedBy: .timedOut,
            fileSHA256: Self.hashes[key.path],
            rerun: rerun
        )
    }

    /// A result recorded for `key`'s mutant, tested in a file whose hash was `fileSHA256`.
    func record(
        of key: MutantKey,
        fileSHA256: String?,
        outcome: TestSuiteOutcome = .failed,
        endedBy: TestRun.Ending = .exited,
        snapshot: MutationOperator.Snapshot = mutation,
        killedBy: [FailedTestLine.FailedTest]? = nil
    ) -> MutantResult {
        MutantResult.make(
            path: key.path,
            line: key.line,
            column: key.column,
            occurrence: key.occurrence,
            mutationOperatorId: key.mutationOperatorId,
            snapshot: snapshot,
            outcome: outcome,
            endedBy: endedBy,
            killedBy: killedBy,
            fileSHA256: fileSHA256
        )
    }

    /// A reuse's changes since session 1, from a tree that holds this run's `hashes` and `SumTests.swift`, to one with
    /// `changed` files' hashes changed, `added` added and `removed` removed, with `sources` as the test files' text.
    func changes(
        changed: [String] = [],
        added: [String] = [],
        waiving globs: [String] = [],
        sources: [String: String] = [:]
    ) -> [Int: ReuseChanges] {
        let files = Self.hashes.merging(["Tests/SumTests/SumTests.swift": "0001"]) { $1 }
        var current = files
        for path in changed + added {
            current[path] = "ffff"
        }
        let allSources = sources.merging(
            ["Tests/SumTests/SumTests.swift": "import Testing\n@Test func adds() {}"]
        ) { first, _ in
            first
        }
        return [1: ReuseChanges(from: tree(files), to: tree(current), waiving: globs) { allSources[$0] }]
    }

    func tree(_ files: [String: String]) -> ProjectTree {
        ProjectTree(listedBy: .git, files: files, excluded: [], treeSHA256: ProjectTree.treeHash(of: files))
    }

    /// The plan for jobs with `keys`, each making `mutation` unless `snapshots` says otherwise.
    func plan(
        _ keys: [MutantKey],
        recorded records: [MutantResult],
        snapshots: [MutationOperator.Snapshot]? = nil,
        fileHashes: [String: String] = hashes,
        workers: [Int: Int] = [1: 1],
        limits: [Int: Double] = [:],
        limit: Double? = nil,
        reusing changes: [Int: ReuseChanges]? = nil
    ) -> ResumePlan {
        ResumePlan.make(
            keys: keys,
            snapshots: snapshots ?? keys.map { _ in Self.mutation },
            recorded: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }),
            fileHashes: fileHashes,
            workers: workers,
            limits: limits,
            limit: limit,
            reusing: changes
        )
    }
}
