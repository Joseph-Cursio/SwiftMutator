import Foundation
@testable import muterCore

/// Takes mutated projects' locks in memory: none is held, so none refuses another.
final class MutatedProjectLockerSpy: MutatedProjectLocking {
    /// Thrown by `lock` instead of taking the lock.
    var errorToThrow: Error?
    /// The mutated projects a lock was asked for, in order.
    private(set) var mutatedProjects: [URL] = []
    /// Each lock taken, in order.
    private(set) var locks: [MutatedProjectLock] = []

    func lock(_ mutatedProject: URL) throws -> MutatedProjectLock {
        mutatedProjects.append(mutatedProject)
        if let errorToThrow {
            throw errorToThrow
        }
        let lock = MutatedProjectLock(descriptor: -1, path: MutatedProjectLock.path(for: mutatedProject))
        locks.append(lock)
        return lock
    }
}
