import Foundation

/// Where a mutant comes in a session's jobs. Discovery sorts files by path (`mergeByFilePath`) and each file's mutants
/// by switch ID (`SchemataMutationMapping.mutationSchemata`), which compares as text, so line 10 comes before line 9;
/// a key's repeats come in the order they were found, which their occurrences number. A results file holds mutants in
/// the order they finished; this gives back the order the run tested and reported them in.
struct JobOrder: Comparable {
    /// The absolute path, as discovery sorted it: a file outside the mutated project, whose path the results file
    /// keeps as it is, then keeps its place among the others.
    let filePath: String
    let switchID: String
    let occurrence: Int

    static func < (lhs: JobOrder, rhs: JobOrder) -> Bool {
        (lhs.filePath, lhs.switchID, lhs.occurrence) < (rhs.filePath, rhs.switchID, rhs.occurrence)
    }
}

extension JobOrder {
    /// Where `record`'s mutant came in the jobs of a session that mutated the project copy at `mutatedProjectPath`.
    init(of record: MutantResult, under mutatedProjectPath: String) {
        self.init(
            filePath: RepoRelativePath.resolve(record.path, under: mutatedProjectPath),
            switchID: record.switchID,
            occurrence: record.occurrence
        )
    }
}

extension RecordedResults {
    /// The outcome the run would have reported had it ended now: each mutant's last record, in the order the run
    /// tested them, under the latest session's project paths, coverage and update notice, with every session's test
    /// duration. For a finished run, exactly the outcome its own report was made from.
    func mutationTestOutcome() -> MutationTestOutcome {
        // `read` refuses a file without a header.
        guard let header = headers.last else { return MutationTestOutcome() }
        let projectDirectory = URL(fileURLWithPath: header.projectPath, isDirectory: true)
        let mutatedProjectDirectory = URL(fileURLWithPath: header.mutatedProjectPath, isDirectory: true)
        let mutations = latest.values
            .map { (record: $0, order: JobOrder(of: $0, under: header.mutatedProjectPath)) }
            .sorted { $0.order < $1.order }
            .map { record, order in
                MutationTestOutcome.Mutation(
                    testSuiteOutcome: record.outcome,
                    mutationPoint: MutationPoint(
                        mutationOperatorId: record.mutationOperatorId,
                        filePath: order.filePath,
                        position: MutationPosition(utf8Offset: record.utf8Offset, line: record.line, column: record.column)
                    ),
                    mutationSnapshot: record.snapshot,
                    originalProjectDirectoryUrl: projectDirectory,
                    mutatedProjectDirectoryURL: mutatedProjectDirectory,
                    killingTests: .init(record)
                )
            }
        return MutationTestOutcome(
            mutations: mutations,
            coverage: header.coverage.map {
                Coverage(percent: $0.percent, filesWithoutCoverage: $0.filesWithoutCoverage)
            } ?? .null,
            testDuration: testDuration,
            newVersion: header.newVersion
        )
    }
}
