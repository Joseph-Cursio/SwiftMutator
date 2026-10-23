import Foundation

protocol MutationStep {
    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change]
}

extension FileSystemManager {
    /// Keeps `log` in the run's log folder as `name`, as `MutationTestObserver` keeps the baseline's and each mutant's,
    /// since the output its run wrote goes once read back, and gives its path. Without a log folder, as a state that
    /// bypasses the handler has, nothing is kept.
    @discardableResult
    func keepLog(_ log: String, named name: String, state: AnyMutationTestState) -> String? {
        guard !state.loggingDirectory.isEmpty else { return nil }
        let path = (state.loggingDirectory as NSString).appendingPathComponent(name)
        _ = createFile(atPath: path, contents: Data(log.utf8), attributes: nil)
        return path
    }
}
