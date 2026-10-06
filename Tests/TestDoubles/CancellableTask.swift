import Foundation

/// Runs work in a task of its own that `cancel()` cancels from anywhere. From a task group's child task, such as a
/// worker clone's build, `withUnsafeCurrentTask` would cancel only that child.
final class CancellableTask<Success>: @unchecked Sendable { // `task` is behind `lock`
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private var task: Task<Success, Error>?

    func run(_ work: @escaping () async throws -> Success) async -> Result<Success, Error> {
        let task = Task { try await work() }
        lock.withLock { self.task = task }
        started.signal()
        return await task.result
    }

    /// Waits until `run` has started the task, at most 5 seconds, so a cancellation can't come before it and be lost.
    func cancel() {
        if started.wait(timeout: .now() + 5) == .success {
            started.signal()
        }
        lock.withLock { task }?.cancel()
    }
}
