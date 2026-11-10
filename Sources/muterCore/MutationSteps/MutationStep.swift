import Foundation

protocol MutationStep {
    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change]
}

extension FileSystemManager {
    /// Writes `log` to the run's log folder as `name`, and gives its path: for a log that no run's output file holds,
    /// such as a run's that the simulator failed to launch, whose file the run in its place wrote over. Without a log
    /// folder, as a state that bypasses the handler has, nothing is kept.
    @discardableResult
    func keepLog(_ log: String, named name: String, state: AnyMutationTestState) -> String? {
        guard !state.loggingDirectory.isEmpty else { return nil }
        let path = state.loggingDirectory.appendingPathComponent(name)
        _ = createFile(atPath: path, contents: Data(log.utf8), attributes: nil)
        return path
    }

    /// Keeps the log of a run that wrote its output to `output` as `name` in the run's log folder, by moving that file,
    /// or, with no file to move, by writing `log`, and gives its path. A nil `name` keeps nothing and discards the
    /// output, as does a state with no log folder. Either way the run's file is gone from where it ran.
    @discardableResult
    func keepLog(
        _ log: String,
        writtenTo output: String?,
        by ioDelegate: MutationTestingIODelegate,
        named name: String?,
        state: AnyMutationTestState
    ) -> String? {
        guard !state.loggingDirectory.isEmpty, let name else {
            if let output {
                ioDelegate.keepOutput(at: output, as: nil)
            }
            return nil
        }
        let path = state.loggingDirectory.appendingPathComponent(name)
        // Never `fileExists` first: the move says whether there was a file.
        if let output, ioDelegate.keepOutput(at: output, as: path) {
            return path
        }
        _ = createFile(atPath: path, contents: Data(log.utf8), attributes: nil)
        return path
    }
}
