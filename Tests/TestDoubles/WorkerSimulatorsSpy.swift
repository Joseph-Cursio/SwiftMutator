import Foundation
@testable import muterCore

/// Worker simulators kept in memory: no simctl runs. Records each call, in order, from any thread.
final class WorkerSimulatorsSpy: WorkerSimulating, @unchecked Sendable { // every `var` is behind `lock`
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var preparing: Result<[WorkerSimulator], Error>?
    private var booting: Error?
    private var whileRemovingAll: (@Sendable () -> Void)?

    /// Each call, in order: `sweep <path>`, `prepare <count> like <destination> for <path>`, `boot <udids>` and
    /// `removeAll`.
    var calls: [String] { lock.withLock { recordedCalls } }

    /// What `prepare` gives: by default as many simulators as asked for, `platform=iOS Simulator,id=SIM-<n>`.
    func preparing(_ result: Result<[WorkerSimulator], Error>) {
        lock.withLock { preparing = result }
    }

    /// What `boot` throws, if anything.
    func booting(throwing error: Error?) {
        lock.withLock { booting = error }
    }

    /// Called by `removeAll`, from the task that calls it.
    func removingAll(_ hook: (@Sendable () -> Void)?) {
        lock.withLock { whileRemovingAll = hook }
    }

    func sweep(_ mutatedProject: URL) async {
        record("sweep \(mutatedProject.path)")
    }

    func prepare(_ count: Int, like destination: String, for mutatedProject: URL) async throws -> [WorkerSimulator] {
        record("prepare \(count) like \(destination) for \(mutatedProject.path)")
        let result = lock.withLock { preparing } ?? .success((0..<count).map { worker in
            WorkerSimulator(
                udid: "SIM-\(worker)",
                name: "swiftmutator-0123abcd-1-2-w\(worker)",
                destination: "platform=iOS Simulator,id=SIM-\(worker)"
            )
        })
        return try result.get()
    }

    func boot(_ simulators: [WorkerSimulator]) async throws {
        record("boot \(simulators.map(\.udid).joined(separator: " "))")
        if let error = lock.withLock({ booting }) {
            throw error
        }
    }

    func removeAll() async {
        record("removeAll")
        lock.withLock { whileRemovingAll }?()
    }

    private func record(_ call: String) {
        lock.withLock { recordedCalls.append(call) }
    }
}
